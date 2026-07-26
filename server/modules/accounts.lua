--[[
  server/modules/accounts.lua — account lifecycle (design §5.1).
  Auto-created primary checking accounts, system accounts, named/savings
  accounts, shared access by level, close-at-zero.
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
    -- The access row is what makes the account visible to its owner:
    -- listForChar inner-joins on it, so an account without one holds money
    -- nobody can reach through the teller. Failure is logged, and
    -- repairOwnerAccess() backfills it on the next boot.
    if Db.insert([[
      INSERT IGNORE INTO sov_bank_access (account_id, charidentifier, access_level, granted_by)
      VALUES (?, ?, 'owner', ?)
    ]], { id, tostring(ownerId), tostring(ownerId) }) == nil then
      Log.error('account %s created but its owner access row did not write — it will be invisible until repaired',
        number)
    end
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

-- ============================================================================
-- Access levels (design §5.1). Strictly hierarchical; the owner row is
-- implicit from ownership and can never be granted, changed, or revoked.
-- ============================================================================

local RANK = Constants.AccessRank

--- Effective access level of charid on an account ('owner'..'read'), or nil.
--- Accepts an account row or an id.
function Accounts.getAccessLevel(account, charid)
  charid = tostring(charid)
  local acct = type(account) == 'table' and account or Accounts.getById(account)
  if not acct then return nil end
  if acct.owner_type == Constants.OwnerType.CHARACTER
    and tostring(acct.owner_id) == charid then
    return 'owner'
  end
  local row = Db.single(
    'SELECT access_level FROM sov_bank_access WHERE account_id = ? AND charidentifier = ?',
    { acct.id, charid })
  return row and row.access_level or nil
end

--- True when charid holds `needed` level or better. Second return = level.
function Accounts.hasLevel(account, charid, needed)
  local level = Accounts.getAccessLevel(account, charid)
  if not level or not RANK[needed] then return false, level end
  return RANK[level] >= RANK[needed], level
end

--- Every non-closed account this character can see (their own + shared).
function Accounts.listForChar(charid)
  charid = tostring(charid)
  return Db.query([[
    SELECT a.*, x.access_level
    FROM sov_bank_accounts a
    JOIN sov_bank_access x ON x.account_id = a.id
    WHERE x.charidentifier = ? AND a.status <> 'closed'
    ORDER BY a.id ASC
  ]], { charid }) or {}
end

--- Access roster for an account (management view).
function Accounts.listAccess(accountId)
  return Db.query([[
    SELECT charidentifier, access_level, granted_by,
           UNIX_TIMESTAMP(created_at) AS created_at
    FROM sov_bank_access WHERE account_id = ?
    ORDER BY id ASC
  ]], { tonumber(accountId) }) or {}
end

--- Grant (or update) shared access. Rules (design §5.1):
--- admin+ can grant; only the owner grants/overwrites 'admin'; the owner row
--- is untouchable; grantee must be a real character.
function Accounts.grantAccess(accountId, granterCharid, targetCharid, level)
  granterCharid, targetCharid = tostring(granterCharid), tostring(targetCharid)
  if not RANK[level] or level == 'owner' then return false, Constants.Err.BAD_LEVEL end

  local acct = Accounts.getById(accountId)
  if not acct then return false, Constants.Err.NO_ACCOUNT end
  if acct.status ~= 'active' then return false, Constants.Err.FROZEN end
  if targetCharid == granterCharid then return false, Constants.Err.ACCESS end
  if acct.owner_type == Constants.OwnerType.CHARACTER
    and tostring(acct.owner_id) == targetCharid then
    return false, Constants.Err.ACCESS
  end

  local granterLevel = Accounts.getAccessLevel(acct, granterCharid)
  if not granterLevel or RANK[granterLevel] < RANK.admin then
    return false, Constants.Err.ACCESS
  end
  if level == 'admin' and granterLevel ~= 'owner' then
    return false, Constants.Err.ACCESS
  end
  -- An admin may not overwrite another admin's grant — owner only.
  local existing = Accounts.getAccessLevel(acct, targetCharid)
  if existing == 'admin' and granterLevel ~= 'owner' then
    return false, Constants.Err.ACCESS
  end

  if not Bridge.CharacterExists(targetCharid) then
    return false, Constants.Err.UNKNOWN_CHAR
  end

  Db.execute([[
    INSERT INTO sov_bank_access (account_id, charidentifier, access_level, granted_by)
    VALUES (?, ?, ?, ?)
    ON DUPLICATE KEY UPDATE access_level = VALUES(access_level), granted_by = VALUES(granted_by)
  ]], { acct.id, targetCharid, level, granterCharid })

  Log.info('access: %s granted %s on account %s to %s',
    granterCharid, level, acct.account_number, targetCharid)
  return true, { level = level }
end

--- Revoke shared access. admin+ may revoke below-admin; owner may revoke
--- anyone; anyone (except the owner) may remove themselves.
function Accounts.revokeAccess(accountId, granterCharid, targetCharid)
  granterCharid, targetCharid = tostring(granterCharid), tostring(targetCharid)
  local acct = Accounts.getById(accountId)
  if not acct then return false, Constants.Err.NO_ACCOUNT end
  if acct.owner_type == Constants.OwnerType.CHARACTER
    and tostring(acct.owner_id) == targetCharid then
    return false, Constants.Err.ACCESS -- the owner row is untouchable
  end

  local isSelf = granterCharid == targetCharid
  if not isSelf then
    local granterLevel = Accounts.getAccessLevel(acct, granterCharid)
    if not granterLevel or RANK[granterLevel] < RANK.admin then
      return false, Constants.Err.ACCESS
    end
    local targetLevel = Accounts.getAccessLevel(acct, targetCharid)
    if targetLevel == 'admin' and granterLevel ~= 'owner' then
      return false, Constants.Err.ACCESS
    end
  end

  Db.execute('DELETE FROM sov_bank_access WHERE account_id = ? AND charidentifier = ?',
    { acct.id, targetCharid })
  Log.info('access: %s revoked account %s access for %s',
    granterCharid, acct.account_number, targetCharid)
  return true
end

-- ============================================================================
-- Named / savings accounts & close (design §5.1)
-- ============================================================================

--- Open an additional account for a character, respecting Config.MaxAccounts.
--- Returns (accountRow) or (nil, errCode).
--- Serialized per character: the cap check and the insert straddle a yield, so
--- without a lock two simultaneous requests both see room and both create.
function Accounts.createNamed(charid, name, kind)
  charid = tostring(charid)
  if kind ~= Constants.AccountKind.CHECKING and kind ~= Constants.AccountKind.SAVINGS then
    return nil, Constants.Err.BAD_KIND
  end

  local ok, result = Money.withLocks({ 'newacct:' .. charid }, function()
    local count = Db.scalar([[
      SELECT COUNT(*) FROM sov_bank_accounts
      WHERE owner_type = 'character' AND owner_id = ? AND status <> 'closed'
    ]], { charid })
    -- A failed count must not read as "no accounts" and wave the cap through.
    if count == nil then return false, Constants.Err.INTERNAL end
    if (tonumber(count) or 0) >= (Config.MaxAccounts or 4) then
      return false, Constants.Err.ACCOUNT_LIMIT
    end

    local clean = type(name) == 'string' and name:gsub('^%s+', ''):gsub('%s+$', '') or ''
    if #clean == 0 then
      clean = kind == Constants.AccountKind.SAVINGS and 'Savings' or 'Checking'
    end

    local acct = Accounts.create(Constants.OwnerType.CHARACTER, charid,
      Util.truncate(clean, 30), kind)
    if not acct then return false, Constants.Err.INTERNAL end
    return true, acct
  end)

  if not ok then return nil, result end
  return result
end

--- Close an account: owner only, all balances zero (design §5.1). Runs under
--- the account mutex so it can't race an in-flight movement.
function Accounts.close(accountId, charid)
  charid = tostring(charid)
  accountId = tonumber(accountId)
  if not accountId then return false, Constants.Err.NO_ACCOUNT end

  return Money.withLocks({ 'acct:' .. accountId }, function()
    local acct = Accounts.getById(accountId)
    if not acct then return false, Constants.Err.NO_ACCOUNT end
    if acct.status == 'closed' then return false, Constants.Err.ACCOUNT_CLOSED end
    if Accounts.getAccessLevel(acct, charid) ~= 'owner' then
      return false, Constants.Err.ACCESS
    end
    for _, col in pairs(Constants.CurrencyColumn) do
      if (tonumber(acct[col]) or 0) ~= 0 then
        return false, Constants.Err.NOT_EMPTY
      end
    end
    Db.execute("UPDATE sov_bank_accounts SET status = 'closed' WHERE id = ?", { acct.id })
    Log.info('account %s closed by %s', acct.account_number, charid)
    return true, { closed = acct.id }
  end)
end

--- Backfill missing owner access rows (boot repair).
---
--- A character account whose access row failed to write is invisible to its
--- owner while still holding money — `listForChar` inner-joins on that table.
--- That can happen if the access table was missing or the insert errored, so
--- rather than trusting it never happens, every boot re-asserts the invariant.
--- Idempotent and cheap: it only touches rows that are actually missing.
function Accounts.repairOwnerAccess()
  local repaired = Db.execute([[
    INSERT IGNORE INTO sov_bank_access (account_id, charidentifier, access_level, granted_by)
    SELECT a.id, a.owner_id, 'owner', 'boot-repair'
    FROM sov_bank_accounts a
    LEFT JOIN sov_bank_access x
      ON x.account_id = a.id AND x.charidentifier = a.owner_id
    WHERE a.owner_type = 'character' AND a.status <> 'closed' AND x.id IS NULL
  ]])
  if repaired and repaired > 0 then
    Log.warn('repaired %d account(s) that were missing their owner access row', repaired)
  end
  return repaired or 0
end

--- Idempotent first-boot seeding (tech spec §15.4). Government/system
--- accounts live in the reserved number range 1–1000 (Config.ReservedNumbers):
--- their row id and account number are both pinned there, so №1 is the
--- Government Fund and №2 the Insurance Fund for the life of the server.
function Accounts.ensureSystemAccounts()
  local reserved = Config.ReservedNumbers or {}
  local prefix = Config.AccountPrefix or 'SVB-'
  local seeds = {
    { key = Constants.SystemAccounts.GOV,       name = 'Government Fund' },
    { key = Constants.SystemAccounts.INSURANCE, name = 'Insurance Fund' },
  }
  for _, seed in ipairs(seeds) do
    local num = reserved[seed.key]
    local acct = Accounts.getSystem(seed.key)

    if not acct and num then
      -- Fresh install: pin id AND number to the reserved slot.
      local number = ('%s%07d'):format(prefix, num)
      Db.execute([[
        INSERT IGNORE INTO sov_bank_accounts (id, account_number, owner_type, owner_id, name, kind)
        VALUES (?, ?, 'system', ?, ?, 'checking')
      ]], { num, number, seed.key, seed.name })
      acct = Accounts.getSystem(seed.key)
      if acct then Log.info('seeded system account %s as %s', seed.key, number) end
    elseif not acct then
      -- No reserved slot configured — fall back to an organic row.
      acct = Accounts.create(Constants.OwnerType.SYSTEM, seed.key, seed.name,
        Constants.AccountKind.CHECKING)
    elseif num then
      -- Migration: installs seeded before the range was reserved carry a
      -- role-branded number (SVB-SYS-GOV). Rebrand to the numeric slot.
      local wanted = ('%s%07d'):format(prefix, num)
      if acct.account_number ~= wanted then
        local clash = Accounts.getByNumber(wanted)
        if clash and clash.id ~= acct.id then
          Log.error('cannot brand %s as %s: number already held by account id %s',
            seed.key, wanted, tostring(clash.id))
        else
          Db.execute('UPDATE sov_bank_accounts SET account_number = ? WHERE id = ?',
            { wanted, acct.id })
          Log.info('rebranded system account %s as %s', seed.key, wanted)
        end
      end
    end

    if not acct then Log.error('failed to seed system account %s', seed.key) end
  end
end
