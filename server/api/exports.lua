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
-- Ops
-- ============================================================================

--- Ledger-vs-balance reconciliation report for one account (tech spec §5.6).
function API.Reconcile(accountId)
  return Ledger.reconcile(accountId)
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
