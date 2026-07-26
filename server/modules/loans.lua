--[[
  server/modules/loans.lua — fixed-cost loans (design §5.3).

  Interest is applied ONCE at origination: the borrower agrees to total_due
  (principal + principal × originationRate) up front; no periodic compounding.
  Lifecycle: pending → active (approved & disbursed) | denied; active → paid
  (balance_remaining hits 0) | defaulted (past due_by, scheduler).

  Money flow: disbursement credits the borrower's account as a ledgered
  faucet (category loan_disburse); repayments sink into SYS-GOV (category
  loan_repay, tech spec §8.4). Net effect per completed loan: the money
  supply shrinks by the interest — a mild, deliberate deflationary sink.

  Approval is by server console (`sovbank loan ...`) or the ApproveLoan /
  DenyLoan exports until the Phase 4 admin panel lands. Config.Loans.
  requireApproval=false auto-approves at application time.
]]

Loans = {}

local Err = Constants.Err
local DAY = 86400

function Loans.get(loanId)
  loanId = tonumber(loanId)
  if not loanId then return nil end
  return Db.single([[
    SELECT *, UNIX_TIMESTAMP(due_by) AS due_epoch,
           UNIX_TIMESTAMP(created_at) AS created_epoch
    FROM sov_bank_loans WHERE id = ?
  ]], { loanId })
end

function Loans.listFor(charid)
  return Db.query([[
    SELECT *, UNIX_TIMESTAMP(due_by) AS due_epoch,
           UNIX_TIMESTAMP(created_at) AS created_epoch
    FROM sov_bank_loans WHERE charidentifier = ?
    ORDER BY id DESC LIMIT 20
  ]], { tostring(charid) }) or {}
end

local function openCount(charid)
  return tonumber(Db.scalar([[
    SELECT COUNT(*) FROM sov_bank_loans
    WHERE charidentifier = ? AND status IN ('pending','active')
  ]], { tostring(charid) })) or 0
end

--- Apply for a loan (design §6.1 CreateLoan). rate nil → config rate.
--- Disbursement lands in accountId (must belong to the borrower — the
--- callbacks layer enforces that; exports trust their caller).
--- Returns (true, {loanId, totalDue, status}) or (false, errCode).
function Loans.create(charid, principal, rate, accountId, meta)
  meta = meta or {}
  if not (Config.Loans and Config.Loans.enabled) then return false, Err.LOANS_DISABLED end
  charid = tostring(charid)
  principal = tonumber(principal)
  if not Util.isValidAmount(principal) or principal > (Config.Loans.maxPrincipal or 500000) then
    return false, Err.BAD_AMOUNT
  end

  -- The count and the insert are serialized per borrower: without a lock, two
  -- near-simultaneous applications both see zero open loans and both succeed,
  -- letting one character hold twice the permitted debt.
  local id, totalDue
  local ok, err = Money.withLocks({ 'loanapp:' .. charid }, function()
    if openCount(charid) >= (Config.Loans.maxActivePerChar or 1) then
      return false, Err.LOAN_LIMIT
    end

    local acct = accountId and Accounts.getById(accountId) or Accounts.ensurePrimary(charid)
    if not acct or acct.status ~= 'active' then return false, Err.NO_ACCOUNT end

    rate = tonumber(rate) or Config.Loans.originationRate or 0.10
    if rate < 0 or rate > 1 then rate = Config.Loans.originationRate or 0.10 end
    totalDue = principal + math.floor(principal * rate + 0.5)

    id = Db.insert([[
      INSERT INTO sov_bank_loans
        (charidentifier, account_id, principal, total_due, balance_remaining, interest_flat, status)
      VALUES (?, ?, ?, ?, ?, ?, 'pending')
    ]], { charid, acct.id, principal, totalDue, totalDue, rate })
    if not id then return false, Err.INTERNAL end
    return true, { loanId = id }
  end)
  if not ok then return false, err end

  Log.info('loan #%d application: %s asks %s (total due %s)', id, charid, principal, totalDue)

  if Config.Loans.requireApproval == false then
    local aok, ares = Loans.approve(id, 'auto')
    if not aok then
      -- Auto-approval failed (e.g. the target account was frozen). Close the
      -- application out, or it counts against maxActivePerChar forever and the
      -- borrower can never apply again.
      Db.execute("UPDATE sov_bank_loans SET status = 'denied', approved_by = 'auto-failed' WHERE id = ? AND status = 'pending'",
        { id })
      return false, ares
    end
    return true, { loanId = id, totalDue = totalDue, status = 'active' }
  end
  return true, { loanId = id, totalDue = totalDue, status = 'pending' }
