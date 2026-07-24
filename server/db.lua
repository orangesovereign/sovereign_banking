--[[
  server/db.lua — thin oxmysql wrappers.
  Every wrapper is pcall-guarded: a SQL error logs and returns nil/false rather
  than throwing, matching the resource-wide "never throw to callers" rule
  (tech spec §5.2).
]]

Db = {}

local function safe(fn, query, params)
  local ok, res = pcall(fn, query, params)
  if not ok then
    Log.error('db error: %s | query: %s', tostring(res), tostring(query))
    return nil
  end
  return res
end

--- First row or nil.
function Db.single(query, params)
  return safe(MySQL.single.await, query, params)
end

--- All rows (possibly empty array) or nil on error.
function Db.query(query, params)
  return safe(MySQL.query.await, query, params)
end

--- First column of first row, or nil.
function Db.scalar(query, params)
  return safe(MySQL.scalar.await, query, params)
end

--- INSERT; returns insert id or nil.
function Db.insert(query, params)
  return safe(MySQL.insert.await, query, params)
end

--- UPDATE/DELETE; returns affected row count or nil.
function Db.execute(query, params)
  return safe(MySQL.update.await, query, params)
end

--- Atomic multi-statement transaction. stmts = { {query=..., values={...}}, ... }.
--- Returns true only if every statement succeeded and the txn committed.
function Db.transaction(stmts)
  local ok, res = pcall(MySQL.transaction.await, stmts)
  if not ok then
    Log.error('db transaction error: %s', tostring(res))
    return false
  end
  return res == true
end
