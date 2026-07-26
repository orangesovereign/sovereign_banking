--[[
  client/main.lua — blips + teller peds (tech spec §10.1).
  Peds spawn/despawn by distance; everything is cleaned up on resource stop.

  Blip and ped natives follow the form proven on this server by
  sovereign_stores: named wrappers rather than raw InvokeNative, a plain
  string for the blip name (a VarString here yields a nameless blip), and
  `false` on SetBlipSprite.

  Blips and peds run in SEPARATE threads. They used to share one, so an error
  creating a blip took the ped loop down with it — two unrelated features
  failing together for one cause.
]]

local blips = {}
local peds = {}       -- branch.id -> ped handle
local pedFailed = {}  -- branch.id -> true once its model is known-bad

local function createBlip(branch)
  local blip = BlipAddForCoords(1664425300, branch.blip.x, branch.blip.y, branch.blip.z)
  if not blip then return nil end

  local sprite = Config.Teller.blipSprite or 'blip_shop_bank'
  SetBlipSprite(blip, joaat(sprite), false)
  if Config.Teller.blipModifier then
    BlipAddModifier(blip, joaat(Config.Teller.blipModifier))
  end
  -- Plain string: SetBlipName does its own string handling, and passing a
  -- CreateVarString here produces a blip with no label.
  SetBlipName(blip, branch.name)
  return blip
end

--- Load a ped model. Returns the hash, or nil if it never loaded — which
--- usually means the model name does not exist in this build.
local function loadModel(name)
  local model = joaat(name)
  RequestModel(model, false)
  for _ = 1, 100 do
    if HasModelLoaded(model) then return model end
    Wait(50)
  end
  return nil
end

local function spawnTellerPed(branch)
  local name = branch.pedModel or Config.Teller.pedModel or 'U_M_M_NbxGeneralStoreOwner_01'
  local model = loadModel(name)
  if not model then
    -- Logged ONCE per branch: the distance loop revisits every couple of
    -- seconds, and a bad model name would otherwise spam the console forever.
    pedFailed[branch.id] = true
    print(('[sovereign_banking] teller ped model "%s" never loaded for %s — no ped will spawn there. Set a valid pedModel in config/locations.lua.')
      :format(name, branch.id))
    return nil
  end

  -- Ground-snap before freezing, so a teller whose configured Z sits slightly
  -- above the floor doesn't hover. Falls back to the configured Z when
  -- collision hasn't streamed in yet.
  local t = branch.teller
  local z = t.z
  for _ = 1, 5 do
    local found, groundZ = GetGroundZAndNormalFor_3dCoord(t.x, t.y, t.z + 2.0)
    if found and groundZ then z = groundZ break end
    Wait(100)
  end

  local ped = CreatePed(model, t.x, t.y, z, branch.tellerHeading or 0.0, false, false, false, false)
  -- SetRandomOutfitVariation — RDR2 peds spawn invisible without it.
  Citizen.InvokeNative(0x283978A15512B2FE, ped, true)
  SetEntityCanBeDamaged(ped, false)
  SetEntityInvincible(ped, true)
  FreezeEntityPosition(ped, true)
  SetBlockingOfNonTemporaryEvents(ped, true)
  SetPedCanBeTargetted(ped, false)
  SetModelAsNoLongerNeeded(model)
  return ped
end

-- Blips: one pass at start. Guarded per branch so one bad entry cannot cost
-- the others their marker.
CreateThread(function()
  for _, branch in ipairs(Config.Locations.banks or {}) do
    local ok, blip = pcall(createBlip, branch)
    if ok and blip then
      blips[#blips + 1] = blip
    else
      print(('[sovereign_banking] could not create the map blip for %s: %s')
        :format(branch.id, tostring(blip)))
    end
  end
end)

-- Teller peds: spawn and despawn by distance.
CreateThread(function()
  if Config.Teller.spawnPeds == false then return end
  local spawnDist = Config.Teller.pedSpawnDistance or 60.0

  while true do
    local coords = GetEntityCoords(PlayerPedId())
    for _, branch in ipairs(Config.Locations.banks or {}) do
      local dist = #(coords - branch.teller)
      if dist <= spawnDist and not peds[branch.id] and not pedFailed[branch.id] then
        local ok, ped = pcall(spawnTellerPed, branch)
        peds[branch.id] = ok and ped or nil
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
