--[[
  config/config.lua — tunables (design spec §8).
  Design rule: content and tuning live here; logic lives in code.
]]

Config = Config or {}

-- ============================================================================
-- General
-- ============================================================================
Config.Currencies    = { money = true, gold = true, rol = false } -- VORP ids 0/1/2
Config.StoreAsCents  = true      -- all amounts are integer minor units (cents)
Config.MaxAccounts   = 4         -- per character (enforced in Phase 1 UI flows)
Config.AccountPrefix = 'SVB-'    -- account numbers look like SVB-0000123

Config.LogLevel      = 'info'    -- debug | info | warn | error
Config.AutoRunSchema = true      -- run sql/install.sql (idempotent) on boot

-- ============================================================================
-- Fees (design §5.2 / §5.11 — fees fund the government insurance account)
-- ============================================================================
Config.Fees = {
  transferSameBranch  = { type = 'flat',    value = 0 },
  transferCrossBranch = { type = 'percent', value = 0.01 }, -- "wire" between banks
  goldExchangeSpread  = 0.05,
  sdbRent = { small = 500, medium = 1500, large = 4000 },   -- cents / rental period
  routeFeesTo = 'SYS-INSURANCE',
}

-- ============================================================================
-- Heist / branch cash reserve (design §5.11) — player balances are NEVER at risk
-- ============================================================================
Config.Heist = {
  reserveDefault   = 250000,        -- cents, base vault cash on hand per branch
  payoutRange      = { 0.4, 0.8 },  -- fraction of current reserve a heist yields
  replenishRealHrs = 48,            -- real-life hours to refill an emptied reserve
}

-- ============================================================================
-- Savings interest (design §5.4) — savings-only, real-life days
-- ============================================================================
Config.Interest = {
  savingsOnly     = true,
  savingsAPR      = 0.02,
  accrualRealDays = 7,
  catchUpCap      = 4,   -- max periods paid at once after a long offline stretch
}

-- ============================================================================
-- Credit / overdraft master toggle (design §5.3)
-- ============================================================================
Config.Credit = {
  enabled = false,
}

-- ============================================================================
-- Delinquency & collections (design §5.14)
-- ============================================================================
Config.Collections = {
  lateFee              = { type = 'percent', value = 0.05 },
  overdueAfterDays     = 3,   -- real-life days past due_at → tier 1 (overdue)
  collectionsAfterDays = 7,   -- real-life days overdue → tier 2 (Tax Collector)
  taxCollectorCommission = 0.10,
  liensEnabled         = true,
  seizure = {
    enabled          = true,
    requireRestraint = true,
    capToDebt        = true,
    valuation        = 'store',  -- 'store' | 'table'
    returnSurplus    = true,
    exemptItems      = {},
  },
  -- Tier 3 / arrestable threshold — GOVERNMENT DEBT ONLY (invoices never reach it)
  arrestable = {
    enabled               = true,
    minAmount             = 5000, -- cents
    minOverdueDays        = 14,   -- real-life days
    allowManualEscalation = true,
  },
}

-- ============================================================================
-- Loans (design §5.3) — fixed-cost: interest applied once at origination
-- ============================================================================
Config.Loans = {
  enabled             = true,
  requireApproval     = true,
  maxPrincipal        = 500000,
  originationRate     = 0.10,
  maxActivePerChar    = 1,
  defaultTermRealDays = 14,   -- 0 = no term
}

-- ============================================================================
-- Business tax (design §5.15) — NO sales tax; flat license fee per period
-- ============================================================================
Config.BusinessTax = {
  licenseRate            = 0.25, -- per period = 25% of building purchase price
  assessEveryRealDays    = 7,
  remitDueRealDays       = 7,
  overdueBecomesGovtDebt = true,
}

-- ============================================================================
-- Integrations
-- ============================================================================
Config.Discord = { enabled = false, webhooks = { tx = '', loans = '', admin = '' } }
Config.Notify  = 'vorp'
