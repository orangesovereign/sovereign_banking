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

-- Account numbers 1–1000 are set aside for government/system accounts;
-- player accounts begin at SVB-0001001. Named entries pin specific numbers.
Config.ReservedNumbers = {
  max = 1000,                    -- last reserved number
  ['SYS-GOV']       = 1,         -- Government Fund  -> SVB-0000001
  ['SYS-INSURANCE'] = 2,         -- Insurance Fund   -> SVB-0000002
  -- Society accounts (design §5.8) — keys must match Config.Societies ids.
  ['lawman']        = 10,        -- Sheriff's Office -> SVB-0000010
  ['medical']       = 11,        -- Medical Fund     -> SVB-0000011
  ['tax_office']    = 12,        -- Tax Office       -> SVB-0000012
}

-- ============================================================================
-- Societies (design §5.8) — shared org funds owned by the bank.
-- jobs: VORP job names that belong to the society (match your jobs.json /
-- whitelist setup). bossGrade: minimum job grade for boss actions (view
-- ledger, deposit/withdraw society funds, run payroll).
-- ============================================================================
Config.Societies = {
  {
    id = 'lawman',
    name = "Sheriff's Office",
    jobs = { 'sheriff', 'deputy', 'marshal' },
    bossGrade = 3,
  },
  {
    id = 'medical',
    name = 'Medical Fund',
    jobs = { 'doctor', 'nurse' },
    bossGrade = 3,
  },
  {
    id = 'tax_office',
    name = 'Tax Office',
    jobs = { 'taxcollector' },
    bossGrade = 2,
  },
}

-- ============================================================================
-- Billing (design §5.7) — invoices are civil; fines/taxes are government debt.
-- Due windows are REAL-LIFE days from issue; the §5.14 tiers then run off
-- Config.Collections.
-- ============================================================================
Config.Billing = {
  invoiceDueDays = 3,
  fineDueDays    = 3,
  taxDueDays     = 7,
  maxOpenPerIssuer = 25,  -- anti-spam: open invoices one issuer may hold
}

-- Delinquency sweep cadence (tech spec §9.2)
Config.Scheduler = { sweepMinutes = 15 }

Config.LogLevel      = 'info'    -- debug | info | warn | error
Config.AutoRunSchema = true      -- run sql/install.sql (idempotent) on boot

-- ============================================================================
-- Teller interaction (design §5.10 — no ATMs, staffed tellers only)
-- ============================================================================
Config.Teller = {
  promptKey        = 0x760A9C6F,  -- [G] — RedM control hash for the hold-prompt
  openRange        = 2.5,         -- metres from the teller to interact (client)
  serverSlack      = 2.5,         -- extra metres allowed by the server-side gate
  nearbyRange      = 30.0,        -- client switches to per-frame checks inside this
  blipSprite       = 'blip_shop_bank',
  blipScale        = 0.2,
  spawnPeds        = true,        -- spawn a teller ped at each branch
  pedSpawnDistance = 60.0,        -- spawn/despawn distance for teller peds
}

-- ============================================================================
-- Fees (design §5.2 / §5.11 — fees fund the government insurance account)
-- ============================================================================
-- Teller transfers between two accounts you OWN use the sameBranch fee (free
-- by default); sending to anyone else's account is a "wire" and uses the
-- crossBranch fee. Collected fees credit SYS-INSURANCE (design §5.11).
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
  -- The Tax Collector job (§5.14 tier 2). Must match a Config.Societies entry:
  -- commissions and collected debt flow through that society's fund.
  collectorSociety = 'tax_office',
  seizure = {
    enabled          = true,
    requireRestraint = true,     -- the restraint resource gates this via IsSeizureAuthorized
    capToDebt        = true,     -- never seize more than owed + fees
    valuation        = 'table',  -- 'table' (priceTable below) | 'store' (economy sell prices)
    storeExport      = { resource = 'sovereign_stores', fn = 'GetSellPrice' },
    returnSurplus    = true,
    -- Fallback per-item value in minor units when valuation can't price an item.
    defaultItemValue = 100,
    priceTable = {
      -- ['gold_nugget'] = 2500, ['pocket_watch'] = 800,
    },
    -- Never seizable, whatever the debt (design §5.14).
    exemptItems = {
      'bread', 'water', 'canteen', 'consumable_medicine',
    },
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
-- Gold exchange (design §5.6) — the assayer's counter at the bank.
-- pricePerGold is money-minor per 1.00 gold; the spread (Config.Fees.
-- goldExchangeSpread) is added when buying gold and subtracted when selling.
-- ============================================================================
Config.Gold = {
  enabled      = true,
  pricePerGold = 2000,   -- $20.00 per 1.00 gold (before spread)
}

-- ============================================================================
-- Safety deposit boxes (design §5.5) — rented physical vault boxes, backed by
-- vorp_inventory stashes. Rent is per real-life period from Config.Fees.sdbRent;
-- past rent_paid_until + graceDays the box locks until rent is paid.
-- ============================================================================
Config.SDB = {
  enabled            = true,
  maxPerChar         = 2,
  rentPeriodRealDays = 7,
  graceDays          = 3,
  sizes = {
    small  = { slots = 10 },
    medium = { slots = 25 },
    large  = { slots = 50 },
  },
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
-- Admin (design §5.12) — who may open /bankadmin and force adjustments.
-- Grant the ACE in server.cfg:  add_ace group.admin banking.admin allow
-- Or list raw identifiers (license:xxxx / steam:xxxx) as a fallback.
-- ============================================================================
Config.Admin = {
  aceGroup    = 'banking.admin',
  identifiers = {},
  adjustMax   = 10000000,  -- cents; ceiling on a single force adjustment
}

-- ============================================================================
-- Migration shim (design §6.5) — mirror common VORP money signatures so
-- third-party scripts route through the bank without being rewritten.
-- Off by default: enable only if you know which resources need it.
-- ============================================================================
Config.Compat = {
  enabled = false,
  target  = 'wallet',  -- where legacy addMoney/removeMoney land
}

-- ============================================================================
-- Integrations
-- ============================================================================
-- Discord audit mirroring (tech spec §12). Categories: tx (large movements),
-- loans, admin, heist. Payloads are batched to respect rate limits.
Config.Discord = {
  enabled = false,
  webhooks = { tx = '', loans = '', admin = '', heist = '' },
  txMinAmount = 100000,   -- cents; only mirror movements at least this large
  flushSeconds = 10,
}
Config.Notify  = 'vorp'
