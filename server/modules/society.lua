--[[
  server/modules/society.lua — society/faction funds & payroll (design §5.8).

  Societies are config-declared (Config.Societies), own a bank account seeded
  at boot with a reserved number (1–1000 range), and are accessed by JOB, not
  by the access table: membership and boss rights come from the character's
  VORP job + grade. Sovereign Bank owns society funds outright — the lawman,
  medical, and stores scripts read/mutate them only through the exports.

  Payroll (tech spec §8.3) is one atomic disburse: society debited once, every
  employee's PRIMARY BANK ACCOUNT credited — works for offline characters, and
  the wage is waiting at the bank next time they ride into town (design §6.1
  note: only wallet payouts require presence).
]]

Society = {}

local byId = {}
local byJob = {}

local function rebuildIndexes()
  byId, byJob = {}, {}
  for _, soc in ipairs(Config.Societies or {}) do
    byId[soc.id] = soc
    for _, job in ipairs(soc.jobs or {}) do
      byJob[job] = soc
    end
  end
end
rebuildIndexes()

--- Config entry for a society id, or nil.
function Society.get(societyId)
  return byId[tostring(societyId)]
end

--- The society a VORP job belongs to, or nil.
function Society.forJob(jobName)
  return jobName and byJob[tostring(jobName)] or nil
end

--- The society a connected player belongs to (via their job), plus boss flag.
function Society.forSource(src)
  local job, grade = Bridge.GetJob(src)
  local soc = Society.forJob(job)
  if not soc then return nil end
  return soc, grade >= (soc.bossGrade or 3)
end

--- Society bank account row, or nil.
function Society.account(societyId)
  local soc = Society.get(societyId)
  if not soc then return nil end
  return Db.single([[
    SELECT * FROM sovereign_banking_accounts
    WHERE owner_type = 'society' AND owner_id = ? AND status <> 'closed'
    LIMIT 1
  ]], { soc.id })
end

--- Balance in minor units (design §6.1 GetSocietyBalance), or nil.
function Society.balance(societyId, currency)
  local acct = Society.account(societyId)
  if not acct then return nil end
  local col = Constants.CurrencyColumn[currency]
  return col and (tonumber(acct[col]) or 0) or nil
end

--- Credit/debit society funds (export backing). meta as engine meta.
function Society.credit(societyId, currency, amount, meta)
  local acct = Society.account(societyId)
  if not acct then return false, Constants.Err.NO_SOCIETY end
  return Money.accountCredit(acct.id, currency, amount, meta)
end

function Society.debit(societyId, currency, amount, meta)
  local acct = Society.account(societyId)
  if not acct then return false, Constants.Err.NO_SOCIETY end
  return Money.accountDebit(acct.id, currency, amount, meta)
end

--- Employee roster (config jobs → VORP characters), for the boss payroll view.
function Society.roster(societyId)
  local soc = Society.get(societyId)
  if not soc then return {} end
  return Bridge.GetCharactersByJob(soc.jobs or {})
end

--- Atomic payroll (design §6.1 RunPayroll, tech spec §8.3).
--- entries: { {charid=, amount=, memo=}, ... }. Amounts in minor units.
--- Duplicate charids are folded together. Every payee is paid into their
--- primary checking account (auto-created if missing). Returns
--- (true, {paid={...}, total, txId}) or (false, errCode).
function Society.payroll(societyId, entries, meta)
  meta = meta or {}
  local soc = Society.get(societyId)
  if not soc then return false, Constants.Err.NO_SOCIETY end
  local acct = Society.account(societyId)
  if not acct then return false, Constants.Err.NO_SOCIETY end
  if type(entries) ~= 'table' or #entries == 0 then
    return false, Constants.Err.PAYROLL_EMPTY
  end

  -- Fold duplicates and resolve each payee to their primary account.
  local byCharid, order = {}, {}
  for _, e in ipairs(entries) do
    local charid = e and tostring(e.charid or '')
    local amount = tonumber(e and e.amount)
    if charid == '' or not Util.isValidAmount(amount) then
      return false, Constants.Err.BAD_AMOUNT
    end
    if byCharid[charid] then
      byCharid[charid].amount = byCharid[charid].amount + amount
    else
      byCharid[charid] = { charid = charid, amount = amount, memo = e.memo }
      order[#order + 1] = charid
    end
  end

  local credits, paid = {}, {}
  for _, charid in ipairs(order) do
    local e = byCharid[charid]
    if not Bridge.CharacterExists(charid) then
      return false, Constants.Err.UNKNOWN_CHAR
    end
    local target = Accounts.ensurePrimary(charid)
    if not target then return false, Constants.Err.NO_ACCOUNT end
    credits[#credits + 1] = {
      accountId = target.id,
      amount = e.amount,
      memo = Util.truncate(e.memo, 140) or ('%s payroll'):format(soc.name),
    }
    paid[#paid + 1] = { charid = charid, accountId = target.id, amount = e.amount }
  end

  local ok, res = Money.disburse(acct.id, credits, Constants.Currency.MONEY, {
    category = Constants.Category.PAYROLL,
    memo = meta.memo or ('%s payroll'):format(soc.name),
    source = meta.source,
    idem = meta.idem,
    allowNeg = meta.allowNeg,
  })
  if not ok then return false, res end

  Log.info('payroll: %s paid %d hands, total %s (tx %s)',
    soc.id, #paid, tostring(res.total), tostring(res.txId))
  return true, { paid = paid, total = res.total, txId = res.txId, replayed = res.replayed }
end

--- Boot seeding: a bank account per configured society, pinned to its
--- reserved number when one is configured (design §5.1 reserved range).
function Society.ensureAccounts()
  rebuildIndexes()
  local reserved = Config.ReservedNumbers or {}
  local prefix = Config.AccountPrefix or 'SVB-'
  for _, soc in ipairs(Config.Societies or {}) do
    local existing = Society.account(soc.id)
    local num = reserved[soc.id]
    if not existing then
      if num then
        local number = ('%s%07d'):format(prefix, num)
        Db.execute([[
          INSERT IGNORE INTO sovereign_banking_accounts (id, account_number, owner_type, owner_id, name, kind)
          VALUES (?, ?, 'society', ?, ?, 'society')
        ]], { num, number, soc.id, soc.name })
        existing = Society.account(soc.id)
        if existing then Log.info('seeded society account %s as %s', soc.id, number) end
      else
        existing = Accounts.create(Constants.OwnerType.SOCIETY, soc.id, soc.name,
          Constants.AccountKind.SOCIETY)
      end
      if not existing then Log.error('failed to seed society account %s', soc.id) end
    elseif num then
      local wanted = ('%s%07d'):format(prefix, num)
      if existing.account_number ~= wanted then
        local clash = Accounts.getByNumber(wanted)
        if clash and clash.id ~= existing.id then
          Log.error('cannot brand society %s as %s: number already held by account id %s',
            soc.id, wanted, tostring(clash.id))
        else
          Db.execute('UPDATE sovereign_banking_accounts SET account_number = ? WHERE id = ?',
            { wanted, existing.id })
          Log.info('rebranded society account %s as %s', soc.id, wanted)
        end
      end
    end
  end
end
