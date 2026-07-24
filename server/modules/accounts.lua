--[[
  server/modules/accounts.lua — account lifecycle (design §5.1).
  Phase 0 scope: auto-created primary checking accounts, system accounts,
  lookups. Savings/joint/shared-access flows land in Phase 1.
]]

Accounts = {}

-- System account ids are stable for the life of the server — cache the id
-- only (never the row: balances would go stale).
local systemIds = {}

-- ensurePrimary in-flight guard: prevents duplicate account creation when a
-- character load and an early export call race each other.
local ensuring = {}

function Accounts.getById(id)
  id = tonumber(id)
  if not id then return nil end
  return Db.single('SELECT * FROM sov_bank_accounts WHERE id = ?', { id })
end

function Accounts.getByNumber(accountNumber)
  if type(accountNumber) ~= 'string' then return nil end
  return Db.single('SELECT * FROM sov_bank_accounts WHERE account_number = ?', { accountNumber })
end

--- A character's primary checking account (auto-created on first load).
function Accounts.getPrimary(charid)
  charid = tostring(charid)
  return Db.single([[
    SELECT * FROM sov_bank_accounts
    WHERE owner_type = 'character' AND owner_id = ? AND kind = 'checking'
      AND status <> 'closed'
    ORDER BY id ASC LIMIT 1
  ]], { charid })
end

--- Create an account. Two-step number assignment: insert with a unique
--- placeholder, then brand it from the row id (SVB-0000123).
function Accounts.create(ownerType, ownerId, name, kind)
  local placeholder = 'TMP-' .. Util.uuid():sub(1, 18)
  local id = Db.insert([[
    INSERT INTO sov_bank_accounts (account_number, owner_type, owner_id, name, kind)
    VALUES (?, ?, ?, ?, ?)
  ]], { placeholder, ownerType, tostring(ownerId), name, kind })
  if not id then return nil end

  local number = ('%s%07d'):format(Config.AccountPrefix or 'SVB-', id)
  Db.execute('UPDATE sov_bank_accounts SET account_number = ? WHERE id = ?', { number, id })

  if ownerType == Constants.OwnerType.CHARACTER then
    Db.insert([[
      INSERT IGNORE INTO sov_bank_access (account_id, charidentifier, access_level, granted_by)
      VALUES (?, ?, 'owner', ?)
    ]], { id, tostring(ownerId), tostring(ownerId) })
  end

  Log.info('created account %s (%s/%s, kind=%s)', number, ownerType, tostring(ownerId), kind)
  return Accounts.getById(id)
end

--- Get-or-create the primary checking account (design §5.1: auto-created on
--- first character load).
function Accounts.ensurePrimary(charid)
  charid = tostring(charid)
  -- Take the guard BEFORE the first DB read: there is no yield between the
  -- while-check and the set, so two coroutines can never both enter create.
  while ensuring[charid] do Wait(0) end
  ensuring[charid] = true

  local ok, result = pcall(function()
    local existing = Accounts.getPrimary(charid)
    if existing then return existing end
    return Accounts.create(Constants.OwnerType.CHARACTER, charid, 'Checking',
      Constants.AccountKind.CHECKING)
  end)
  ensuring[charid] = nil

  if not ok then
    Log.error('ensurePrimary failed for %s: %s', charid, tostring(result))
    return nil
  end
  return result
end

--- System accounts (design §5.11): SYS-INSURANCE, SYS-GOV.
function Accounts.getSystem(key)
  local id = systemIds[key]
  if id then return Accounts.getById(id) end
  local row = Db.single([[
    SELECT * FROM sov_bank_accounts
    WHERE owner_type = 'system' AND owner_id = ? LIMIT 1
  ]], { key })
  if row then systemIds[key] = row.id end
  return row
end

--- Idempotent first-boot seeding (tech spec §15.4).
function Accounts.ensureSystemAccounts()
  local seeds = {
    { key = Constants.SystemAccounts.INSURANCE, name = 'Insurance Fund' },
    { key = Constants.SystemAccounts.GOV,       name = 'Government Fund' },
  }
  for _, seed in ipairs(seeds) do
    if not Accounts.getSystem(seed.key) then
      local acct = Accounts.create(Constants.OwnerType.SYSTEM, seed.key, seed.name,
        Constants.AccountKind.CHECKING)
      if acct then
        -- Brand system accounts by their role, not a numeric id.
        Db.execute('UPDATE sov_bank_accounts SET account_number = ? WHERE id = ?',
          { 'SVB-' .. seed.key, acct.id })
        systemIds[seed.key] = acct.id
      end
    end
  end
end
