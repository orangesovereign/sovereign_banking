--[[
  server/modules/seizure.lua — lawful seizure for debt (design §5.14).

  This is the last rung of the collection ladder, and it is deliberately the
  most constrained code in the resource. Seizure is not "robbery with a badge":

  - It requires a VERIFIED open tier-2 debt. There is no generic "take their
    things" path — `authorized` is the only door, and it checks the bills table.
  - It is CAPPED to what is owed. A $5 debt cannot strip a debtor bare.
  - Exempt items are never taken, whatever the debt.
  - Goods are valued, "sold" through the Tax Office, and the proceeds applied
    to the debt; any SURPLUS goes back to the debtor.
  - A shortfall leaves the bill open (and, for government debt, still able to
    escalate) rather than being written off.
  - Every seizure writes an itemized audit row: collector, debtor, goods,
    assessed value, applied, surplus.

  Restraint (rope/hogtie) belongs to whichever resource owns it; that resource
  calls `IsSeizureAuthorized` before allowing the restraint, so force is gated
  on a real debt rather than on a player's say-so.

  Items are removed BEFORE any money moves, and proceeds are computed from what
  actually came out of the inventory — so a failed removal can never pay a
  collector for goods the debtor still has.
]]

Seizure = {}

local Err = Constants.Err

local function scfg()
  return (Config.Collections or {}).seizure or {}
end

local function isExempt(itemName)
  for _, name in ipairs(scfg().exemptItems or {}) do
    if name == itemName then return true end
  end
  return false
end

--- Unit value of an item in minor units (design §12.6a — configurable source).
function Seizure.itemValue(itemName)
  local cfg = scfg()
  if cfg.valuation == 'store' then
    local ref = cfg.storeExport or {}
    local ok, value = pcall(function()
      return exports[ref.resource][ref.fn](nil, itemName)
    end)
    if ok and tonumber(value) then return math.floor(tonumber(value)) end
    -- fall through to the table when the economy script isn't available
  end
  local priced = (cfg.priceTable or {})[itemName]
  if priced then return math.floor(tonumber(priced)) end
  return math.floor(tonumber(cfg.defaultItemValue) or 0)
end

--- Assessed sale value of a list (design §6.1 ValuateItems).
--- itemList = { { name = 'gold_nugget', count = 2 }, ... }
function Seizure.valuate(itemList)
  local total = 0
  if type(itemList) ~= 'table' then return 0 end
  for _, entry in ipairs(itemList) do
    local name = entry and (entry.name or entry.item)
    local count = math.max(0, math.floor(tonumber(entry and entry.count) or 0))
    if name and not isExempt(name) then
      total = total + Seizure.itemValue(name) * count
    end
  end
  return total
end

--- The open tier-2 debt a collector may act on, or nil (design §6.1
--- IsSeizureAuthorized). This is the single gate every seizure passes through.
function Seizure.authorizedBill(collectorCharid, debtorCharid)
  if scfg().enabled == false then return nil end
  if not Collections.isCollectorCharid(collectorCharid) then return nil end
  local row = Db.single([[
    SELECT *, UNIX_TIMESTAMP(due_at) AS due_epoch,
           UNIX_TIMESTAMP(created_at) AS created_epoch
    FROM sov_bank_bills
    WHERE target_charid = ? AND status IN ('in_collections','warrant')
      AND balance_remaining > 0
    ORDER BY balance_remaining DESC LIMIT 1
  ]], { tostring(debtorCharid) })
  return row
end

function Seizure.isAuthorized(collectorCharid, debtorCharid)
  return Seizure.authorizedBill(collectorCharid, debtorCharid) ~= nil
end

local function recipientAccount(bill)
  if bill.kind == Constants.BillKind.INVOICE then
    if bill.issuer_type == 'society' then
      local a = Society.account(bill.issuer_id)
      return a and a.id or nil
    end
    if bill.issuer_type == 'character' then
      local a = Accounts.ensurePrimary(bill.issuer_id)
      return a and a.id or nil
    end
  end
  local gov = Accounts.getSystem(Constants.SystemAccounts.GOV)
  return gov and gov.id or nil
end

