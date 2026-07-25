--[[
  client/nui.lua — NUI ↔ server marshalling (tech spec §10.1).
  The NUI never talks to the server directly: it posts to this file, which
  forwards over the sov_bank RPC layer and returns the server's reply to the
  fetch promise. The client adds nothing and trusts nothing.
]]

-- ============================================================================
-- RPC client (pairs with server/api/callbacks.lua)
-- ============================================================================

local pending = {}
local nextId = 0

--- Rpc(name, payload, cb) — cb receives the server's { ok, data|error } table.
function Rpc(name, payload, cb)
  nextId = nextId + 1
  local id = nextId
  pending[id] = cb
  TriggerServerEvent('sov_bank:rpc:request', name, id, payload)

  -- Reap abandoned requests so a lost reply can't leak callbacks forever.
  SetTimeout(10000, function()
    if pending[id] then
      local cbf = pending[id]
      pending[id] = nil
      cbf({ ok = false, error = 'ERR_INTERNAL' })
    end
  end)
end

RegisterNetEvent('sov_bank:rpc:response', function(reqId, res)
  local cb = pending[reqId]
  pending[reqId] = nil
  if cb then cb(res) end
end)

-- ============================================================================
-- NUI callbacks
-- ============================================================================

RegisterNUICallback('rpc', function(data, cb)
  if type(data) ~= 'table' or type(data.name) ~= 'string' then
    return cb({ ok = false, error = 'ERR_INTERNAL' })
  end
  Rpc(data.name, data.payload or {}, function(res)
    cb(res or { ok = false, error = 'ERR_INTERNAL' })
  end)
end)

RegisterNUICallback('close', function(_, cb)
  TellerClose()
  AdminClose()
  cb({ ok = true })
end)
