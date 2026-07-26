--[[
  server/engine/ledger.lua — the append-only transaction ledger (design §4).
  Every money movement gets a row; balances are always reconcilable against it.
]]

Ledger = {}

--- Insert one ledger row. Optional fields are simply omitted (SQL NULL) —
--- oxmysql params must be dense arrays, so the column list is built dynamically.
--- e = { tx_uuid, account_id, counterparty_account_id, currency, direction,
---       amount, balance_after, category, source_resource, memo }
--- Returns the row id, or nil on error (e.g. duplicate tx_uuid).
function Ledger.write(e)
  local cols, marks, vals = {}, {}, {}
  local function add(col, v)
    if v ~= nil then
      cols[#cols + 1] = col
      marks[#marks + 1] = '?'
      vals[#vals + 1] = v
    end
  end
  add('tx_uuid', e.tx_uuid)
  add('account_id', e.account_id)
  add('counterparty_account_id', e.counterparty_account_id)
  add('currency', e.currency)
  add('direction', e.direction)
  add('amount', e.amount)
  add('balance_after', e.balance_after)
  add('category', Util.truncate(e.category, 40) or 'adjust') -- column is NOT NULL
  add('source_resource', Util.truncate(e.source_resource, 48))
  add('memo', Util.truncate(e.memo, 140))

  return Db.insert(
    ('INSERT INTO sovereign_banking_transactions (%s) VALUES (%s)')
      :format(table.concat(cols, ', '), table.concat(marks, ', ')),
    vals
  )
end

--- Idempotency lookup (tech spec §5.3).
function Ledger.findByUuid(uuid)
  if not uuid then return nil end
  return Db.single('SELECT * FROM sovereign_banking_transactions WHERE tx_uuid = ?', { uuid })
end

--- Statement query (design §5.9). opts: limit, offset, category, currency,
--- since (epoch), before (epoch). Newest first.
function Ledger.getTransactions(accountId, opts)
  opts = opts or {}
  accountId = tonumber(accountId)
  if not accountId then return {} end

  -- Each condition is appended ONLY when its value converts cleanly. Appending
  -- a `?` whose value is nil leaves a hole in the parameter array, which
  -- oxmysql silently truncates — every later placeholder then binds one slot
  -- to the left.
  local conds, vals = { 'account_id = ?' }, { accountId }
  local function where(clause, value)
    if value ~= nil then
      conds[#conds + 1] = clause
      vals[#vals + 1] = value
    end
  end
  where('category = ?', opts.category and tostring(opts.category) or nil)
  where('currency = ?', opts.currency ~= nil and tonumber(opts.currency) or nil)
  where('created_at >= FROM_UNIXTIME(?)', opts.since and tonumber(opts.since) or nil)
  where('created_at < FROM_UNIXTIME(?)', opts.before and tonumber(opts.before) or nil)

  local limit = math.min(tonumber(opts.limit) or 50, 200)
  local offset = math.max(tonumber(opts.offset) or 0, 0)
  vals[#vals + 1] = limit
  vals[#vals + 1] = offset

  return Db.query(([[
    SELECT id, tx_uuid, account_id, counterparty_account_id, currency, direction,
           amount, balance_after, category, source_resource, memo,
           UNIX_TIMESTAMP(created_at) AS created_at
    FROM sovereign_banking_transactions
    WHERE %s
    ORDER BY id DESC
    LIMIT ? OFFSET ?
  ]]):format(table.concat(conds, ' AND ')), vals) or {}
end

--- Row count for the same filters as getTransactions (statement pagination).
function Ledger.countTransactions(accountId, opts)
  opts = opts or {}
  accountId = tonumber(accountId)
  if not accountId then return 0 end
  -- Must mirror getTransactions exactly, date filters included, or a paginated
  -- statement reports a total for rows it isn't showing.
  local conds, vals = { 'account_id = ?' }, { accountId }
  local function where(clause, value)
    if value ~= nil then
      conds[#conds + 1] = clause
      vals[#vals + 1] = value
    end
  end
  where('category = ?', opts.category and tostring(opts.category) or nil)
  where('currency = ?', opts.currency ~= nil and tonumber(opts.currency) or nil)
  where('created_at >= FROM_UNIXTIME(?)', opts.since and tonumber(opts.since) or nil)
  where('created_at < FROM_UNIXTIME(?)', opts.before and tonumber(opts.before) or nil)

  return tonumber(Db.scalar(
    ('SELECT COUNT(*) FROM sovereign_banking_transactions WHERE %s'):format(table.concat(conds, ' AND ')),
    vals)) or 0
end

--- Reconciliation (tech spec §5.6): signed ledger sum vs stored balance,
--- per currency. Drift logs at error level and is returned for the admin panel.
--- Runs under the account's mutex: the balance and the ledger sum are two
--- round trips, and a movement committing between them would make a perfectly
--- healthy account report drift. False alarms here are worse than none — they
--- train an operator to ignore the one signal that catches real corruption.
function Ledger.reconcile(accountId)
  accountId = tonumber(accountId)
  if not accountId then return nil end

  local ok, report = Money.withLocks({ 'acct:' .. accountId }, function()
    return true, Ledger.reconcileUnlocked(accountId)
  end)
  return ok and report or nil
end

--- The comparison itself. Call this only while holding 'acct:<id>'.
function Ledger.reconcileUnlocked(accountId)
  local acct = Db.single('SELECT * FROM sovereign_banking_accounts WHERE id = ?', { accountId })
  if not acct then return nil end

  local sums = Db.query([[
    SELECT currency,
           COALESCE(SUM(CASE WHEN direction = 'credit' THEN amount ELSE -amount END), 0) AS total
    FROM sovereign_banking_transactions
    WHERE account_id = ?
    GROUP BY currency
  ]], { accountId }) or {}

  local byCurrency = {}
  for _, row in ipairs(sums) do
    byCurrency[tonumber(row.currency)] = tonumber(row.total)
  end

  local report = { accountId = accountId, ok = true, drift = {} }
  for currency, column in pairs(Constants.CurrencyColumn) do
    local ledgerSum = byCurrency[currency] or 0
    local stored = tonumber(acct[column]) or 0
    if ledgerSum ~= stored then
      report.ok = false
      report.drift[#report.drift + 1] = {
        currency = currency, stored = stored, ledger = ledgerSum,
        delta = stored - ledgerSum,
      }
    end
  end

  if not report.ok then
    Log.error('reconciliation drift on account %d: %s', accountId, json.encode(report.drift))
  end
  return report
end
