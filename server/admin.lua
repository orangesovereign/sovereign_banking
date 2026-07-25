--[[
  server/admin.lua — admin & operations (design §5.12).

  Surfaces: the /bankadmin NUI panel (permission-gated RPC in
  server/api/callbacks.lua) and the `sovbank` server console commands.

  Every privileged mutation here goes through the money engine so it lands in
  the ledger like any other movement — an admin adjustment is a ledgered
  `admin_adjust` row naming the actor, never a silent UPDATE. That keeps
  reconciliation honest even when a human intervenes.
]]

Admin = {}

local Err = Constants.Err

-- ============================================================================
-- Permission
-- ============================================================================

--- Server console is always allowed (src 0). Players need the ACE or an
--- identifier on the allow-list.
function Admin.isAllowed(src)
  src = tonumber(src) or 0
  if src == 0 then return true end

  local ace = Config.Admin and Config.Admin.aceGroup
  if ace and ace ~= '' then
    local ok, allowed = pcall(IsPlayerAceAllowed, src, ace)
    if ok and allowed then return true end
  end

  local list = (Config.Admin and Config.Admin.identifiers) or {}
  if #list > 0 then
    for i = 0, GetNumPlayerIdentifiers(src) - 1 do
      local ident = GetPlayerIdentifier(src, i)
      for _, allowedIdent in ipairs(list) do
        if ident == allowedIdent then return true end
      end
    end
  end
  return false
end

-- ============================================================================
-- Account operations
-- ============================================================================

--- Search accounts by number, owner id, or name fragment.
function Admin.searchAccounts(term, limit)
  term = tostring(term or ''):gsub('^%s+', ''):gsub('%s+$', '')
  limit = math.min(tonumber(limit) or 25, 50)
  if #term == 0 then
    return Db.query([[
      SELECT * FROM sov_bank_accounts ORDER BY id DESC LIMIT ?
    ]], { limit }) or {}
  end
  local like = '%' .. term .. '%'
  return Db.query([[
    SELECT * FROM sov_bank_accounts
    WHERE account_number LIKE ? OR owner_id LIKE ? OR name LIKE ?
    ORDER BY id ASC LIMIT ?
  ]], { like, like, like, limit }) or {}
end

--- Freeze / unfreeze (design §5.1). status: 'frozen' | 'active'.
function Admin.setStatus(accountId, status, actor)
  accountId = tonumber(accountId)
  if not accountId then return false, Err.NO_ACCOUNT end
  if status ~= 'frozen' and status ~= 'active' then return false, Err.BAD_KIND end

  return Money.withLocks({ 'acct:' .. accountId }, function()
    local acct = Accounts.getById(accountId)
    if not acct then return false, Err.NO_ACCOUNT end
    if acct.status == 'closed' then return false, Err.ACCOUNT_CLOSED end

    Db.execute('UPDATE sov_bank_accounts SET status = ? WHERE id = ?', { status, acct.id })
    Log.warn('admin: %s set account %s to %s', tostring(actor), acct.account_number, status)
    Log.discord('admin', 'Account status changed', nil, {
      { name = 'Account', value = acct.account_number, inline = true },
      { name = 'Status', value = status, inline = true },
      { name = 'By', value = tostring(actor), inline = true },
    })
    if status == 'frozen' then
      Events.accountFrozen({ accountId = acct.id, by = tostring(actor) })
    end
    return true, { accountId = acct.id, status = status }
  end)
end

--- Force adjustment, always ledgered as admin_adjust (design §5.12).
--- delta may be negative; bounded by Config.Admin.adjustMax.
function Admin.adjust(accountId, currency, delta, actor, reason)
  accountId = tonumber(accountId)
  delta = math.floor(tonumber(delta) or 0)
  if not accountId then return false, Err.NO_ACCOUNT end
  if delta == 0 then return false, Err.BAD_AMOUNT end

  local cap = tonumber(Config.Admin and Config.Admin.adjustMax) or 10000000
  if math.abs(delta) > cap then return false, Err.BAD_AMOUNT end

  local memo = Util.truncate(('admin adjust by %s%s'):format(
    tostring(actor), reason and (' — ' .. tostring(reason)) or ''), 140)
  local meta = {
    category = Constants.Category.ADMIN_ADJUST,
    memo = memo,
    source = 'sov_bank_admin',
  }

  local ok, res
  if delta > 0 then
    ok, res = Money.accountCredit(accountId, currency, delta, meta)
  else
    ok, res = Money.accountDebit(accountId, currency, -delta, meta)
  end
  if not ok then return false, res end

  local acct = Accounts.getById(accountId)
  Log.warn('admin: %s adjusted account %s by %s (%s)',
    tostring(actor), acct and acct.account_number or accountId, delta, tostring(reason))
  Log.discord('admin', 'Balance adjusted', reason and tostring(reason) or nil, {
    { name = 'Account', value = acct and acct.account_number or tostring(accountId), inline = true },
    { name = 'Delta', value = Util.formatAmount(delta, currency), inline = true },
    { name = 'By', value = tostring(actor), inline = true },
  })
  return true, res
end

-- ============================================================================
-- Reconciliation (tech spec §5.6) & money supply (design §5.12)
-- ============================================================================

