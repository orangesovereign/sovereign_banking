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

  -- Both epochs, on BOTH paths. This query used to omit claimed_epoch, which is
  -- the path taken every time after the first: cooldownRemaining then read a nil
  -- last-claimed and returned 0, so the cooldown silently never applied.
  local row = Db.single([[
    SELECT *, UNIX_TIMESTAMP(last_refilled_at) AS refilled_epoch,
           UNIX_TIMESTAMP(last_claimed_at) AS claimed_epoch
    FROM sovereign_banking_reserves WHERE branch_id = ? AND currency = ?
  ]], { branch.id, currency })
  if row then return row end

  local cap = branchCap(branch)
  Db.execute([[
    INSERT IGNORE INTO sovereign_banking_reserves (branch_id, currency, balance, cap, last_refilled_at)
    VALUES (?, ?, ?, ?, NOW())
  ]], { branch.id, currency, cap, cap })
  return Db.single([[
    SELECT *, UNIX_TIMESTAMP(last_refilled_at) AS refilled_epoch,
           UNIX_TIMESTAMP(last_claimed_at) AS claimed_epoch
    FROM sovereign_banking_reserves WHERE branch_id = ? AND currency = ?
  ]], { branch.id, currency })
end

--- Cash on hand at a branch, in minor units (design §6.1 GetBranchReserve).
function Heist.getReserve(branchId, currency)
  local row = Heist.getRow(branchId, currency)
  return row and (tonumber(row.balance) or 0) or nil
end

-- ============================================================================
-- Robbery state
--
-- Live encounter state, held in memory: it describes something happening right
-- now, not a fact worth surviving a restart. The heist resource owns the
-- encounter and calls Begin/End around it; the bank uses the flag to shut the
-- teller (you cannot make a deposit while a man holds a gun on the clerk) and
-- self-clears it so a crashed heist script can't close a branch forever.
-- ============================================================================

local robberies = {} -- branchId -> { by, at }

local function lockMins()
  return tonumber(cfg().robberyLockMins) or 20
end

--- True while a robbery is in progress at this branch.
function Heist.isUnderRobbery(branchId)
  local r = robberies[tostring(branchId)]
  if not r then return false end
  if os.time() - r.at > lockMins() * 60 then
    robberies[tostring(branchId)] = nil
    Log.warn('robbery flag on %s expired after %d minutes — clearing it',
      tostring(branchId), lockMins())
    return false
  end
  return true
end

--- Called by the heist resource when a robbery starts.
function Heist.beginRobbery(branchId, opts)
  opts = opts or {}
  local branch = Branches.getById(branchId)
  if not branch then return false, Err.NO_BRANCH end
  if Heist.isUnderRobbery(branch.id) then return false, Err.BRANCH_ROBBERY end

  robberies[branch.id] = { by = opts.by, at = os.time() }
  Log.warn('ROBBERY BEGUN at %s (by %s)', branch.name, tostring(opts.by or '?'))
  Events.robberyStarted({
    branchId = branch.id, branchName = branch.name,
    by = opts.by, coords = branch.teller,
  })
  return true, { branchId = branch.id, expiresIn = lockMins() * 60 }
end

--- Called by the heist resource when it ends, however it ended.
function Heist.endRobbery(branchId, opts)
  opts = opts or {}
  local branch = Branches.getById(branchId)
  if not branch then return false, Err.NO_BRANCH end
  robberies[branch.id] = nil
  Log.info('robbery at %s ended (%s)', branch.name, tostring(opts.outcome or 'unknown'))
  Events.robberyEnded({
    branchId = branch.id, branchName = branch.name, outcome = opts.outcome,
  })
  return true, { branchId = branch.id }
end

--- Seconds remaining before this branch's till may be claimed again, 0 if now.
function Heist.cooldownRemaining(branchId, currency)
  local row = Heist.getRow(branchId, currency)
  if not row then return 0 end
  local last = tonumber(row.claimed_epoch)
  if not last then return 0 end
  local window = math.floor((tonumber(cfg().cooldownRealHrs) or 0) * HOUR)
  local elapsed = os.time() - last
  return elapsed >= window and 0 or (window - elapsed)
end

--- Everything the heist resource needs to decide whether a job is worth
--- starting, in one call — so a crew isn't sent to crack an empty vault.
function Heist.getStatus(branchId, currency)
  currency = tonumber(currency) or Constants.Currency.MONEY
  local branch = Branches.getById(branchId)
  if not branch then return nil end
  local row = Heist.getRow(branch.id, currency)
  if not row then return nil end

  local cooldown = Heist.cooldownRemaining(branch.id, currency)
  local balance = tonumber(row.balance) or 0
  return {
    branchId = branch.id,
    branchName = branch.name,
    currency = currency,
    balance = balance,
    cap = tonumber(row.cap) or 0,
    lastClaimedAt = tonumber(row.claimed_epoch),
    lastRefilledAt = tonumber(row.refilled_epoch),
    cooldownRemaining = cooldown,
    underRobbery = Heist.isUnderRobbery(branch.id),
    -- The single flag worth branching on: is there anything to take right now?
    claimable = balance > 0 and cooldown == 0,
  }
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

    -- Cooldown is enforced HERE rather than trusted to the caller: it governs
    -- how fast money can leave the bank, which makes it a money rule. The
    -- heist script should check getStatus first so a crew isn't sent to crack
    -- a vault that will refuse them, but this is the authority.
    local cooling = Heist.cooldownRemaining(branch.id, currency)
    if cooling > 0 then
      Log.info('heist claim on %s refused — %d min of cooldown left',
        branch.id, math.ceil(cooling / 60))
      return false, Err.COOLDOWN
    end

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
      UPDATE sovereign_banking_reserves SET balance = balance - ?, last_claimed_at = NOW()
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

    Events.reserveClaimed({
      branchId = branch.id, branchName = branch.name, currency = currency,
      looted = looted, remaining = remaining, paid = paid,
      looters = looters, txId = uuid,
    })

    return true, {
      looted = looted, remaining = remaining, paid = paid, txId = uuid,
      cooldownRemaining = Heist.cooldownRemaining(branch.id, currency),
    }
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