end

--- Approve & disburse (teller/admin/console). Idempotent per loan status.
function Loans.approve(loanId, approver)
  loanId = tonumber(loanId)
  if not loanId then return false, Err.NO_LOAN end
  return Money.withLocks({ 'loan:' .. loanId }, function()
    local loan = Loans.get(loanId)
    if not loan then return false, Err.NO_LOAN end
    if loan.status ~= 'pending' then return false, Err.LOAN_CLOSED end

    local termDays = tonumber(Config.Loans.defaultTermRealDays) or 0
    local dueEpoch = termDays > 0 and (os.time() + math.floor(termDays * DAY)) or nil

    local ok, res = Money.accountCredit(loan.account_id, Constants.Currency.MONEY,
      tonumber(loan.principal), {
        category = Constants.Category.LOAN_DISBURSE,
        memo = ('Loan #%d disbursement'):format(loan.id),
        source = 'sov_bank',
        idem = ('loan_disburse:%d'):format(loan.id),
      })
    if not ok then return false, res end

    if dueEpoch then
      Db.execute([[
        UPDATE sov_bank_loans SET status = 'active', approved_by = ?, due_by = FROM_UNIXTIME(?)
        WHERE id = ?
      ]], { tostring(approver or '?'), dueEpoch, loan.id })
    else
      Db.execute('UPDATE sov_bank_loans SET status = \'active\', approved_by = ? WHERE id = ?',
        { tostring(approver or '?'), loan.id })
    end
    Log.info('loan #%d approved by %s, %s disbursed to account %d',
      loan.id, tostring(approver), loan.principal, loan.account_id)
    Log.discord('loans', ('Loan #%d approved'):format(loan.id), nil, {
      { name = 'Borrower', value = tostring(loan.charidentifier), inline = true },
      { name = 'Principal', value = Util.formatAmount(tonumber(loan.principal), 0), inline = true },
      { name = 'Total due', value = Util.formatAmount(tonumber(loan.total_due), 0), inline = true },
      { name = 'By', value = tostring(approver), inline = true },
    })
    return true, { loanId = loan.id, disbursed = tonumber(loan.principal), dueBy = dueEpoch }
  end)
end

function Loans.deny(loanId, approver)
  loanId = tonumber(loanId)
  if not loanId then return false, Err.NO_LOAN end
  return Money.withLocks({ 'loan:' .. loanId }, function()
    local loan = Loans.get(loanId)
    if not loan then return false, Err.NO_LOAN end
    if loan.status ~= 'pending' then return false, Err.LOAN_CLOSED end
    Db.execute('UPDATE sov_bank_loans SET status = \'denied\', approved_by = ? WHERE id = ?',
      { tostring(approver or '?'), loan.id })
    Log.info('loan #%d denied by %s', loan.id, tostring(approver))
    return true, { loanId = loan.id }
  end)
end

