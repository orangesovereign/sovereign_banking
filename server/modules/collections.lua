--[[
  server/modules/collections.lua — tier-2 collections & the Tax Collector
  (design §5.14).

  The bank owns the whole life of an unpaid debt. Tiers 0–1 are pure
  bookkeeping (server/scheduler.lua). This module is tier 2: the civil
  collections queue worked by the Tax Collector — a whitelisted job attached
  to the Tax Office society.

  The Tax Collector holds CIVIL authority: they may compel payment, place
  liens, and (under seizure.lua) lawfully seize goods for debt. They may never
  arrest or jail — that is the lawman's criminal authority, and a debt only
  reaches it at tier 3.

  HARD RULE, enforced in code and not merely documented: a private invoice is
  civil forever. `escalate` refuses any bill whose kind is not government debt,
  so no amount of collector frustration can turn a shopkeeper's unpaid tab into
  a warrant.

  Money split: the creditor (SYS-GOV for government debt, the issuer for a
  private invoice) is credited the full amount, then the collector's commission
  moves creditor → Tax Office fund as its own atomic transfer. Nothing is
  created or destroyed at any point.
]]

Collections = {}

local Err = Constants.Err

local function cfg()
  return Config.Collections or {}
end

--- Is this connected player a Tax Collector? Returns (bool, societyId).
function Collections.isCollector(src)
  local socId = cfg().collectorSociety
  if not socId then return false end
  local soc = Society.forSource(src)
  return (soc and soc.id == socId), socId
end

--- Same check for an offline/charid path — used by export callers that pass
--- a charid rather than a source.
function Collections.isCollectorCharid(charid)
  local socId = cfg().collectorSociety
  if not socId then return false end
  local src = Bridge.GetSourceFromCharId(tostring(charid))
  if not src then return false end
  local soc = Society.forSource(src)
  return (soc and soc.id == socId)
end

