--[[
  client/admin.lua — /bankadmin panel entry (design §5.12).

  The client asks; the server decides. Permission is verified server-side on
  the adminData call and on every subsequent admin RPC — this command is just
  a door, and an unauthorized knock gets nothing but a notification.
]]

local adminOpen = false

local function openAdmin()
  if TellerUi.open or adminOpen then return end
  adminOpen = true
  Rpc('adminData', {}, function(res)
    if not res or not res.ok then
      adminOpen = false
      Bridge.Notify(res and res.error == 'ERR_ACCESS'
        and 'You have no business behind that counter.'
        or 'The ledger office cannot be reached.')
      return
    end
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'openAdmin', data = res.data })
  end)
end

function AdminClose()
  if not adminOpen then return end
  adminOpen = false
  SetNuiFocus(false, false)
  SendNUIMessage({ action = 'close' })
end

RegisterCommand('bankadmin', openAdmin, false)

AddEventHandler('onResourceStop', function(res)
  if res ~= GetCurrentResourceName() then return end
  if adminOpen then SetNuiFocus(false, false) end
end)
