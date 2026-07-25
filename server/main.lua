--[[
  server/main.lua — bootstrap & resource lifecycle (tech spec §15).
  1. Wait for the database.
  2. Ensure schema (sql/install.sql is fully idempotent).
  3. Seed system accounts (SYS-INSURANCE, SYS-GOV).
  4. Auto-create primary checking accounts on character selection.
]]

local RESOURCE = GetCurrentResourceName()

local function waitForDb()
  while true do
    local ok = pcall(MySQL.scalar.await, 'SELECT 1')
    if ok then return end
    Log.warn('waiting for database...')
    Wait(1000)
  end
end

--- Execute sql/install.sql statement-by-statement. Every statement is
--- CREATE TABLE IF NOT EXISTS, so re-running on every boot is safe.
local function ensureSchema()
  if Config.AutoRunSchema == false then return end
  local raw = LoadResourceFile(RESOURCE, 'sql/install.sql')
  if not raw then
    Log.warn('sql/install.sql not found — assuming schema was imported manually')
    return
  end
  local count = 0
  for stmt in raw:gmatch('[^;]+') do
    local cleaned = stmt:gsub('%-%-[^\n]*', ''):gsub('^%s+', ''):gsub('%s+$', '')
    if #cleaned > 0 then
      Db.query(cleaned)
      count = count + 1
    end
  end
  Log.info('database schema ensured (%d statements)', count)
end

CreateThread(function()
  waitForDb()
  ensureSchema()

  -- Numbers 1–1000 are reserved for government accounts (Config.ReservedNumbers):
  -- push the id counter past the range so organic accounts brand from №1001.
  -- Safe to run every boot — MySQL never lowers the counter below the current max.
  local floor = ((Config.ReservedNumbers and Config.ReservedNumbers.max) or 1000) + 1
  Db.execute(('ALTER TABLE sov_bank_accounts AUTO_INCREMENT = %d'):format(floor))

  Accounts.ensureSystemAccounts()

  -- Resource restarted mid-session: make sure everyone already in has a
  -- primary account.
  for _, sid in ipairs(GetPlayers()) do
    local charid = Bridge.GetCharId(tonumber(sid))
    if charid then Accounts.ensurePrimary(charid) end
  end

  Log.info('Sovereign Bank v%s ready',
    GetResourceMetadata(RESOURCE, 'version', 0) or '?')
end)

-- Personal checking account auto-created on first character load (design §5.1).
Bridge.OnCharacterSelected(function(src)
  CreateThread(function()
    Wait(1000) -- let VORP finish wiring the character
    local charid = Bridge.GetCharId(src)
    if charid then
      Accounts.ensurePrimary(charid)
    end
  end)
end)

-- ============================================================================
-- Console diagnostics (server console only; /bankadmin panel lands Phase 4)
-- ============================================================================

RegisterCommand('sovbank', function(source, args)
  if source ~= 0 then return end -- server console only
  local sub = args[1]

  if sub == 'reconcile' and args[2] then
    local report = Ledger.reconcile(tonumber(args[2]))
    print(report and json.encode(report) or 'account not found')
  elseif sub == 'account' and args[2] then
    local acct = Accounts.getPrimary(args[2])
    print(acct and json.encode(acct) or 'no primary account for charid ' .. tostring(args[2]))
  elseif sub == 'tx' and args[2] then
    local rows = Ledger.getTransactions(tonumber(args[2]), { limit = tonumber(args[3]) or 10 })
    print(json.encode(rows))
  else
    print('usage: sovbank reconcile <accountId> | sovbank account <charid> | sovbank tx <accountId> [limit]')
  end
end, true)
