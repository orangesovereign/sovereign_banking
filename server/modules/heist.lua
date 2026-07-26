--[[
  server/modules/heist.lua — branch physical cash reserve (design §5.11).

  THE GUARANTEE: a robbery can never debit, freeze, or reduce any character's
  or society's bank account. That is enforced structurally, not by config —
  nothing in this file reads or writes sovereign_banking_accounts for a player. The
  only pool it touches is sovereign_banking_reserves: the cash physically on hand in
  a branch's vault and till, which is a wholly separate ledger of money.

  In-world, banked balances are government-insured (funded by the fees that
  route to SYS-INSURANCE), so a heist takes the bank's cash, never a
  customer's deposit.

  Ownership split: the heist/robbery gameplay (cracking the vault, alarms,
  lawman dispatch) belongs to a separate resource. This module exposes the
  pool and the claim; the heist script owns the action and supplies its own
  randomization through opts.

  Ledger note: heist rows are written with account_id NULL (like wallet ops)
  and the branch named in the memo. The reserve is not an account, so keeping
  these rows off every account keeps reconciliation (§5.6) exact.
]]

Heist = {}

local Err = Constants.Err
local HOUR = 3600

local function cfg()
  return Config.Heist or {}
end

local function branchCap(branch)
  return tonumber(branch.reserve and branch.reserve.cap)
    or tonumber(cfg().reserveDefault) or 250000
end

--- Reserve row for a branch, seeding it on first sight.
function Heist.getRow(branchId, currency)
  currency = tonumber(currency) or Constants.Currency.MONEY
  local branch = Branches.getById(branchId)
  if not branch then return nil end

  local row = Db.single([[
    SELECT *, UNIX_TIMESTAMP(last_refilled_at) AS refilled_epoch
    FROM sovereign_banking_reserves WHERE branch_id = ? AND currency = ?
  ]], { branch.id, currency })
  if row then return row end

  local cap = branchCap(branch)
  Db.execute([[
    INSERT IGNORE INTO sovereign_banking_reserves (branch_id, currency, balance, cap, last_refilled_at)
    VALUES (?, ?, ?, ?, NOW())
  ]], { branch.id, currency, cap, cap })
  return Db.single([[
    SELECT *, UNIX_TIMESTAMP(last_refilled_at) AS refilled_epoch
    FROM sovereign_banking_reserves WHERE branch_id = ? AND currency = ?
  ]], { branch.id, currency })
end

--- Cash on hand at a branch, in minor units (design §6.1 GetBranchReserve).
function Heist.getReserve(branchId, currency)
  local row = Heist.getRow(branchId, currency)
  return row and (tonumber(row.balance) or 0) or nil
end

