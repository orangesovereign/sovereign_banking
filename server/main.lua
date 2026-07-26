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
---
--- Comments are stripped from the WHOLE file before splitting on ';'. Doing it
--- the other way round means a semicolon inside a `--` comment splits the
--- comment in two and the tail becomes the head of the next statement, which
--- then fails to parse. A failure here is fatal to boot rather than a warning:
--- a missing table is not something to discover later at a teller.
local function ensureSchema()
  if Config.AutoRunSchema == false then return end
  local raw = LoadResourceFile(RESOURCE, 'sql/install.sql')
  if not raw then
    Log.warn('sql/install.sql not found — assuming schema was imported manually')
    return true
  end

  local stripped = raw:gsub('%-%-[^\n]*', '')
  local count, failed = 0, 0
  for stmt in stripped:gmatch('[^;]+') do
    local cleaned = stmt:gsub('^%s+', ''):gsub('%s+$', '')
    if #cleaned > 0 then
      count = count + 1
      if Db.query(cleaned) == nil then
        failed = failed + 1
        Log.error('schema statement %d failed: %s', count, cleaned:sub(1, 120))
      end
    end
  end

  if failed > 0 then
    Log.error('SCHEMA INCOMPLETE — %d of %d statements failed. The bank will not start.',
      failed, count)
    return false
  end
  Log.info('database schema ensured (%d statements)', count)
  return true
end

CreateThread(function()
  waitForDb()
  if not ensureSchema() then
    -- Seeding accounts against a half-built schema would scatter partial state
    -- that is harder to clean up than a refused boot.
    Log.error('Sovereign Bank did NOT start. Fix the schema errors above and restart the resource.')
    return
  end

  -- Numbers 1–1000 are reserved for government accounts (Config.ReservedNumbers):
  -- push the id counter past the range so organic accounts brand from №1001.
  -- Safe to run every boot — MySQL never lowers the counter below the current max.
  local floor = ((Config.ReservedNumbers and Config.ReservedNumbers.max) or 1000) + 1
  Db.execute(('ALTER TABLE sov_bank_accounts AUTO_INCREMENT = %d'):format(floor))

  Accounts.ensureSystemAccounts()
  Accounts.repairOwnerAccess()
  Society.ensureAccounts()
  Heist.ensureReserves()
  SDB.registerAll()

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
  elseif sub == 'loans' then
    -- Loan desk (until the Phase 4 admin panel): list / approve / deny.
    local action = args[2]
    if action == 'approve' and args[3] then
      local ok, res = Loans.approve(tonumber(args[3]), 'console')
      print(ok and json.encode(res) or ('error: ' .. tostring(res)))
    elseif action == 'deny' and args[3] then
      local ok, res = Loans.deny(tonumber(args[3]), 'console')
      print(ok and json.encode(res) or ('error: ' .. tostring(res)))
    else
      local rows = Loans.listPending()
      print(#rows == 0 and 'no pending loan applications' or json.encode(rows))
    end
  else
    print('usage: sovbank reconcile <accountId> | sovbank account <charid> | sovbank tx <accountId> [limit] | sovbank loans [approve|deny <loanId>]')
  end
end, true)
