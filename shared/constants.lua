--[[
  shared/constants.lua — enums, currency ids, ledger categories, error codes.
]]

Constants = {}

-- VORP currency type ids (design §2)
Constants.Currency = { MONEY = 0, GOLD = 1, ROL = 2 }

Constants.CurrencyName = { [0] = 'money', [1] = 'gold', [2] = 'rol' }

Constants.CurrencyColumn = {
  [0] = 'balance_money',
  [1] = 'balance_gold',
  [2] = 'balance_rol',
}

Constants.Direction = { CREDIT = 'credit', DEBIT = 'debit' }

Constants.OwnerType = {
  CHARACTER = 'character', SOCIETY = 'society', BUSINESS = 'business',
  JOINT = 'joint', SYSTEM = 'system',
}

Constants.AccountKind = {
  CHECKING = 'checking', SAVINGS = 'savings', SOCIETY = 'society', BUSINESS = 'business',
}

Constants.AccessLevel = {
  OWNER = 'owner', ADMIN = 'admin', WITHDRAW = 'withdraw',
  DEPOSIT = 'deposit', READ = 'read',
}

-- Access levels are strictly hierarchical (design §5.1): a higher rank can do
-- everything a lower rank can.
Constants.AccessRank = {
  read = 1, deposit = 2, withdraw = 3, admin = 4, owner = 5,
}

-- Ledger categories (design §4, open set — opts.reason may add more)
Constants.Category = {
  DEPOSIT       = 'deposit',
  WITHDRAW      = 'withdraw',
  TRANSFER      = 'transfer',
  FEE           = 'fee',
  ADD           = 'add',            -- generic external credit (API default)
  REMOVE        = 'remove',         -- generic external debit (API default)
  PAYROLL       = 'payroll',
  INVOICE       = 'invoice',
  FINE          = 'fine',
  TAX           = 'tax',
  TAX_ASSESSED  = 'tax_assessed',
  TAX_REMIT     = 'tax_remit',
  PURCHASE      = 'purchase',
  LOAN_DISBURSE = 'loan_disburse',
  LOAN_REPAY    = 'loan_repay',
  INTEREST      = 'interest',
  HEIST         = 'heist',
  ADMIN_ADJUST  = 'admin_adjust',
  COMPENSATION  = 'compensation',   -- reversal of a failed two-phase op
}

-- Reserved system account owner_ids (design §5.11)
Constants.SystemAccounts = {
  INSURANCE = 'SYS-INSURANCE', -- fee sink; the lore backing for "balances are safe"
  GOV       = 'SYS-GOV',       -- government fund: taxes, fines
}

-- Error codes (tech spec §5.2) — every mutating call returns (ok, resultOrCode)
Constants.Err = {
  BAD_AMOUNT         = 'ERR_BAD_AMOUNT',
  BAD_CURRENCY       = 'ERR_BAD_CURRENCY',
  CURRENCY_DISABLED  = 'ERR_CURRENCY_DISABLED',
  NO_ACCOUNT         = 'ERR_NO_ACCOUNT',
  ACCOUNT_CLOSED     = 'ERR_ACCOUNT_CLOSED',
  FROZEN             = 'ERR_FROZEN',
  INSUFFICIENT_FUNDS = 'ERR_INSUFFICIENT_FUNDS',
  NO_CREDIT          = 'ERR_NO_CREDIT',
  OFFLINE            = 'ERR_OFFLINE',
  WALLET_APPLY       = 'ERR_WALLET_APPLY',
  SAME_ACCOUNT       = 'ERR_SAME_ACCOUNT',
  UNKNOWN_CHAR       = 'ERR_UNKNOWN_CHAR',
  NOT_AT_BRANCH      = 'ERR_NOT_AT_BRANCH',
  ACCESS             = 'ERR_ACCESS',
  BAD_KIND           = 'ERR_BAD_KIND',
  BAD_LEVEL          = 'ERR_BAD_LEVEL',
  ACCOUNT_LIMIT      = 'ERR_ACCOUNT_LIMIT',
  NOT_EMPTY          = 'ERR_NOT_EMPTY',
  RATE_LIMITED       = 'ERR_RATE_LIMITED',
  INTERNAL           = 'ERR_INTERNAL',
}
