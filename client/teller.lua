--[[
  client/teller.lua — teller proximity, hold-prompt, NUI open/close
  (tech spec §10.1). The client only ever expresses intent; the server
  re-checks proximity on every RPC (§7.3).
]]

TellerUi = { open = false }

local promptGroup = GetRandomIntInRange(0, 0xffffff)
local openPrompt

local function varString(text)
  return CreateVarString(10, 'LITERAL_STRING', text)
end

local function setupPrompt()
  openPrompt = PromptRegisterBegin()
  PromptSetControlAction(openPrompt, Config.Teller.promptKey)
  PromptSetText(openPrompt, varString('Speak with the Teller'))
  PromptSetEnabled(openPrompt, true)
  PromptSetVisible(openPrompt, true)
  PromptSetHoldMode(openPrompt, true)
  PromptSetGroup(openPrompt, promptGroup)
  PromptRegisterEnd(openPrompt)
end

function TellerClose()
  if not TellerUi.open then return end
  TellerUi.open = false
  SetNuiFocus(false, false)
  SendNUIMessage({ action = 'close' })
end

local function tellerOpen()
  if TellerUi.open then return end
  TellerUi.open = true -- optimistic guard against double-fire while awaiting
  Rpc('getTellerData', {}, function(res)
    if not res or not res.ok then
      TellerUi.open = false
      Bridge.Notify('The teller cannot help you right now.')
      return
    end
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'open', data = res.data })
  end)
end

CreateThread(function()
  setupPrompt()
  local nearby = Config.Teller.nearbyRange or 30.0
  local openRange = Config.Teller.openRange or 2.5

  while true do
    local sleep = 1000
    local coords = GetEntityCoords(PlayerPedId())

    local best, bestDist = nil, nearby
    for _, branch in ipairs(Config.Locations.banks or {}) do
      local dist = #(coords - branch.teller)
      if dist < bestDist then
        best, bestDist = branch, dist
      end
    end

    if best then
      sleep = 0
      local range = best.tellerRange or openRange
      if bestDist <= range and not TellerUi.open then
        PromptSetActiveGroupThisFrame(promptGroup, varString(best.name))
        if PromptHasHoldModeCompleted(openPrompt) then
          tellerOpen()
          Wait(500) -- debounce the completed hold
        end
      elseif TellerUi.open and bestDist > range + 2.0 then
        TellerClose() -- walked away with the ledger open
      end
    elseif TellerUi.open then
      TellerClose()
    end

    Wait(sleep)
  end
end)

AddEventHandler('onResourceStop', function(res)
  if res ~= GetCurrentResourceName() then return end
  if TellerUi.open then
    SetNuiFocus(false, false)
  end
  if openPrompt then
    PromptDelete(openPrompt)
  end
end)