--- Rob the till (design §6.1 ClaimBranchReserve).
--- opts:
---   fraction = 0..1     share of the CURRENT reserve to take (the heist
---                       script's own RNG; clamped to Config.Heist.payoutRange)
---   amount   = minor    explicit amount instead of a fraction
---   looters  = charid | { charid, ... }   wallets to split the take into
---   idem     = string   replay guard
--- Returns (true, {looted, remaining, perLooter, paid}) or (false, errCode).
--- Player and society ACCOUNT balances are never queried or altered.
function Heist.claim(branchId, currency, opts)
  opts = opts or {}
  currency = tonumber(currency) or Constants.Currency.MONEY
  local branch = Branches.getById(branchId)
  if not branch then return false, Err.NO_ACCOUNT end

  return Money.withLocks({ 'reserve:' .. branch.id .. ':' .. currency }, function()
    if opts.idem then
      local prior = Ledger.findByUuid(opts.idem)
      if prior then
        return true, { looted = tonumber(prior.amount) or 0, replayed = true }
      end
    end

    local row = Heist.getRow(branch.id, currency)
    if not row then return false, Err.INTERNAL end
    local reserve = tonumber(row.balance) or 0
    if reserve <= 0 then return false, Err.INSUFFICIENT_FUNDS end

    local looted
    if opts.amount then
      looted = math.floor(tonumber(opts.amount) or 0)
    else
      local range = cfg().payoutRange or { 0.4, 0.8 }
      local f = tonumber(opts.fraction) or range[1]
      f = math.max(range[1] or 0, math.min(range[2] or 1, f))
      looted = math.floor(reserve * f)
    end
    looted = math.max(0, math.min(looted, reserve))
    if looted <= 0 then return false, Err.INSUFFICIENT_FUNDS end

    -- Drain the till first: the money exists once, and only in the reserve.
    local affected = Db.execute([[
      UPDATE sovereign_banking_reserves SET balance = balance - ?
      WHERE branch_id = ? AND currency = ? AND balance >= ?
    ]], { looted, branch.id, currency, looted })
    if not affected or affected < 1 then return false, Err.INSUFFICIENT_FUNDS end

    local uuid = opts.idem or Util.uuid()
    Ledger.write({
      tx_uuid = uuid, currency = currency, direction = 'debit', amount = looted,
      category = Constants.Category.HEIST,
      source_resource = opts.source or 'heist',
      memo = ('Vault reserve taken — %s'):format(branch.name),
    })

    -- Pay the looters' WALLETS. A failed wallet leg is logged and its share
    -- stays "in the wind" rather than silently returning to the till.
    local looters = opts.looters
    if type(looters) == 'string' or type(looters) == 'number' then
      looters = { tostring(looters) }
    end
    local paid = {}
    if type(looters) == 'table' and #looters > 0 then
      local share = math.floor(looted / #looters)
      local remainder = looted - share * #looters
      for i, charid in ipairs(looters) do
        local cut = share + (i == 1 and remainder or 0)
        if cut > 0 then
          local ok = Money.walletCredit(tostring(charid), currency, cut, {
            category = Constants.Category.HEIST,
            memo = ('Score — %s'):format(branch.name),
            source = opts.source or 'heist',
            silent = opts.silent ~= false,
          })
          if ok then
            paid[#paid + 1] = { charid = tostring(charid), amount = cut }
          else
            Log.warn('heist: could not pay %s their %s cut (offline?)', tostring(charid), cut)
          end
        end
      end
    end

    local remaining = reserve - looted
    Log.warn('HEIST: %s reserve down %s, %s remains (%d looter(s) paid)',
      branch.name, looted, remaining, #paid)
    Log.discord('heist', ('Vault robbed — %s'):format(branch.name), nil, {
      { name = 'Taken', value = Util.formatAmount(looted, currency), inline = true },
      { name = 'Reserve left', value = Util.formatAmount(remaining, currency), inline = true },
      { name = 'Paid out to', value = tostring(#paid), inline = true },
    })

    return true, { looted = looted, remaining = remaining, paid = paid, txId = uuid }
  end)
end

--- Scheduler: refill reserves toward cap once replenishRealHrs has elapsed
--- since the last refill (design §5.11 — a branch can't be farmed).
function Heist.replenish()
  local hrs = tonumber(cfg().replenishRealHrs) or 48
  local rows = Db.query([[
    SELECT branch_id, currency, balance, cap FROM sovereign_banking_reserves
    WHERE balance < cap
      AND (last_refilled_at IS NULL OR last_refilled_at < FROM_UNIXTIME(?))
    LIMIT 25
  ]], { os.time() - math.floor(hrs * HOUR) }) or {}

  for _, r in ipairs(rows) do
    Db.execute([[
      UPDATE sovereign_banking_reserves SET balance = cap, last_refilled_at = NOW()
      WHERE branch_id = ? AND currency = ?
    ]], { r.branch_id, r.currency })
    Log.info('reserve refilled: %s back to %s', r.branch_id, tostring(r.cap))
  end
  return #rows
end

--- Boot: seed a money reserve row per configured branch, and re-sync caps
--- when the config changes.
function Heist.ensureReserves()
  for _, branch in ipairs(Branches.list()) do
    local row = Heist.getRow(branch.id, Constants.Currency.MONEY)
    local cap = branchCap(branch)
    if row and tonumber(row.cap) ~= cap then
      Db.execute([[
        UPDATE sovereign_banking_reserves SET cap = ?, balance = LEAST(balance, ?)
        WHERE branch_id = ? AND currency = ?
      ]], { cap, cap, branch.id, Constants.Currency.MONEY })
      Log.info('reserve cap for %s set to %s', branch.id, cap)
    end
  end
end

--- Admin/ops view of every branch till.
function Heist.report()
  return Db.query([[
    SELECT branch_id, currency, balance, cap,
           UNIX_TIMESTAMP(last_refilled_at) AS refilled_epoch
    FROM sovereign_banking_reserves ORDER BY branch_id ASC
  ]]) or {}
end
