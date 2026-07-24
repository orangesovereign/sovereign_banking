--[[
  server/api/events.lua — net-event surface (design §6.2).

  Outbound: the bank announces what it did so other systems can react without
  polling. Inbound: thin fire-and-forget shims over the exports.

  SECURITY: inbound money events are registered with AddEventHandler ONLY —
  deliberately NOT RegisterNetEvent/RegisterServerEvent. They are reachable by
  server-side TriggerEvent from other resources, and can never be fired by a
  client (design principle #2: the client never triggers a raw money mutation).
]]

Events = {}

local function emit(name, payload)
  TriggerEvent('sov_bank:server:' .. name, payload)
end

-- ============================================================================
-- Outbound broadcasts (bank → listeners)
-- ============================================================================

function Events.transactionCompleted(payload) emit('transactionCompleted', payload) end
function Events.balanceChanged(payload)       emit('balanceChanged', payload) end
function Events.loanDefaulted(payload)        emit('loanDefaulted', payload) end   -- Phase 3
function Events.accountFrozen(payload)        emit('accountFrozen', payload) end   -- Phase 1
function Events.billPaid(payload)             emit('billPaid', payload) end        -- Phase 2
function Events.debtOverdue(payload)          emit('debtOverdue', payload) end     -- Phase 2
function Events.debtInCollections(payload)    emit('debtInCollections', payload) end -- Phase 2
function Events.warrantFiled(payload)         emit('warrantFiled', payload) end    -- Phase 2
function Events.assetsSeized(payload)         emit('assetsSeized', payload) end    -- Phase 2

-- ============================================================================
-- Inbound shims (other server resources → bank), fire-and-forget.
-- Resources that need the (ok, result) reply should call the exports instead.
-- ============================================================================

AddEventHandler('sov_bank:server:addMoney', function(charid, currency, amount, opts)
  API.AddMoney(charid, currency, amount, opts)
end)

AddEventHandler('sov_bank:server:removeMoney', function(charid, currency, amount, opts)
  API.RemoveMoney(charid, currency, amount, opts)
end)

AddEventHandler('sov_bank:server:transfer', function(fromAccountId, toAccountId, currency, amount, opts)
  API.Transfer(fromAccountId, toAccountId, currency, amount, opts)
end)
