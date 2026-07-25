--[[
  server/modules/business.lua — business accounts & the Tax Ledger (design §5.15).

  A business's money and its tax obligation both live under the bank and are
  handled at the teller. `sovereign_stores` never holds the money: it calls
  RegisterBusiness when a property is bought, and the bank owns everything
  after that.

  THE TAX IS A LICENSE FEE, NOT A SALES TAX. There is no per-transaction cut
  anywhere in this suite. Each period the bank assesses
  `licenseRate × building_price` (default 25%) regardless of whether the shop
  sold a thing — so the fee scales with property value and makes an expensive
  building a real commitment.

  Ledger note: an ASSESSMENT is an obligation, not a movement, so it is
  recorded with account_id NULL (naming the business in the memo). Writing it
  against the business account would break `Ledger.reconcile`, which sums
  ledger rows per account and compares to the stored balance. A REMITTANCE is
  a genuine movement and goes through Money.transfer to SYS-GOV like any
  other payment.
]]

Business = {}

local Err = Constants.Err
local DAY = 86400

local function cfg()
  return Config.BusinessTax or {}
end

function Business.getLedger(businessId)
  if not businessId then return nil end
  return Db.single([[
    SELECT *, UNIX_TIMESTAMP(next_due_at) AS due_epoch,
           UNIX_TIMESTAMP(last_assessed_at) AS assessed_epoch,
           UNIX_TIMESTAMP(last_remit_at) AS remit_epoch
    FROM sov_bank_business_tax WHERE business_id = ?
  ]], { tostring(businessId) })
end

--- The business's bank account row, or nil (design §6.1 GetBusinessAccount).
function Business.account(businessId)
  if not businessId then return nil end
  return Db.single([[
    SELECT * FROM sov_bank_accounts
    WHERE owner_type = 'business' AND owner_id = ? AND status <> 'closed'
    LIMIT 1
  ]], { tostring(businessId) })
end

--- Charid of the registered owner (the 'owner' access row on the account).
function Business.owner(businessId)
  local acct = Business.account(businessId)
  if not acct then return nil end
  local row = Db.single([[
    SELECT charidentifier FROM sov_bank_access
    WHERE account_id = ? AND access_level = 'owner' LIMIT 1
  ]], { acct.id })
  return row and tostring(row.charidentifier) or nil
end

--- Whitelist check (design §6.1 IsBusinessOwner) — owner or admin access.
function Business.isOwner(charid, businessId)
  local acct = Business.account(businessId)
  if not acct then return false end
  return (Accounts.hasLevel(acct, charid, 'admin')) == true
end

--- Register a business on purchase (design §6.1 RegisterBusiness).
--- Creates the business account (owner gets an 'owner' access row) and opens
--- the Tax Ledger with the building price as the permanent tax basis.
--- Idempotent: re-registering an existing business updates the basis/owner.
function Business.register(businessId, ownerCharid, buildingPrice, opts)
  opts = opts or {}
  businessId = tostring(businessId or '')
  ownerCharid = tostring(ownerCharid or '')
  buildingPrice = math.floor(tonumber(buildingPrice) or 0)
  if businessId == '' then return false, Err.NO_BUSINESS end
  if buildingPrice < 0 then return false, Err.BAD_AMOUNT end
  if not Bridge.CharacterExists(ownerCharid) then return false, Err.UNKNOWN_CHAR end

  local acct = Business.account(businessId)
  if not acct then
    acct = Accounts.create(Constants.OwnerType.BUSINESS, businessId,
      Util.truncate(opts.name, 30) or businessId, Constants.AccountKind.BUSINESS)
    if not acct then return false, Err.INTERNAL end
  end

  -- The owner's access row is what makes the account visible at the teller.
  Db.execute([[
    INSERT INTO sov_bank_access (account_id, charidentifier, access_level, granted_by)
    VALUES (?, ?, 'owner', ?)
    ON DUPLICATE KEY UPDATE access_level = 'owner'
  ]], { acct.id, ownerCharid, opts.source or 'sov_bank' })

  local rate = tonumber(opts.licenseRate) or tonumber(cfg().licenseRate) or 0.25
  local nextDue = os.time() + math.floor((tonumber(cfg().assessEveryRealDays) or 7) * DAY)

  local existing = Business.getLedger(businessId)
  if existing then
    Db.execute([[
      UPDATE sov_bank_business_tax SET building_price = ?, license_rate = ?
      WHERE business_id = ?
    ]], { buildingPrice, rate, businessId })
  else
    Db.execute([[
      INSERT INTO sov_bank_business_tax
        (business_id, building_price, license_rate, next_due_at)
      VALUES (?, ?, ?, FROM_UNIXTIME(?))
    ]], { businessId, buildingPrice, rate, nextDue })
  end

  Log.info('business %s registered to %s (basis %s, rate %.4f)',
    businessId, ownerCharid, buildingPrice, rate)
  return true, {
    accountId = acct.id,
    accountNumber = acct.account_number,
    taxBasis = buildingPrice,
    licenseRate = rate,
  }