--- Reconcile a slice of accounts; returns { checked, drifted = {reports} }.
function Admin.reconcileAll(limit, offset)
  limit = math.min(tonumber(limit) or 200, 500)
  offset = tonumber(offset) or 0
  local rows = Db.query(
    'SELECT id FROM sov_bank_accounts ORDER BY id ASC LIMIT ? OFFSET ?',
    { limit, offset }) or {}

  local drifted = {}
  for _, r in ipairs(rows) do
    local report = Ledger.reconcile(r.id)
    if report and not report.ok then
      drifted[#drifted + 1] = report
    end
  end
  if #drifted > 0 then
    Log.error('reconciliation: %d of %d accounts show drift', #drifted, #rows)
    Log.discord('admin', 'Reconciliation drift detected',
      ('%d of %d accounts do not match their ledger'):format(#drifted, #rows))
  end
  return { checked = #rows, drifted = drifted }
end

--- Money-supply telemetry: what the bank holds, and the faucet/sink balance
--- by category over a window of real-life days.
function Admin.moneySupply(windowDays)
  windowDays = tonumber(windowDays) or 7
  local since = os.time() - math.floor(windowDays * 86400)

  local totals = Db.single([[
    SELECT
      COALESCE(SUM(balance_money), 0) AS money,
      COALESCE(SUM(balance_gold), 0)  AS gold,
      COUNT(*) AS accounts
    FROM sov_bank_accounts WHERE status <> 'closed'
  ]]) or {}

  local byOwner = Db.query([[
    SELECT owner_type, COUNT(*) AS n, COALESCE(SUM(balance_money), 0) AS money
    FROM sov_bank_accounts WHERE status <> 'closed'
    GROUP BY owner_type ORDER BY money DESC
  ]]) or {}

  -- Faucets (credits) vs sinks (debits) per category in the window.
  local flows = Db.query([[
    SELECT category,
           COALESCE(SUM(CASE WHEN direction = 'credit' THEN amount ELSE 0 END), 0) AS credited,
           COALESCE(SUM(CASE WHEN direction = 'debit'  THEN amount ELSE 0 END), 0) AS debited,
           COUNT(*) AS n
    FROM sov_bank_transactions
    WHERE currency = 0 AND created_at >= FROM_UNIXTIME(?)
    GROUP BY category ORDER BY (credited + debited) DESC LIMIT 25
  ]], { since }) or {}

  local sys = {}
  for _, key in ipairs({ Constants.SystemAccounts.GOV, Constants.SystemAccounts.INSURANCE }) do
    local acct = Accounts.getSystem(key)
    if acct then
      sys[#sys + 1] = {
        key = key, number = acct.account_number,
        money = tonumber(acct.balance_money) or 0,
      }
    end
  end

  local loans = Db.single([[
    SELECT COUNT(*) AS n, COALESCE(SUM(balance_remaining), 0) AS outstanding
    FROM sov_bank_loans WHERE status IN ('active','defaulted')
  ]]) or {}

  local debt = Db.single([[
    SELECT COUNT(*) AS n, COALESCE(SUM(balance_remaining), 0) AS owed
    FROM sov_bank_bills WHERE status IN ('pending','overdue','in_collections','warrant')
  ]]) or {}

  return {
    windowDays = windowDays,
    banked = {
      money = tonumber(totals.money) or 0,
      gold = tonumber(totals.gold) or 0,
      accounts = tonumber(totals.accounts) or 0,
    },
    byOwner = byOwner,
    flows = flows,
    system = sys,
    loans = { count = tonumber(loans.n) or 0, outstanding = tonumber(loans.outstanding) or 0 },
    debt = { count = tonumber(debt.n) or 0, owed = tonumber(debt.owed) or 0 },
    reserves = Heist.report(),
  }
end

-- ============================================================================
-- Console commands (server console only — the NUI panel is the player path)
-- ============================================================================

RegisterCommand('sovbankadmin', function(source, args)
  if source ~= 0 then return end
  local sub = args[1]

  if sub == 'supply' then
    print(json.encode(Admin.moneySupply(tonumber(args[2]) or 7)))
  elseif sub == 'reconcile' then
    print(json.encode(Admin.reconcileAll(tonumber(args[2]) or 200, tonumber(args[3]) or 0)))
  elseif sub == 'search' and args[2] then
    print(json.encode(Admin.searchAccounts(args[2], 25)))
  elseif (sub == 'freeze' or sub == 'unfreeze') and args[2] then
    local ok, res = Admin.setStatus(tonumber(args[2]), sub == 'freeze' and 'frozen' or 'active', 'console')
    print(ok and json.encode(res) or ('error: ' .. tostring(res)))
  elseif sub == 'adjust' and args[2] and args[3] then
    local ok, res = Admin.adjust(tonumber(args[2]), tonumber(args[4]) or 0,
      tonumber(args[3]), 'console', args[5])
    print(ok and json.encode(res) or ('error: ' .. tostring(res)))
  elseif sub == 'reserves' then
    print(json.encode(Heist.report()))
  else
    print('usage: sovbankadmin supply [days] | reconcile [limit] [offset] | search <term>')
    print('       sovbankadmin freeze|unfreeze <accountId>')
    print('       sovbankadmin adjust <accountId> <deltaMinor> [currency] [reason]')
    print('       sovbankadmin reserves')
  end
end, true)