--- The collections queue (design §6.1 GetCollectionsQueue).
--- filterOpts: { kind, charid, mine (collector charid), limit }
function Collections.queue(filterOpts)
  filterOpts = filterOpts or {}
  local conds = { "status IN ('in_collections','warrant')" }
  local vals = {}
  if filterOpts.kind then
    conds[#conds + 1] = 'kind = ?'
    vals[#vals + 1] = tostring(filterOpts.kind)
  end
  if filterOpts.charid then
    conds[#conds + 1] = 'target_charid = ?'
    vals[#vals + 1] = tostring(filterOpts.charid)
  end
  if filterOpts.mine then
    conds[#conds + 1] = 'assigned_collector = ?'
    vals[#vals + 1] = tostring(filterOpts.mine)
  end
  vals[#vals + 1] = math.min(tonumber(filterOpts.limit) or 50, 100)

  return Db.query(([[
    SELECT *, UNIX_TIMESTAMP(due_at) AS due_epoch,
           UNIX_TIMESTAMP(created_at) AS created_epoch,
           DATEDIFF(NOW(), due_at) AS days_overdue
    FROM sov_bank_bills WHERE %s
    ORDER BY due_at ASC LIMIT ?
  ]]):format(table.concat(conds, ' AND ')), vals) or {}
end

--- Claim a debt off the queue so two collectors don't work the same debtor.
function Collections.assign(billId, collectorCharid)
  billId = tonumber(billId)
  if not billId then return false, Err.NO_BILL end
  return Money.withLocks({ 'bill:' .. billId }, function()
    local bill = Billing.get(billId)
    if not bill then return false, Err.NO_BILL end
    if bill.status ~= 'in_collections' then return false, Err.NOT_IN_COLLECTIONS end
    Db.execute('UPDATE sov_bank_bills SET assigned_collector = ? WHERE id = ?',
      { tostring(collectorCharid), bill.id })
    return true, { billId = bill.id }
  end)
end

--- Where a bill's proceeds belong (mirrors billing.lua).
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

--- Move the collector's commission creditor → Tax Office fund. Its own atomic
--- transfer, so a commission failure can never strand the principal.
local function payCommission(amount, creditorId, bill, collectorCharid)
  local rate = tonumber(cfg().taxCollectorCommission) or 0
  if rate <= 0 then return 0 end
  local commission = math.floor(amount * rate + 0.5)
  if commission <= 0 then return 0 end

  local socId = cfg().collectorSociety
  local socAcct = socId and Society.account(socId) or nil
  if not socAcct or socAcct.id == creditorId then return 0 end

  local ok = Money.transfer(creditorId, socAcct.id, Constants.Currency.MONEY, commission, {
    category = Constants.Category.COMMISSION,
    memo = ('Collection commission — bill #%d (%s)'):format(bill.id, tostring(collectorCharid)),
    source = 'sov_bank',
  })
  if not ok then
    Log.warn('bill #%d: commission of %s could not be paid', bill.id, commission)
    return 0
  end
  return commission
end

--- Record a payment taken in the field or on a payment plan
--- (design §6.1 RecordCollection). payWith = 'wallet' | accountId.
--- Partial payments are the payment-plan mechanism: the balance stays open.
function Collections.record(billId, collectorCharid, amount, payWith, meta)
  meta = meta or {}
  billId = tonumber(billId)
  if not billId then return false, Err.NO_BILL end

  return Money.withLocks({ 'bill:' .. billId }, function()
    local bill = Billing.get(billId)
    if not bill then return false, Err.NO_BILL end
    if bill.status ~= 'in_collections' and bill.status ~= 'warrant' then
      return false, Err.NOT_IN_COLLECTIONS
    end

    local remaining = tonumber(bill.balance_remaining) or 0
    if remaining <= 0 then return false, Err.BILL_CLOSED end
    local toPay = amount and math.floor(tonumber(amount) or 0) or remaining
    if not Util.isValidAmount(toPay) or toPay > remaining then return false, Err.BAD_AMOUNT end

    local creditorId = recipientAccount(bill)
    if not creditorId then return false, Err.INTERNAL end

    local memoLine = Util.truncate(
      ('Collected on %s #%d by %s'):format(bill.kind, bill.id, tostring(collectorCharid)), 140)

    if payWith == 'wallet' then
      local ok, res = Money.walletDebit(bill.target_charid, Constants.Currency.MONEY, toPay,
        { category = Constants.Category.COLLECTION, memo = memoLine,
          source = meta.source, silent = true })
      if not ok then return false, res end
      local ok2, res2 = Money.accountCredit(creditorId, Constants.Currency.MONEY, toPay,
        { category = Constants.Category.COLLECTION, memo = memoLine, source = meta.source })
      if not ok2 then
        Money.walletCredit(bill.target_charid, Constants.Currency.MONEY, toPay, {
          category = Constants.Category.COMPENSATION, source = 'sov_bank',
          memo = ('reversal: %s'):format(memoLine), silent = true,
        })
        return false, res2
      end
    else
      local fromId = tonumber(payWith)
      if not fromId then return false, Err.NO_ACCOUNT end
      local ok, res = Money.transfer(fromId, creditorId, Constants.Currency.MONEY, toPay,
        { category = Constants.Category.COLLECTION, memo = memoLine, source = meta.source })
      if not ok then return false, res end
    end

    local commission = payCommission(toPay, creditorId, bill, collectorCharid)

    local newRemaining = remaining - toPay
    local closed = newRemaining <= 0
    if closed then
      Db.execute([[
        UPDATE sov_bank_bills SET balance_remaining = 0, status = 'paid', paid_at = NOW()
        WHERE id = ?
      ]], { bill.id })
      Collections.releaseLiensForBill(bill.id)
      Events.billPaid({
        billId = bill.id, payerCharid = bill.target_charid,
        issuerType = bill.issuer_type, issuerId = bill.issuer_id,
        amount = tonumber(bill.amount), kind = bill.kind,
        wasWarrant = bill.status == 'warrant',
      })
    else
      Db.execute('UPDATE sov_bank_bills SET balance_remaining = ? WHERE id = ?',
        { newRemaining, bill.id })
    end

    Log.info('collections: %s took %s on bill #%d (commission %s), %s left',
      tostring(collectorCharid), toPay, bill.id, commission, newRemaining)
    return true, {
      applied = toPay, remaining = newRemaining, closed = closed, commission = commission,
    }
  end)
end

-- ============================================================================
-- Liens (design §5.14)
-- ============================================================================

function Collections.placeLien(debtorCharid, accountId, amount, opts)
  opts = opts or {}
  if cfg().liensEnabled == false then return false, Err.ACCESS end
  amount = math.floor(tonumber(amount) or 0)
  if not Util.isValidAmount(amount) then return false, Err.BAD_AMOUNT end

  local id = Db.insert([[
    INSERT INTO sov_bank_liens (bill_id, account_id, debtor_charid, amount, placed_by)
    VALUES (?, ?, ?, ?, ?)
  ]], {
    opts.billId and tonumber(opts.billId) or nil,
    accountId and tonumber(accountId) or nil,
    tostring(debtorCharid), amount, tostring(opts.collectorCharid or 'sov_bank'),
  })
  if not id then return false, Err.INTERNAL end
  Log.info('lien #%d placed on %s for %s', id, tostring(debtorCharid), amount)
  return true, { lienId = id }
end

function Collections.releaseLien(lienId, status)
  lienId = tonumber(lienId)
  if not lienId then return false, Err.NO_LIEN end
  local affected = Db.execute([[
    UPDATE sov_bank_liens SET status = ?, released_at = NOW()
    WHERE id = ? AND status = 'active'
  ]], { status or 'released', lienId })
  if not affected or affected < 1 then return false, Err.NO_LIEN end
  return true, { lienId = lienId }
end

function Collections.releaseLiensForBill(billId)
  Db.execute([[
    UPDATE sov_bank_liens SET status = 'satisfied', released_at = NOW()
    WHERE bill_id = ? AND status = 'active'
  ]], { tonumber(billId) })
end

function Collections.listLiens(debtorCharid)
  return Db.query([[
    SELECT *, UNIX_TIMESTAMP(created_at) AS created_epoch
    FROM sov_bank_liens WHERE debtor_charid = ? AND status = 'active'
    ORDER BY id DESC LIMIT 25
  ]], { tostring(debtorCharid) }) or {}
end

-- ============================================================================
-- Escort & escalation
-- ============================================================================

-- Escort flags are in-memory: they describe a live encounter, not a fact worth
-- persisting across a restart.
local escorts = {}

--- Flag "debtor is accompanying the collector to a branch to settle up"
--- (design §5.14 ladder step 2 — the cooperative path).
function Collections.startEscort(collectorCharid, debtorCharid, billId)
  local bill = Billing.get(billId)
  if not bill then return false, Err.NO_BILL end
  if tostring(bill.target_charid) ~= tostring(debtorCharid) then return false, Err.ACCESS end
  if bill.status ~= 'in_collections' and bill.status ~= 'warrant' then
    return false, Err.NOT_IN_COLLECTIONS
  end
  escorts[tostring(debtorCharid)] = {
    collector = tostring(collectorCharid), billId = bill.id, at = os.time(),
  }
  Log.info('escort started: %s walking %s to the bank over bill #%d',
    tostring(collectorCharid), tostring(debtorCharid), bill.id)
  return true, { billId = bill.id }
end

function Collections.getEscort(debtorCharid)
  local e = escorts[tostring(debtorCharid)]
  if not e then return nil end
  if os.time() - e.at > 1800 then -- stale after 30 real minutes
    escorts[tostring(debtorCharid)] = nil
    return nil
  end
  return e
end

function Collections.clearEscort(debtorCharid)
  escorts[tostring(debtorCharid)] = nil
end

--- Hand a stubborn evader to the lawman (design §6.1 EscalateToLawman).
--- GOVERNMENT DEBT ONLY — a private invoice is refused here, permanently.
function Collections.escalate(billId, collectorCharid)
  billId = tonumber(billId)
  if not billId then return false, Err.NO_BILL end
  if cfg().arrestable and cfg().arrestable.allowManualEscalation == false then
    return false, Err.ACCESS
  end

  return Money.withLocks({ 'bill:' .. billId }, function()
    local bill = Billing.get(billId)
    if not bill then return false, Err.NO_BILL end
    if Constants.GovDebt[bill.kind] ~= true then
      -- The hard rule (design §5.14): civil debt can never become criminal.
      return false, Err.CIVIL_DEBT
    end
    if bill.status ~= 'in_collections' then return false, Err.NOT_IN_COLLECTIONS end

    Db.execute("UPDATE sov_bank_bills SET status = 'warrant' WHERE id = ?", { bill.id })
    Log.warn('bill #%d escalated to WARRANT by collector %s',
      bill.id, tostring(collectorCharid))
    Events.warrantFiled({
      charid = bill.target_charid, billId = bill.id, kind = bill.kind,
      amount = tonumber(bill.balance_remaining) or 0,
      reason = ('escalated by Tax Collector %s'):format(tostring(collectorCharid)),
    })
    return true, { warrantFiled = true, billId = bill.id }
  end)
end