--- Seize goods against a verified debt (design §6.1 SeizeAssets).
--- Returns (true, {applied, surplus, shortfall, seized, assessed}) or
--- (false, errCode).
function Seizure.seize(collectorCharid, debtorCharid, billId, itemList, opts)
  opts = opts or {}
  collectorCharid, debtorCharid = tostring(collectorCharid), tostring(debtorCharid)
  if scfg().enabled == false then return false, Err.SEIZURE_DISABLED end
  if type(itemList) ~= 'table' or #itemList == 0 then return false, Err.BAD_AMOUNT end

  -- Gate 1: the collector must hold the job, and the debt must be real.
  local bill = Seizure.authorizedBill(collectorCharid, debtorCharid)
  if not bill then return false, Err.SEIZURE_DENIED end
  if billId and tonumber(billId) ~= bill.id then
    -- Caller named a specific bill; honor it only if it is the same open debt.
    local named = Billing.get(billId)
    if not named or tostring(named.target_charid) ~= debtorCharid
      or (named.status ~= 'in_collections' and named.status ~= 'warrant') then
      return false, Err.SEIZURE_DENIED
    end
    bill = named
  end

  local debtorSrc = Bridge.GetSourceFromCharId(debtorCharid)
  if not debtorSrc then return false, Err.OFFLINE end

  -- The debtor is locked as well as the bill: two collectors working two of
  -- the same debtor's debts would otherwise both read the same item counts and
  -- both seize the same goods.
  return Money.withLocks({ 'bill:' .. bill.id, 'seize:' .. debtorCharid }, function()
    local fresh = Billing.get(bill.id)
    if not fresh then return false, Err.NO_BILL end
    local owed = tonumber(fresh.balance_remaining) or 0
    if owed <= 0 then return false, Err.BILL_CLOSED end

    -- Resolve (and prove usable) the destination for the proceeds BEFORE any
    -- goods leave the debtor. Discovering a frozen creditor after the fact
    -- would mean their property was destroyed for nothing.
    local creditorId = recipientAccount(fresh)
    if not creditorId then return false, Err.INTERNAL end
    local creditorAcct = Accounts.getById(creditorId)
    if not creditorAcct or creditorAcct.status ~= 'active' then
      return false, Err.FROZEN
    end

    -- Gate 2: plan the take, capped to the debt and to what they actually hold.
    local cap = scfg().capToDebt == false and math.huge or owed
    local plan, planned = {}, 0
    for _, entry in ipairs(itemList) do
      local name = entry and (entry.name or entry.item)
      local want = math.max(0, math.floor(tonumber(entry and entry.count) or 0))
      if name and want > 0 and not isExempt(name) then
        local unit = Seizure.itemValue(name)
        if unit > 0 then
          local held = Bridge.GetItemCount(debtorSrc, name)
          local take = math.min(want, held)
          if cap < math.huge then
            local room = math.max(0, cap - planned)
            take = math.min(take, math.floor(room / unit))
          end
          if take > 0 then
            plan[#plan + 1] = { name = name, count = take, unit = unit }
            planned = planned + take * unit
          end
        end
      end
    end
    if #plan == 0 then return false, Err.SEIZURE_DENIED end

    -- Gate 3: take the goods FIRST; only removed items can be paid for.
    local seized, assessed = {}, 0
    for _, p in ipairs(plan) do
      if Bridge.RemoveItem(debtorSrc, p.name, p.count) then
        seized[#seized + 1] = { name = p.name, count = p.count, value = p.unit * p.count }
        assessed = assessed + p.unit * p.count
      end
    end
    if assessed <= 0 then return false, Err.SEIZURE_DENIED end

    -- Proceeds: pay down the debt, hand back anything over.
    local applied = math.min(assessed, owed)
    local surplus = assessed - applied

    local currency = tonumber(fresh.currency) or Constants.Currency.MONEY
    local memoLine = Util.truncate(
      ('Seized goods sold — %s #%d'):format(fresh.kind, fresh.id), 140)

    local ok, res = Money.accountCredit(creditorId, currency, applied, {
      category = Constants.Category.SEIZURE, memo = memoLine, source = 'sov_bank',
    })
    if not ok then
      -- Goods are already gone. Nothing can un-take them, so record the loss
      -- loudly rather than silently pocketing it.
      Log.error('CRITICAL: seizure on bill #%d removed goods worth %s from %s but the creditor could not be credited (%s)',
        fresh.id, tostring(assessed), debtorCharid, tostring(res))
      return false, res
    end

    -- Commission out of the creditor's share (same shape as a field collection).
    local rate = tonumber((Config.Collections or {}).taxCollectorCommission) or 0
    local commission = math.floor(applied * rate + 0.5)
    if commission > 0 then
      local socId = (Config.Collections or {}).collectorSociety
      local socAcct = socId and Society.account(socId) or nil
      if socAcct and socAcct.id ~= creditorId then
        local paid = Money.transfer(creditorId, socAcct.id, currency,
          commission, {
            category = Constants.Category.COMMISSION,
            memo = ('Seizure commission — bill #%d (%s)'):format(fresh.id, collectorCharid),
            source = 'sov_bank',
          })
        if not paid then commission = 0 end
      else
        commission = 0
      end
    end

    -- Surplus returns to the debtor's bank account (design §5.14). Banking it
    -- rather than paying cash means it survives them being offline or robbed.
    local surplusReturned = 0
    if surplus > 0 and scfg().returnSurplus ~= false then
      local debtorAcct = Accounts.ensurePrimary(debtorCharid)
      if debtorAcct then
        local sok = Money.accountCredit(debtorAcct.id, currency, surplus, {
          category = Constants.Category.SEIZURE,
          memo = ('Surplus returned from seizure — bill #%d'):format(fresh.id),
          source = 'sov_bank',
        })
        if sok then surplusReturned = surplus end
      end
      if surplusReturned == 0 then
        Log.error('seizure on bill #%d: %s of surplus could not be returned to %s',
          fresh.id, tostring(surplus), debtorCharid)
      end
    end

    -- Apply to the bill.
    local newRemaining = owed - applied
    local closed = newRemaining <= 0
    if closed then
      Db.execute([[
        UPDATE sov_bank_bills SET balance_remaining = 0, status = 'paid', paid_at = NOW()
        WHERE id = ?
      ]], { fresh.id })
      Collections.releaseLiensForBill(fresh.id)
      Events.billPaid({
        billId = fresh.id, payerCharid = debtorCharid,
        issuerType = fresh.issuer_type, issuerId = fresh.issuer_id,
        amount = tonumber(fresh.amount), kind = fresh.kind,
        wasWarrant = fresh.status == 'warrant',
      })
    else
      Db.execute('UPDATE sov_bank_bills SET balance_remaining = ? WHERE id = ?',
        { newRemaining, fresh.id })
    end

    -- Audit row: itemized, permanent, disputable.
    Db.insert([[
      INSERT INTO sov_bank_seizures
        (bill_id, collector_charid, debtor_charid, items_json, assessed_value,
         applied_amount, surplus_returned)
      VALUES (?, ?, ?, ?, ?, ?, ?)
    ]], {
      fresh.id, collectorCharid, debtorCharid, json.encode(seized),
      assessed, applied, surplusReturned,
    })

    Log.warn('SEIZURE: %s took %d lot(s) worth %s from %s — %s applied to bill #%d, %s returned',
      collectorCharid, #seized, assessed, debtorCharid, applied, fresh.id, surplusReturned)
    Log.discord('admin', 'Assets seized for debt', nil, {
      { name = 'Collector', value = collectorCharid, inline = true },
      { name = 'Debtor', value = debtorCharid, inline = true },
      { name = 'Bill', value = ('#%d (%s)'):format(fresh.id, fresh.kind), inline = true },
      { name = 'Assessed', value = Util.formatAmount(assessed, 0), inline = true },
      { name = 'Applied', value = Util.formatAmount(applied, 0), inline = true },
      { name = 'Surplus returned', value = Util.formatAmount(surplusReturned, 0), inline = true },
    })

    Events.assetsSeized({
      collectorId = collectorCharid, debtorId = debtorCharid, billId = fresh.id,
      items = seized, applied = applied, surplus = surplusReturned,
    })

    return true, {
      seized = seized, assessed = assessed, applied = applied,
      surplus = surplusReturned, shortfall = newRemaining, closed = closed,
      commission = commission,
    }
  end)
end

--- Audit trail for a debtor (dispute resolution).
function Seizure.history(debtorCharid, limit)
  return Db.query([[
    SELECT *, UNIX_TIMESTAMP(created_at) AS created_epoch
    FROM sov_bank_seizures WHERE debtor_charid = ?
    ORDER BY id DESC LIMIT ?
  ]], { tostring(debtorCharid), math.min(tonumber(limit) or 20, 50) }) or {}
end
