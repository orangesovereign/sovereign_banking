--[[
  server/api/exports.lua — the integration surface other Sovereign scripts call
  (design §6.1, Phase 0 subset). Every mutating export returns
  (ok: boolean, resultOrErrorCode) and never throws.

  Phase 0 exports: AddMoney, RemoveMoney, CanAfford, GetWalletBalance,
  GetBankBalance, GetPrimaryAccount, Transfer, Deposit, Withdraw,
  GetTransactions, Reconcile.
]]

API = {}

local Err = Constants.Err

--- Normalize the shared opts table (design §6.1) into engine meta.
--- GetInvokingResource() attributes the ledger row to the calling script.
local function buildMeta(opts, defaultCategory)
  opts = type(opts) == 'table' and opts or {}
  local invoker
  pcall(function() invoker = GetInvokingResource() end)
  return {
    category = Util.truncate(opts.reason, 40) or defaultCategory,
    memo     = Util.truncate(opts.memo, 140),
    source   = opts.source or invoker or GetCurrentResourceName(),
    idem     = type(opts.idem) == 'string' and opts.idem or nil,
    silent   = opts.silent == true,
    allowNeg = opts.allowNeg == true,
  }
end

--- Resolve opts.target ('wallet' | 'bank' | accountId) for a character.
--- 'bank' means the primary checking account (created if missing).
local function resolveTarget(charid, opts)
  local target = (type(opts) == 'table' and opts.target) or 'wallet'
  if target == 'wallet' then return 'wallet', nil end
  if target == 'bank' then
    local acct = Accounts.ensurePrimary(charid)
    if not acct then return nil, Err.NO_ACCOUNT end
    return 'account', acct.id
  end
  local id = tonumber(target)
  if not id then return nil, Err.NO_ACCOUNT end
  return 'account', id
end

-- ============================================================================
-- Core money movement
-- ============================================================================

--- ADD money to a character (wallet by default, or bank via opts.target).
function API.AddMoney(charid, currency, amount, opts)
  local meta = buildMeta(opts, Constants.Category.ADD)
  local kind, accountId = resolveTarget(charid, opts)
  if not kind then return false, accountId end
  if kind == 'wallet' then
    return Money.walletCredit(charid, currency, amount, meta)
  end
  return Money.accountCredit(accountId, currency, amount, meta)
end

--- REMOVE money. Fails cleanly (false, code) on insufficient funds.
function API.RemoveMoney(charid, currency, amount, opts)
  local meta = buildMeta(opts, Constants.Category.REMOVE)
  local kind, accountId = resolveTarget(charid, opts)
  if not kind then return false, accountId end
  if kind == 'wallet' then
    return Money.walletDebit(charid, currency, amount, meta)
  end
  return Money.accountDebit(accountId, currency, amount, meta)
end

--- Can this character afford it? No mutation. Returns a plain boolean.
function API.CanAfford(charid, currency, amount, opts)
  if not Util.isValidAmount(amount) then return false end
  local kind, accountId = resolveTarget(charid, opts)
  if not kind then return false end
  if kind == 'wallet' then
    local src = Bridge.GetSourceFromCharId(tostring(charid))
    if not src then return false end
    local bal = Bridge.WalletGet(src, currency)
    return (bal or 0) >= amount
  end
  local acct = Accounts.getById(accountId)
  if not acct or acct.status ~= 'active' then return false end
  local bal = tonumber(acct[Constants.CurrencyColumn[currency] or '']) or 0
  return bal >= amount
end

-- ============================================================================
-- Reads
-- ============================================================================

--- Wallet balance in minor units, or nil if the character is offline.
function API.GetWalletBalance(charid, currency)
  local src = Bridge.GetSourceFromCharId(tostring(charid))
  if not src then return nil end
  return Bridge.WalletGet(src, currency)
end

--- Bank balance in minor units, or nil if the account doesn't exist.
function API.GetBankBalance(accountId, currency)
  local acct = Accounts.getById(accountId)
  if not acct then return nil end
  local col = Constants.CurrencyColumn[currency]
  if not col then return nil end
  return tonumber(acct[col]) or 0
end

--- Primary checking account row (balances in minor units), or nil.
function API.GetPrimaryAccount(charid)
  return Accounts.getPrimary(charid)
end

