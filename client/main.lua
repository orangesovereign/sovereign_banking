--[[
  client/main.lua — blips + teller peds (tech spec §10.1).
  Peds spawn/despawn by distance; everything is cleaned up on resource stop.
]]

local blips = {}
local peds = {} -- branch.id -> ped handle

-- RDR3 natives invoked by hash where named wrappers are inconsistent between
-- builds. Hashes are the community-standard set.
local function varString(text)
  return CreateVarString(10, 'LITERAL_STRING', text)
end

local function createBlip(branch)
  -- BLIP_ADD_FOR_COORDS (0x554D9D53F696D002), style BLIP_STYLE_LOCATION
  local blip = Citizen.InvokeNative(0x554D9D53F696D002, 1664425300,
    branch.blip.x, branch.blip.y, branch.blip.z)
  -- SET_BLIP_SPRITE (0x74F74D3207ED525C)
  Citizen.InvokeNative(0x74F74D3207ED525C, blip,
    GetHashKey(Config.Teller.blipSprite or 'blip_shop_bank'), true)
  -- _SET_BLIP_NAME_FROM_PLAYER_STRING (0x9CB1A1623062F402) — takes a VarString
  Citizen.InvokeNative(0x9CB1A1623062F402, blip, varString(branch.name))
  return blip
end

local function loadModel(hash)
  if not IsModelValid(hash) then return false end
  RequestModel(hash)
  local deadline = GetGameTimer() + 5000
  while not HasModelLoaded(hash) and GetGameTimer() < deadline do
    Wait(50)
  end
  return HasModelLoaded(hash)
end

local function spawnTellerPed(branch)
  local model = branch.pedModel or 'u_m_m_valbanker_01'
  local hash = GetHashKey(model)
  if not loadModel(hash) then
    print(('[sovereign_banking] teller ped model %s failed to load for %s'):format(model, branch.id))
    return nil
  end
  local t = branch.teller
  local ped = CreatePed(hash, t.x, t.y, t.z, branch.tellerHeading or 0.0, false, false, false, false)
  -- _SET_RANDOM_OUTFIT_VARIATION — required or RDR2 peds spawn invisible
  Citizen.InvokeNative(0x283978A15512B2FE, ped, true)
  SetEntityInvincible(ped, true)
  FreezeEntityPosition(ped, true)
  SetBlockingOfNonTemporaryEvents(ped, true)
  SetModelAsNoLongerNeeded(hash)
  return ped
end

CreateThread(function()
  for _, branch in ipairs(Config.Locations.banks or {}) do
    blips[#blips + 1] = createBlip(branch)
  end

  if Config.Teller.spawnPeds == false then return end
  local spawnDist = Config.Teller.pedSpawnDistance or 60.0
  while true do
    local coords = GetEntityCoords(PlayerPedId())
    for _, branch in ipairs(Config.Locations.banks or {}) do
      local dist = #(coords - branch.teller)
      if dist <= spawnDist and not peds[branch.id] then
        peds[branch.id] = spawnTellerPed(branch)
      elseif dist > spawnDist + 20.0 and peds[branch.id] then
        DeleteEntity(peds[branch.id])
        peds[branch.id] = nil
      end
    end
    Wait(2000)
  end
end)

AddEventHandler('onResourceStop', function(res)
  if res ~= GetCurrentResourceName() then return end
  for _, blip in ipairs(blips) do
    RemoveBlip(blip)
  end
  for _, ped in pairs(peds) do
    if ped then DeleteEntity(ped) end
  end
end)
