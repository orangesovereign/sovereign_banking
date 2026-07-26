--[[
  server/modules/billing.lua — invoices, fines & taxes (design §5.7).

  - Invoices are CIVIL debt: any character or society bills another character;
    settled at a teller; proceeds route to the issuer. They can be chased by
    collections but can NEVER become a warrant (design §5.14 hard rule).
  - Fines and taxes are GOVERNMENT debt, issued by the lawman script / Tax
    Office through the exports; proceeds route to SYS-GOV; they alone may
    escalate to tier 3.

  Settlement happens in person at a branch (callbacks layer enforces
  proximity). Payment routes:
  - from a bank account: one atomic Money.transfer (no wallet leg);
  - from the wallet: walletDebit → accountCredit with compensation on the
    second-leg failure, mirroring the engine's two-phase pattern.

  Bill-row mutations run under a per-bill mutex ('bill:<id>') so a payment
  and a scheduler tier-flip can never interleave.
]]

Billing = {}

local Err = Constants.Err
local DAY = 86400

local function dueDaysFor(kind)
  local b = Config.Billing or {}
  if kind == Constants.BillKind.FINE then return b.fineDueDays or 3 end
  if kind == Constants.BillKind.TAX then return b.taxDueDays or 7 end
  return b.invoiceDueDays or 3
end

function Billing.get(billId)
  billId = tonumber(billId)
  if not billId then return nil end
  return Db.single([[
    SELECT *, UNIX_TIMESTAMP(due_at) AS due_epoch,
           UNIX_TIMESTAMP(created_at) AS created_epoch
    FROM sov_bank_bills WHERE id = ?
  ]], { billId })
end

local OPEN_STATUSES = "('pending','overdue','in_collections','warrant')"

--- Open bills a character owes (teller "Pay Bills" view, GetDebtStatus).
function Billing.listOpenFor(charid)
  return Db.query(([[
    SELECT *, UNIX_TIMESTAMP(due_at) AS due_epoch,
           UNIX_TIMESTAMP(created_at) AS created_epoch
    FROM sov_bank_bills
    WHERE target_charid = ? AND status IN %s
    ORDER BY created_at ASC
  ]]):format(OPEN_STATUSES), { tostring(charid) }) or {}
end

--- Count of open bills issued by an issuer (anti-spam cap).
local function openCountByIssuer(issuerType, issuerId)
  return tonumber(Db.scalar(([[
    SELECT COUNT(*) FROM sov_bank_bills
    WHERE issuer_type = ? AND issuer_id = ? AND status IN %s
  ]]):format(OPEN_STATUSES), { issuerType, tostring(issuerId) })) or 0
end

