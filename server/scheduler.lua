--[[
  server/scheduler.lua — timed jobs (tech spec §9).

  Delinquency sweep (design §5.14 tiers 0→1→2, and the tier-3 warrant for
  government debt), savings-interest backstop, and loan defaults. Branch
  reserve refills join in Phase 4 with the heist surface.

  All timers run on real-life time (os.time epoch). Every transition takes
  the per-bill mutex so a sweep can never interleave with a payment, and each
  pass works a bounded slice so a big backlog can't hitch the server.

  Tier rules (Config.Collections):
  - pending  → overdue         when now > due_at + overdueAfterDays.
    The late fee is applied ONCE here, growing balance_remaining.
  - overdue  → in_collections  when now > due_at + overdueAfterDays
                                          + collectionsAfterDays.
  - in_collections → warrant   GOVERNMENT DEBT ONLY (fine/tax), when the
    arrestable threshold is met (amount + days overdue). Invoices are civil
    forever (design §5.14 hard rule) — the query itself excludes them.
]]

local DAY = 86400
local SLICE = 100 -- bills per transition per sweep

local function lateFeeFor(amount)
  local cfg = (Config.Collections or {}).lateFee
  if not cfg then return 0 end
  if cfg.type == 'flat' then return math.floor(tonumber(cfg.value) or 0) end
  if cfg.type == 'percent' then
    return math.floor(amount * (tonumber(cfg.value) or 0) + 0.5)
  end
  return 0
end

local function sweepOverdue(now)
  local cutoff = now - math.floor((Config.Collections.overdueAfterDays or 3) * DAY)
  local rows = Db.query([[
    SELECT id FROM sov_bank_bills
    WHERE status = 'pending' AND due_at IS NOT NULL AND due_at < FROM_UNIXTIME(?)
    LIMIT ?
  ]], { cutoff, SLICE }) or {}

  for _, r in ipairs(rows) do
    Money.withLocks({ 'bill:' .. r.id }, function()
      local bill = Billing.get(r.id)
      if not bill or bill.status ~= 'pending' then return true end
      local fee = lateFeeFor(tonumber(bill.balance_remaining) or 0)
      Db.execute([[
        UPDATE sov_bank_bills
        SET status = 'overdue', balance_remaining = balance_remaining + ?
        WHERE id = ?
      ]], { fee, bill.id })
      Log.info('bill #%d overdue (late fee %s)', bill.id, tostring(fee))
      Events.debtOverdue({
        charid = bill.target_charid, billId = bill.id, kind = bill.kind,
        amount = (tonumber(bill.balance_remaining) or 0) + fee,
      })
      return true
    end)
  end
  return #rows
end

local function sweepCollections(now)
  local days = (Config.Collections.overdueAfterDays or 3)
    + (Config.Collections.collectionsAfterDays or 7)
  local cutoff = now - math.floor(days * DAY)
  local rows = Db.query([[
    SELECT id FROM sov_bank_bills
    WHERE status = 'overdue' AND due_at IS NOT NULL AND due_at < FROM_UNIXTIME(?)
    LIMIT ?
  ]], { cutoff, SLICE }) or {}

  for _, r in ipairs(rows) do
    Money.withLocks({ 'bill:' .. r.id }, function()
      local bill = Billing.get(r.id)
      if not bill or bill.status ~= 'overdue' then return true end
      Db.execute("UPDATE sov_bank_bills SET status = 'in_collections' WHERE id = ?", { bill.id })
      Log.info('bill #%d entered collections', bill.id)
      Events.debtInCollections({
        charid = bill.target_charid, billId = bill.id, kind = bill.kind,
        amount = tonumber(bill.balance_remaining) or 0,
      })
      return true
    end)
  end
  return #rows
end

local function sweepWarrants(now)
  local arr = (Config.Collections or {}).arrestable or {}
  if arr.enabled == false then return 0 end
  local minAmount = tonumber(arr.minAmount) or 5000
  local cutoff = now - math.floor((tonumber(arr.minOverdueDays) or 14) * DAY)

  -- Government debt only. The kind filter is structural, not advisory:
  -- an invoice can never match this query (design §5.14 hard rule).
  local rows = Db.query([[
    SELECT id FROM sov_bank_bills
    WHERE status = 'in_collections'
      AND kind IN ('fine','tax')
      AND balance_remaining >= ?
      AND due_at IS NOT NULL AND due_at < FROM_UNIXTIME(?)
    LIMIT ?
  ]], { minAmount, cutoff, SLICE }) or {}

  for _, r in ipairs(rows) do
    Money.withLocks({ 'bill:' .. r.id }, function()
      local bill = Billing.get(r.id)
      if not bill or bill.status ~= 'in_collections' then return true end
      if Constants.GovDebt[bill.kind] ~= true then return true end -- belt & braces
      Db.execute("UPDATE sov_bank_bills SET status = 'warrant' WHERE id = ?", { bill.id })
      Log.warn('bill #%d escalated to WARRANT (%s, %s owed by %s)',
        bill.id, bill.kind, tostring(bill.balance_remaining), bill.target_charid)
      Events.warrantFiled({
        charid = bill.target_charid, billId = bill.id, kind = bill.kind,
        amount = tonumber(bill.balance_remaining) or 0,
        reason = ('unpaid %s in collections'):format(bill.kind),
      })
      return true
    end)
  end
  return #rows
end

CreateThread(function()
  -- Let boot seeding finish before the first pass.
  Wait(10000)
  while true do
    local ok, err = pcall(function()
      local now = os.time()
      local a = sweepOverdue(now)
      local b = sweepCollections(now)
      local c = sweepWarrants(now)
      if a + b + c > 0 then
        Log.info('delinquency sweep: %d overdue, %d to collections, %d warrants', a, b, c)
      end
      Savings.sweep(50)      -- interest for accounts nobody has touched
      Loans.sweepDefaults(50)
    end)
    if not ok then Log.error('scheduler sweep crashed: %s', tostring(err)) end
    Wait(math.floor((Config.Scheduler.sweepMinutes or 15) * 60000))
  end
end)