end

--- Assess one period's license fee (design §6.1 AssessBusinessTax).
--- Guarded by a compare-and-set on next_due_at so the scheduler and a manual
--- call can never assess the same period twice.
function Business.assess(businessId, opts)
  opts = opts or {}
  businessId = tostring(businessId or '')
  local led = Business.getLedger(businessId)
  if not led then return false, Err.NO_BUSINESS end

  local basis = tonumber(led.building_price) or 0
  local rate = tonumber(led.license_rate) or 0.25
  local amount = math.floor(basis * rate + 0.5)
  if amount <= 0 then return false, Err.BAD_AMOUNT end

  local dueEpoch = tonumber(led.due_epoch)
  local nextDue = os.time() + math.floor((tonumber(cfg().remitDueRealDays) or 7) * DAY)

  -- CAS: only the caller holding the current next_due_at advances the period.
  local affected
  if dueEpoch then
    affected = Db.execute([[
      UPDATE sov_bank_business_tax
      SET assessed = assessed + ?, balance_owed = balance_owed + ?,
          last_assessed_at = NOW(), next_due_at = FROM_UNIXTIME(?)
      WHERE business_id = ? AND next_due_at = FROM_UNIXTIME(?)
    ]], { amount, amount, nextDue, businessId, dueEpoch })
  else
    affected = Db.execute([[
      UPDATE sov_bank_business_tax
      SET assessed = assessed + ?, balance_owed = balance_owed + ?,
          last_assessed_at = NOW(), next_due_at = FROM_UNIXTIME(?)
      WHERE business_id = ? AND next_due_at IS NULL
    ]], { amount, amount, nextDue, businessId })
  end
  if not affected or affected < 1 then
    return false, Err.INTERNAL -- someone else assessed this period first
  end

  -- Obligation record (account_id NULL — see the header note).
  Ledger.write({
    tx_uuid = Util.uuid(), currency = Constants.Currency.MONEY,
    direction = 'debit', amount = amount,
    category = Constants.Category.TAX_ASSESSED,
    source_resource = opts.source or 'sov_bank',
    memo = ('Business licence tax assessed — %s'):format(businessId),
  })

  Log.info('business %s assessed %s licence tax (basis %s × %.4f)',
    businessId, amount, basis, rate)
  return true, {
    assessed = amount,
    balanceOwed = (tonumber(led.balance_owed) or 0) + amount,
    nextDueAt = nextDue,
  }
end

--- Settle business tax at the teller (design §6.1 RemitTax).
--- payWith = accountId (usually the business account) or 'wallet'.
function Business.remit(businessId, amount, payerCharid, payWith, meta)
  meta = meta or {}
  businessId = tostring(businessId or '')
  local led = Business.getLedger(businessId)
  if not led then return false, Err.NO_BUSINESS end

  local owed = tonumber(led.balance_owed) or 0
  if owed <= 0 then return false, Err.BILL_CLOSED end

  local toPay = amount and math.floor(tonumber(amount) or 0) or owed
  if not Util.isValidAmount(toPay) or toPay > owed then return false, Err.BAD_AMOUNT end

  local gov = Accounts.getSystem(Constants.SystemAccounts.GOV)
  if not gov then return false, Err.INTERNAL end
  local memoLine = ('Licence tax remittance — %s'):format(businessId)

  if payWith == 'wallet' then
    local ok, res = Money.walletDebit(payerCharid, Constants.Currency.MONEY, toPay,
      { category = Constants.Category.TAX_REMIT, memo = memoLine,
        source = meta.source, silent = true })
    if not ok then return false, res end
    local ok2, res2 = Money.accountCredit(gov.id, Constants.Currency.MONEY, toPay,
      { category = Constants.Category.TAX_REMIT, memo = memoLine, source = meta.source })
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
      { category = Constants.Category.TAX_REMIT, memo = memoLine, source = meta.source })
    if not ok then return false, res end
  end

  Db.execute([[
    UPDATE sov_bank_business_tax
    SET remitted = remitted + ?, balance_owed = GREATEST(balance_owed - ?, 0),
        last_remit_at = NOW()
    WHERE business_id = ?
  ]], { toPay, toPay, businessId })

  Log.info('business %s remitted %s (was owed %s)', businessId, toPay, owed)
  return true, { remitted = toPay, balanceOwed = math.max(0, owed - toPay) }