--- Issue a bill (design §6.1 IssueInvoice / IssueFine / LevyTax back this).
--- issuer = { type = 'character'|'society'|'system', id = <owner key> }.
--- opts: dueDays override, memo, source, idem (bill_uuid — replays return the
--- original bill instead of double-billing).
--- Returns (true, {billId, dueAt}) or (false, errCode).
function Billing.issue(kind, issuer, targetCharid, currency, amount, memo, opts)
  opts = opts or {}
  if not Constants.BillKind[string.upper(kind or '')] then return false, Err.BAD_KIND end
  if type(issuer) ~= 'table' or not issuer.type or issuer.id == nil then
    return false, Err.ACCESS
  end
  local name = Constants.CurrencyName[currency]
  if not name then return false, Err.BAD_CURRENCY end
  if not Config.Currencies[name] then return false, Err.CURRENCY_DISABLED end
  if not Util.isValidAmount(amount) then return false, Err.BAD_AMOUNT end

  targetCharid = tostring(targetCharid)
  if not Bridge.CharacterExists(targetCharid) then return false, Err.UNKNOWN_CHAR end

  -- A character can't bill themselves.
  if issuer.type == 'character' and tostring(issuer.id) == targetCharid then
    return false, Err.ACCESS
  end

  if issuer.type ~= 'system'
    and openCountByIssuer(issuer.type, issuer.id) >= (Config.Billing.maxOpenPerIssuer or 25) then
    return false, Err.ACCOUNT_LIMIT
  end

  local uuid = type(opts.idem) == 'string' and opts.idem or Util.uuid()
  local existing = Db.single('SELECT id, UNIX_TIMESTAMP(due_at) AS due_epoch FROM sov_bank_bills WHERE bill_uuid = ?', { uuid })
  if existing then
    return true, { billId = existing.id, dueAt = tonumber(existing.due_epoch), replayed = true }
  end

  local dueDays = tonumber(opts.dueDays) or dueDaysFor(kind)
  local dueEpoch = os.time() + math.floor(dueDays * DAY)

  -- memo is optional and last: Util.truncate returns nil for a non-string,
  -- and a trailing nil shortens the oxmysql parameter array so the bind count
  -- no longer matches the statement. Coerce rather than pass nil.
  local id = Db.insert([[
    INSERT INTO sov_bank_bills
      (bill_uuid, issuer_type, issuer_id, target_charid, kind, currency, amount,
       balance_remaining, status, due_at, memo)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'pending', FROM_UNIXTIME(?), ?)
  ]], {
    uuid, issuer.type, tostring(issuer.id), targetCharid, kind, currency, amount,
    amount, dueEpoch, Util.truncate(memo, 140) or '',
  })
  if not id then return false, Err.INTERNAL end

  Log.info('bill #%d issued: %s %s from %s/%s to %s (%s)',
    id, kind, tostring(amount), issuer.type, tostring(issuer.id), targetCharid,
    tostring(memo))
  return true, { billId = id, dueAt = dueEpoch }
end

--- Where a bill's money goes (design §5.7): invoices to the issuer,
--- fines/taxes to the government fund. Returns accountId or nil.
local function recipientAccount(bill)
  if bill.kind == Constants.BillKind.INVOICE then
    if bill.issuer_type == 'society' then
      local acct = Society.account(bill.issuer_id)
      return acct and acct.id or nil
    end
    if bill.issuer_type == 'character' then
      local acct = Accounts.ensurePrimary(bill.issuer_id)
      return acct and acct.id or nil
    end
  end
  local gov = Accounts.getSystem(Constants.SystemAccounts.GOV)
  return gov and gov.id or nil
end