--- Ledger query (design §6.1). filterOpts: limit, offset, category, currency,
--- since (epoch), before (epoch).
function API.GetTransactions(accountId, filterOpts)
  return Ledger.getTransactions(accountId, filterOpts)
end

-- ============================================================================
-- Bank-account movement
-- ============================================================================

--- Atomic account→account transfer; fee (if any) routes to SYS-INSURANCE.
--- opts.crossBranch selects the wire fee.
function API.Transfer(fromAccountId, toAccountId, currency, amount, opts)
  local meta = buildMeta(opts, Constants.Category.TRANSFER)
  meta.crossBranch = type(opts) == 'table' and opts.crossBranch == true or nil
  return Money.transfer(fromAccountId, toAccountId, currency, amount, meta)
end

--- Wallet → bank. Character must be online (the teller flow in Phase 1 calls
--- this via proximity-gated callbacks; exports exist for trusted scripts).
function API.Deposit(charid, accountId, currency, amount, opts)
  local meta = buildMeta(opts, Constants.Category.DEPOSIT)
  return Money.deposit(charid, accountId, currency, amount, meta)
end

--- Bank → wallet. Character must be online.
function API.Withdraw(charid, accountId, currency, amount, opts)
  local meta = buildMeta(opts, Constants.Category.WITHDRAW)
  return Money.withdraw(charid, accountId, currency, amount, meta)
end

-- ============================================================================
-- Societies (design §6.1 — law, medical, tax office, gangs)
-- ============================================================================

function API.AddToSociety(society, currency, amount, opts)
  return Society.credit(society, currency, amount, buildMeta(opts, Constants.Category.ADD))
end

function API.RemoveFromSociety(society, currency, amount, opts)
  return Society.debit(society, currency, amount, buildMeta(opts, Constants.Category.REMOVE))
end

--- Balance in minor units, or nil for an unknown society.
function API.GetSocietyBalance(society, currency)
  return Society.balance(society, currency)
end

--- Society account row (id, number, balances), or nil.
function API.GetSocietyAccount(society)
  return Society.account(society)
end

--- Atomic batch payroll (tech spec §8.3). payrollTable:
--- { {charid=, amount=, memo=}, ... } — amounts in minor units, paid into
--- each hand's primary bank account. All-or-nothing.
function API.RunPayroll(society, payrollTable, opts)
  return Society.payroll(society, payrollTable, buildMeta(opts, Constants.Category.PAYROLL))
end

-- ============================================================================
-- Bills (design §6.1) — invoices civil, fines/taxes government
-- ============================================================================

--- Civil invoice: character or society bills a character.
--- issuer = charid string, or { type='society', id='sheriff' }.
function API.IssueInvoice(issuer, targetCharid, currency, amount, memo, opts)
  local meta = buildMeta(opts, Constants.Category.INVOICE)
  local who
  if type(issuer) == 'table' and issuer.type == 'society' then
    who = { type = 'society', id = issuer.id }
  else
    who = { type = 'character', id = tostring(issuer) }
  end
  return Billing.issue(Constants.BillKind.INVOICE, who, targetCharid, currency,
    amount, memo, { dueDays = opts and opts.dueDays, source = meta.source, idem = meta.idem })
end

--- Government fine (called by the lawman script — design §6.4).
function API.IssueFine(targetCharid, currency, amount, memo, opts)
  local meta = buildMeta(opts, Constants.Category.FINE)
  return Billing.issue(Constants.BillKind.FINE, { type = 'system', id = 'SYS-GOV' },
    targetCharid, currency, amount, memo,
    { dueDays = opts and opts.dueDays, source = meta.source, idem = meta.idem })
end

--- Government tax (called by the Tax Office — design §5.7).
function API.LevyTax(targetCharid, currency, amount, memo, opts)
  local meta = buildMeta(opts, Constants.Category.TAX)
  return Billing.issue(Constants.BillKind.TAX, { type = 'system', id = 'SYS-GOV' },
    targetCharid, currency, amount, memo,
    { dueDays = opts and opts.dueDays, source = meta.source, idem = meta.idem })
end

--- Settle a bill on a character's behalf (booking desk auto-debit, etc.).
--- payWith = 'wallet' | accountId. amount nil = pay in full.
function API.PayBill(billId, payerCharid, payWith, amount, opts)
  local meta = buildMeta(opts, nil)
  return Billing.pay(billId, payerCharid, payWith or 'wallet', amount, { source = meta.source })
