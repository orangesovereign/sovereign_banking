--[[
  server/modules/savings.lua — savings interest (design §5.4).

  Interest applies ONLY to savings-kind accounts, only to the money balance,
  and accrues on REAL-LIFE days (Config.Interest.accrualRealDays per period).
  Accrual is lazy (posted when the account is touched at a teller) with a
  scheduler backstop for untouched accounts — both paths converge on
  Savings.accrue, which is race-safe without holding the account mutex:

  - The idempotency key is derived from (accountId, base last_accrued_at), so
    two concurrent accruals compute the same key and the engine applies it
    exactly once (the loser replays).
  - The accrual-row advance is a compare-and-set on last_accrued_at, so only
    the run that actually posted moves the clock.

  Catch-up is capped (catchUpCap periods) so a character away for months
  returns to modest interest, not a windfall (design §12.2).
]]

Savings = {}

local DAY = 86400

local function periodSeconds()
  return math.floor((Config.Interest.accrualRealDays or 7) * DAY)
end

--- Interest for one period on a balance, in minor units (simple per-period
--- rate: APR scaled to the accrual window).
local function periodInterest(balance)
  local rate = (Config.Interest.savingsAPR or 0.02)
    * ((Config.Interest.accrualRealDays or 7) / 365)
  return math.floor(balance * rate)
end

--- Post any elapsed interest periods for one savings account.
--- Returns (posted: number, periods: number) — both 0 when nothing was due.
function Savings.accrue(accountId)
  accountId = tonumber(accountId)
  if not accountId then return 0, 0 end
  if Config.Interest.savingsOnly == false then return 0, 0 end

  local acct = Accounts.getById(accountId)
  if not acct or acct.kind ~= Constants.AccountKind.SAVINGS
    or acct.status ~= 'active' then
    return 0, 0
  end

  local now = os.time()
  local row = Db.single(
    'SELECT UNIX_TIMESTAMP(last_accrued_at) AS last FROM sov_bank_savings_accrual WHERE account_id = ?',
    { accountId })

  if not row then
    -- First sighting: interest starts counting from now.
    Db.execute([[
      INSERT IGNORE INTO sov_bank_savings_accrual (account_id, last_accrued_at)
      VALUES (?, FROM_UNIXTIME(?))
    ]], { accountId, now })
    return 0, 0
  end

  local base = tonumber(row.last) or now
  local psec = periodSeconds()
  local elapsed = math.floor((now - base) / psec)
  if elapsed < 1 then return 0, 0 end

  local periods = math.min(elapsed, Config.Interest.catchUpCap or 4)

  -- The clock always advances past EVERY elapsed period, even though at most
  -- `catchUpCap` of them are paid. Advancing only by the paid count would
  -- leave the rest pending, and the sweep would simply pay them on the next
  -- tick — turning the cap into a slow drip of the same windfall it exists to
  -- prevent (design §12.2). Periods beyond the cap are forfeited.
  local newBase = base + elapsed * psec

  -- Compound per period on the running balance.
  local balance = tonumber(acct.balance_money) or 0
  local total = 0
  for _ = 1, periods do
    local i = periodInterest(balance + total)
    total = total + i
  end

  -- Compare-and-set on the base we read: only the run that actually observed
  -- this base may move the clock, so concurrent lazy and swept accruals can
  -- never both advance it. Runs unconditionally — it is idempotent by
  -- construction, and skipping it on a replay would strand the clock forever
  -- if a credit committed but its clock update did not.
  local function advance()
    return Db.execute([[
      UPDATE sov_bank_savings_accrual SET last_accrued_at = FROM_UNIXTIME(?)
      WHERE account_id = ? AND last_accrued_at = FROM_UNIXTIME(?)
    ]], { newBase, accountId, base })
  end

  if total <= 0 then
    advance() -- tiny balance: nothing to post, but don't re-scan these periods
    return 0, periods
  end

  local ok, res = Money.accountCredit(accountId, Constants.Currency.MONEY, total, {
    category = Constants.Category.INTEREST,
    memo = ('Interest, %d week(s)'):format(periods),
    source = 'sov_bank',
    idem = ('interest:%d:%d'):format(accountId, base), -- once per base, ever
  })
  if not ok then
    Log.error('interest posting failed for account %d: %s', accountId, tostring(res))
    return 0, 0
  end

  advance()
  if not res.replayed then
    Log.info('interest: account %d earned %s over %d period(s)%s', accountId, total, periods,
      elapsed > periods and (' (%d period(s) forfeited)'):format(elapsed - periods) or '')
  end
  return res.replayed and 0 or total, periods
end

--- Accrue every savings account a character can see (teller touch point).
function Savings.accrueForChar(charid)
  for _, a in ipairs(Accounts.listForChar(charid)) do
    if a.kind == Constants.AccountKind.SAVINGS then
      Savings.accrue(a.id)
    end
  end
end

--- Scheduler backstop (tech spec §9.2): a bounded slice of savings accounts
--- whose accrual clock is at least one period behind, including accounts that
--- have never been touched (missing accrual row).
function Savings.sweep(limit)
  local psec = periodSeconds()
  local cutoff = os.time() - psec
  local rows = Db.query([[
    SELECT a.id
    FROM sov_bank_accounts a
    LEFT JOIN sov_bank_savings_accrual s ON s.account_id = a.id
    WHERE a.kind = 'savings' AND a.status = 'active'
      AND (s.account_id IS NULL OR s.last_accrued_at < FROM_UNIXTIME(?))
    LIMIT ?
  ]], { cutoff, limit or 50 }) or {}
  for _, r in ipairs(rows) do
    Savings.accrue(r.id)
  end
  return #rows
end