--- Settle a bill, fully or partially (design §5.14 payment plans allow
--- partials). payWith = 'wallet' or a source accountId the payer controls
--- (the callbacks layer enforces access on that account).
--- amount nil → pay the full balance_remaining.
--- Returns (true, {applied, remaining, closed}) or (false, errCode).
function Billing.pay(billId, payerCharid, payWith, amount, meta)
  meta = meta or {}
  billId = tonumber(billId)
  if not billId then return false, Err.NO_BILL end
  payerCharid = tostring(payerCharid)

  return Money.withLocks({ 'bill:' .. billId }, function()
    local bill = Billing.get(billId)
    if not bill then return false, Err.NO_BILL end
    if bill.target_charid ~= payerCharid then return false, Err.ACCESS end
    local remaining = tonumber(bill.balance_remaining) or 0
    if remaining <= 0
      or bill.status == 'paid' or bill.status == 'cancelled' or bill.status == 'expired' then
      return false, Err.BILL_CLOSED
    end

    -- Note the floor+or-0: `amount and tonumber(amount) or remaining` would
    -- fall through to "pay everything" when a caller passes a non-numeric
    -- amount, which is the opposite of what they asked for.
    local toPay = amount and math.floor(tonumber(amount) or 0) or remaining
    if not Util.isValidAmount(toPay) or toPay > remaining then
      return false, Err.BAD_AMOUNT
    end

    local recipient = recipientAccount(bill)
    if not recipient then return false, Err.INTERNAL end

    local category = bill.kind -- 'invoice' | 'fine' | 'tax' are ledger categories
    local memoLine = Util.truncate(
      ('%s #%d%s'):format(bill.kind, bill.id, bill.memo and (' — ' .. bill.memo) or ''), 140)
    local currency = tonumber(bill.currency) or 0

    if payWith == 'wallet' then
      -- Two-phase: wallet out, recipient in, compensate if the credit fails.
      local ok, res = Money.walletDebit(payerCharid, currency, toPay,
        { category = category, memo = memoLine, source = meta.source, silent = true })
      if not ok then return false, res end
      local ok2, res2 = Money.accountCredit(recipient, currency, toPay,
        { category = category, memo = memoLine, source = meta.source })
      if not ok2 then
        Money.walletCredit(payerCharid, currency, toPay, {
          category = Constants.Category.COMPENSATION, source = 'sov_bank',
          memo = ('reversal: %s'):format(memoLine), silent = true,
        })
        return false, res2
      end
    else
      local fromId = tonumber(payWith)
      if not fromId then return false, Err.NO_ACCOUNT end
      local ok, res = Money.transfer(fromId, recipient, currency, toPay,
        { category = category, memo = memoLine, source = meta.source })
      if not ok then return false, res end
    end

    local newRemaining = remaining - toPay
    local closed = newRemaining <= 0
    if closed then
      Db.execute(
        "UPDATE sov_bank_bills SET balance_remaining = 0, status = 'paid', paid_at = NOW() WHERE id = ?",
        { bill.id })
    else
      Db.execute('UPDATE sov_bank_bills SET balance_remaining = ? WHERE id = ?',
        { newRemaining, bill.id })
    end

    if closed then
      -- Settling the debt releases anything secured against it.
      if Collections and Collections.releaseLiensForBill then
        Collections.releaseLiensForBill(bill.id)
      end
      Events.billPaid({
        billId = bill.id, payerCharid = payerCharid,
        issuerType = bill.issuer_type, issuerId = bill.issuer_id,
        amount = tonumber(bill.amount), kind = bill.kind,
        wasWarrant = bill.status == 'warrant',
      })
    end
    Log.info('bill #%d: %s paid %s (%s), remaining %s',
      bill.id, payerCharid, tostring(toPay), tostring(payWith), tostring(newRemaining))
    return true, { applied = toPay, remaining = newRemaining, closed = closed }
  end)
end

--- Cancel an open bill (issuer/admin action; export-level guard).
function Billing.cancel(billId, meta)
  billId = tonumber(billId)
  if not billId then return false, Err.NO_BILL end
  return Money.withLocks({ 'bill:' .. billId }, function()
    local bill = Billing.get(billId)
    if not bill then return false, Err.NO_BILL end
    if bill.status == 'paid' or bill.status == 'cancelled' then return false, Err.BILL_CLOSED end
    local wasWarrant = bill.status == 'warrant'
    Db.execute("UPDATE sov_bank_bills SET status = 'cancelled' WHERE id = ?", { bill.id })
    if Collections and Collections.releaseLiensForBill then
      Collections.releaseLiensForBill(bill.id)
    end
    -- A cancelled warrant must be cleared on the lawman's side too, or it
    -- hangs over the character with no debt left to pay.
    if wasWarrant then
      Events.billPaid({
        billId = bill.id, payerCharid = bill.target_charid,
        issuerType = bill.issuer_type, issuerId = bill.issuer_id,
        amount = tonumber(bill.amount), kind = bill.kind,
        wasWarrant = true, cancelled = true,
      })
    end
    Log.info('bill #%d cancelled (%s)', bill.id, (meta and meta.source) or '?')
    return true, { billId = bill.id }
  end)
end

--- Debt status by tier (design §6.1 GetDebtStatus).
function Billing.debtStatus(charid)
  local bills = Billing.listOpenFor(charid)
  local tier = 0
  local TIER = { pending = 0, overdue = 1, in_collections = 2, warrant = 3 }
  local total = 0
  for _, b in ipairs(bills) do
    local t = TIER[b.status] or 0
    if t > tier then tier = t end
    total = total + (tonumber(b.balance_remaining) or 0)
  end
  return { tier = tier, totalOwed = total, bills = bills }
end