end

--- Every business a character can act for (teller view).
function Business.listFor(charid)
  local rows = Db.query([[
    SELECT a.owner_id AS business_id, a.id AS account_id, a.account_number,
           a.name, a.balance_money, x.access_level
    FROM sov_bank_accounts a
    JOIN sov_bank_access x ON x.account_id = a.id
    WHERE a.owner_type = 'business' AND a.status <> 'closed'
      AND x.charidentifier = ? AND x.access_level IN ('owner','admin')
    ORDER BY a.id ASC
  ]], { tostring(charid) }) or {}

  local out = {}
  for _, r in ipairs(rows) do
    local led = Business.getLedger(r.business_id)
    out[#out + 1] = {
      businessId = r.business_id,
      accountId = r.account_id,
      number = r.account_number,
      name = r.name,
      balance = tonumber(r.balance_money) or 0,
      access = r.access_level,
      tax = led and {
        basis = tonumber(led.building_price) or 0,
        rate = tonumber(led.license_rate) or 0,
        assessed = tonumber(led.assessed) or 0,
        remitted = tonumber(led.remitted) or 0,
        owed = tonumber(led.balance_owed) or 0,
        dueAt = tonumber(led.due_epoch),
      } or nil,
    }
  end
  return out
end

-- ============================================================================
-- Scheduler hooks
-- ============================================================================

--- Assess every business whose period has elapsed.
function Business.sweepAssessments(limit)
  local rows = Db.query([[
    SELECT business_id FROM sov_bank_business_tax
    WHERE next_due_at IS NOT NULL AND next_due_at <= NOW() LIMIT ?
  ]], { limit or 25 }) or {}
  for _, r in ipairs(rows) do
    Business.assess(r.business_id, { source = 'scheduler' })
  end
  return #rows
end

--- Unremitted tax past its window becomes GOVERNMENT DEBT and enters the
--- §5.14 collections pipeline against the owner (design §5.15).
--- The bill's idempotency key is derived from the business and the due
--- period, so a business is never billed twice for the same lapse.
function Business.sweepDelinquent(limit)
  if cfg().overdueBecomesGovtDebt == false then return 0 end
  local grace = math.floor((tonumber(Config.Collections.overdueAfterDays) or 3) * DAY)
  local rows = Db.query([[
    SELECT business_id, balance_owed, UNIX_TIMESTAMP(next_due_at) AS due_epoch
    FROM sov_bank_business_tax
    WHERE balance_owed > 0 AND next_due_at IS NOT NULL
      AND next_due_at < FROM_UNIXTIME(?)
    LIMIT ?
  ]], { os.time() - grace, limit or 25 }) or {}

  local opened = 0
  for _, r in ipairs(rows) do
    local owner = Business.owner(r.business_id)
    if owner then
      local ok = Billing.issue(Constants.BillKind.TAX,
        { type = 'system', id = Constants.SystemAccounts.GOV },
        owner, Constants.Currency.MONEY, tonumber(r.balance_owed),
        ('Unremitted licence tax — %s'):format(r.business_id),
        {
          source = 'sov_bank',
          idem = ('biztax:%s:%s'):format(r.business_id, tostring(r.due_epoch)),
          dueDays = 0, -- already overdue; the sweep tiers it immediately
        })
      if ok then opened = opened + 1 end
    end
  end
  if opened > 0 then
    Log.warn('business tax: %d delinquent licence(s) handed to collections', opened)
  end
  return opened
end