end

--- Cancel an open bill (issuer-side tooling).
function API.CancelBill(billId, opts)
  local meta = buildMeta(opts, nil)
  return Billing.cancel(billId, { source = meta.source })
end

--- What a character owes, by tier (design §6.1 GetDebtStatus).
function API.GetDebtStatus(charid)
  return Billing.debtStatus(charid)
end

-- ============================================================================
-- Loans (design §6.1) & gold
-- ============================================================================

--- Loan application. rate nil → Config.Loans.originationRate. opts.accountId
--- targets a specific disbursement account (defaults to the primary).
function API.CreateLoan(charid, principal, rate, opts)
  local meta = buildMeta(opts, Constants.Category.LOAN_DISBURSE)
  return Loans.create(charid, principal, rate,
    type(opts) == 'table' and opts.accountId or nil, { source = meta.source })
end

function API.ApproveLoan(loanId, approver)
  return Loans.approve(loanId, approver or 'export')
end

function API.DenyLoan(loanId, approver)
  return Loans.deny(loanId, approver or 'export')
end

function API.GetLoans(charid)
  return Loans.listFor(charid)
end

--- Current assayer quotes: { buy, sell } in money-minor per 1.00 gold.
function API.GetGoldQuote()
  return Gold.quote()
end

-- ============================================================================
-- Heist / branch cash reserve (design §6.1, §5.11)
-- ============================================================================
-- These NEVER touch a player or society account balance. The only pool they
-- read or move is the branch's physical cash reserve.

--- Cash on hand at a branch, in minor units. nil for an unknown branch.
function API.GetBranchReserve(branchId, currency)
  return Heist.getReserve(branchId, currency or Constants.Currency.MONEY)
end

--- Collect a branch's till (called by the heist/robbery resource).
--- opts: { fraction | amount, looters = charid|{charid,...}, idem, source }
--- Returns (ok, {looted, remaining, paid}) — auto-caps to what is on hand.
function API.ClaimBranchReserve(branchId, currency, opts)
  return Heist.claim(branchId, currency or Constants.Currency.MONEY, opts)
end

-- ============================================================================
-- Ops
-- ============================================================================

--- Ledger-vs-balance reconciliation report for one account (tech spec §5.6).
function API.Reconcile(accountId)
  return Ledger.reconcile(accountId)
end

--- Money-supply telemetry over a window of real-life days (design §5.12).
function API.GetMoneySupply(windowDays)
  return Admin.moneySupply(windowDays)
end

-- ============================================================================
-- Registration
-- ============================================================================

exports('AddMoney', API.AddMoney)
exports('RemoveMoney', API.RemoveMoney)
exports('CanAfford', API.CanAfford)
exports('GetWalletBalance', API.GetWalletBalance)
exports('GetBankBalance', API.GetBankBalance)
exports('GetPrimaryAccount', API.GetPrimaryAccount)
exports('Transfer', API.Transfer)
exports('Deposit', API.Deposit)
exports('Withdraw', API.Withdraw)
exports('GetTransactions', API.GetTransactions)
exports('Reconcile', API.Reconcile)
-- Phase 2: societies & billing
exports('AddToSociety', API.AddToSociety)
exports('RemoveFromSociety', API.RemoveFromSociety)
exports('GetSocietyBalance', API.GetSocietyBalance)
exports('GetSocietyAccount', API.GetSocietyAccount)
exports('RunPayroll', API.RunPayroll)
exports('IssueInvoice', API.IssueInvoice)
exports('IssueFine', API.IssueFine)
exports('LevyTax', API.LevyTax)
exports('PayBill', API.PayBill)
exports('CancelBill', API.CancelBill)
exports('GetDebtStatus', API.GetDebtStatus)
-- Phase 3: loans & gold
exports('CreateLoan', API.CreateLoan)
exports('ApproveLoan', API.ApproveLoan)
exports('DenyLoan', API.DenyLoan)
exports('GetLoans', API.GetLoans)
exports('GetGoldQuote', API.GetGoldQuote)
-- Phase 4: heist reserve & ops
exports('GetBranchReserve', API.GetBranchReserve)
exports('ClaimBranchReserve', API.ClaimBranchReserve)
exports('GetMoneySupply', API.GetMoneySupply)