--- Repay (teller). payWith = 'wallet' | accountId (access enforced by the
--- caller). amount nil → the full remaining balance. Proceeds sink to SYS-GOV.
function Loans.repay(loanId, payerCharid, payWith, amount, meta)
  meta = meta or {}
  loanId = tonumber(loanId)
  if not loanId then return false, Err.NO_LOAN end
  payerCharid = tostring(payerCharid)

  return Money.withLocks({ 'loan:' .. loanId }, function()
    local loan = Loans.get(loanId)
    if not loan then return false, Err.NO_LOAN end
    if loan.charidentifier ~= payerCharid then return false, Err.ACCESS end
    if loan.status ~= 'active' and loan.status ~= 'defaulted' then
      return false, Err.LOAN_CLOSED
    end

    local remaining = tonumber(loan.balance_remaining) or 0
    -- floor+or-0 rather than `amount and tonumber(amount) or remaining`: the
    -- latter silently repays the WHOLE loan when given a malformed amount.
    local toPay = amount and math.floor(tonumber(amount) or 0) or remaining
    if not Util.isValidAmount(toPay) or toPay > remaining then
      return false, Err.BAD_AMOUNT
    end

    local gov = Accounts.getSystem(Constants.SystemAccounts.GOV)
    if not gov then return false, Err.INTERNAL end
    local memoLine = ('Loan #%d repayment'):format(loan.id)

    if payWith == 'wallet' then
      local ok, res = Money.walletDebit(payerCharid, Constants.Currency.MONEY, toPay,
        { category = Constants.Category.LOAN_REPAY, memo = memoLine,
          source = meta.source, silent = true })
      if not ok then return false, res end
      local ok2, res2 = Money.accountCredit(gov.id, Constants.Currency.MONEY, toPay,
        { category = Constants.Category.LOAN_REPAY, memo = memoLine, source = meta.source })
      if not ok2 then
        Money.walletCredit(payerCharid, Constants.Currency.MONEY, toPay, {
          category = Constants.Category.COMPENSATION, source = 'sov_bank',
          memo = ('reversal: %s'):format(memoLine), silent = true,
        })
        return false, res2
      end
    else
      local fromId = tonumber(payWith)
      if not fromId then return false, Err.NO_ACCOUNT end
      local ok, res = Money.transfer(fromId, gov.id, Constants.Currency.MONEY, toPay,
        { category = Constants.Category.LOAN_REPAY, memo = memoLine, source = meta.source })
      if not ok then return false, res end
    end

    local newRemaining = remaining - toPay
    local closed = newRemaining <= 0
    Db.execute(closed
      and 'UPDATE sov_bank_loans SET balance_remaining = 0, status = \'paid\' WHERE id = ?'
      or 'UPDATE sov_bank_loans SET balance_remaining = ? WHERE id = ?',
      closed and { loan.id } or { newRemaining, loan.id })

    Log.info('loan #%d: %s repaid %s, remaining %s%s',
      loan.id, payerCharid, toPay, newRemaining, closed and ' (PAID)' or '')
    return true, { applied = toPay, remaining = newRemaining, closed = closed }
  end)
end

--- Scheduler: mark active loans past due_by as defaulted (design §5.3).
function Loans.sweepDefaults(limit)
  local rows = Db.query([[
    SELECT id FROM sov_bank_loans
    WHERE status = 'active' AND due_by IS NOT NULL AND due_by < NOW()
    LIMIT ?
  ]], { limit or 50 }) or {}
  for _, r in ipairs(rows) do
    Money.withLocks({ 'loan:' .. r.id }, function()
      local loan = Loans.get(r.id)
      if not loan or loan.status ~= 'active' then return true end
      Db.execute('UPDATE sov_bank_loans SET status = \'defaulted\' WHERE id = ?', { loan.id })
      Log.warn('loan #%d DEFAULTED (%s still owes %s)',
        loan.id, loan.charidentifier, loan.balance_remaining)
      Log.discord('loans', ('Loan #%d defaulted'):format(loan.id), nil, {
        { name = 'Borrower', value = tostring(loan.charidentifier), inline = true },
        { name = 'Outstanding', value = Util.formatAmount(tonumber(loan.balance_remaining), 0), inline = true },
      })
      Events.loanDefaulted({ charid = loan.charidentifier, loanId = loan.id,
        remaining = tonumber(loan.balance_remaining) })
      return true
    end)
  end
  return #rows
end

function Loans.listPending()
  return Db.query([[
    SELECT id, charidentifier, principal, total_due, created_at
    FROM sov_bank_loans WHERE status = 'pending' ORDER BY id ASC LIMIT 50
  ]]) or {}
end
