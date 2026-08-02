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

local blips = {}      -- branch.id -> blip handle
local peds = {}       -- branch.id -> ped handle
local pedFailed = {}  -- branch.id -> true once its model is known-bad

local function createBlip(branch)
  local blip = BlipAddForCoords(1664425300, branch.blip.x, branch.blip.y, branch.blip.z)
  if not blip then return nil end

  -- An unknown sprite name is the quietest failure here: it hashes, it is
  -- accepted, the blip exists — and draws nothing. Config carries the verified
  -- names; banking_blips prints what was actually used.
  local sprite = Config.Teller.blipSprite or 'blip_proc_bank'
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

--- Dress a ped: set the outfit variation, THEN push the update.
--- Applying a variation is a TWO-native operation. Without the second call the
--- ped exists, collides and can be interacted with, but renders as nothing at
--- all — an invisible clerk at a working counter. sovereign_medical hit this
--- with its Valentine doctor; same fix, same reason.
local function dressPed(ped)
  pcall(function() Citizen.InvokeNative(0x283978A15512B2FE, ped, true) end)   -- _SET_RANDOM_OUTFIT_VARIATION
  pcall(function() Citizen.InvokeNative(0xCC8CA3E88256E58F, ped, false, true, true, true, false) end) -- _UPDATE_PED_VARIATION
end

--- Where the CLERK stands, which is not where the CUSTOMER stands.
--- `branch.teller` is the customer side of the counter — the prompt fires from
--- it and the server measures proximity against it, so it must not move to suit
--- a ped. `branch.ped` is an optional surveyed vector4 (x, y, z, heading) for
--- the clerk's own mark behind the counter.
local function pedSpot(branch)
  local p = branch.ped
  if p then
    return vector3(p.x, p.y, p.z), p.w + 0.0
  end
  return branch.teller, branch.tellerHeading or 0.0
end

local function spawnTellerPed(branch)
  local name = branch.pedModel or Config.Teller.pedModel or 's_m_m_bankclerk_01'
  local model = loadModel(name)
  if not model then
    -- Logged ONCE per branch: the distance loop revisits every couple of
    -- seconds, and a bad model name would otherwise spam the console forever.
    pedFailed[branch.id] = true
    print(('[sovereign_banking] teller ped model "%s" never loaded for %s — no ped will spawn there. Set a valid pedModel in config/locations.lua.')
      :format(name, branch.id))
    return nil
  end

  local t, heading = pedSpot(branch)
  local ped = CreatePed(model, t.x, t.y, t.z, heading, false, true, true, true)

  -- CreatePed can return before the entity is real; everything below would
  -- silently no-op on a handle that does not exist yet.
  local tries = 0
  while not DoesEntityExist(ped) and tries < 40 do Wait(50) tries = tries + 1 end
  if not DoesEntityExist(ped) then
    print(('[sovereign_banking] teller ped never existed at %s'):format(branch.id))
    return nil
  end

  -- Teller coords are surveyed at foot level on an INTERIOR floor. Ground
  -- snapping traces to world terrain, which under a raised building is metres
  -- below — so it is off by default, and the coords are reasserted either way.
  local snap = branch.groundSnap
  if snap == nil then snap = Config.Teller.groundSnap end
  if snap == true then PlaceEntityOnGroundProperly(ped, true) end
  SetEntityCoordsNoOffset(ped, t.x, t.y, t.z, false, false, false)
  SetEntityHeading(ped, heading)

  dressPed(ped)
  SetEntityVisible(ped, true, false) -- three-arg form, as the post office clerk uses
  SetEntityCanBeDamaged(ped, false)
  SetEntityInvincible(ped, true)
  SetBlockingOfNonTemporaryEvents(ped, true)
  FreezeEntityPosition(ped, true)
  SetPedCanBeTargetted(ped, false)

  -- A standing scenario settles the clerk into an idle instead of a T-pose.
  local scenario = branch.pedScenario or Config.Teller.pedScenario
  if scenario then
    pcall(function()
      TaskStartScenarioInPlace(ped, GetHashKey(scenario), -1, true, false, false, false)
    end)
  end

  SetModelAsNoLongerNeeded(model)
  return ped
end

-- Blips: one pass, but NOT at resource start. A blip created before the player
-- is in the world returns a perfectly good handle that never draws, so this
-- waits for the session first. sovereign_medical sits on a flat Wait(2000) here
-- for the same reason; waiting on the session itself survives a slow load.
-- Guarded per branch so one bad entry cannot cost the others their marker.
CreateThread(function()
  while not NetworkIsSessionStarted() do Wait(500) end
  Wait(1000)

  local placed, total = 0, 0
  for _, branch in ipairs(Config.Locations.banks or {}) do
    total = total + 1
    local ok, blip = pcall(createBlip, branch)
    if ok and blip then
      blips[branch.id] = blip
      placed = placed + 1
    else
      print(('[sovereign_banking] could not create the map blip for %s: %s')
        :format(branch.id, tostring(blip)))
    end
  end
  print(('[sovereign_banking] %d of %d map blips placed (sprite %s)'):format(
    placed, total, tostring(Config.Teller.blipSprite)))
end)

-- Diagnostic (F8): how many blips were placed, and the sprite they were given.
-- A full count with no markers on the map means the sprite name is wrong — the
-- one failure mode that produces no error anywhere.
RegisterCommand('banking_blips', function()
  local sprite = Config.Teller.blipSprite or 'blip_proc_bank'
  print(('[sovereign_banking] sprite "%s" (hash %d)'):format(sprite, joaat(sprite)))
  print('  Every branch "placed" but no markers on the map means the name is not')
  print('  a real blip texture. Verified: blip_proc_bank, blip_robbery_bank,')
  print('  blip_bank_debt. Catalog: rdr3_discoveries .../textures/blips/README.md')
  for _, branch in ipairs(Config.Locations.banks or {}) do
    print(('  %-12s %-7s  %.1f, %.1f, %.1f'):format(
      branch.id, blips[branch.id] and 'placed' or 'MISSING',
      branch.blip.x, branch.blip.y, branch.blip.z))
  end
end, false)

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

-- Diagnostic (F8): where each branch is, whether its clerk exists, and how far
-- the spawned ped ended up from the configured spot. A large Z delta means the
-- ground snap grabbed terrain instead of the floor.
RegisterCommand('banking_peds', function()
  local me = GetEntityCoords(PlayerPedId())
  print('[sovereign_banking] teller peds:')
  for _, branch in ipairs(Config.Locations.banks or {}) do
    local mark, heading = pedSpot(branch)
    local ped = peds[branch.id]
    local line = ('  %-12s counter %5.1fm  mark %5.1fm  ped=%s'):format(
      branch.id, #(me - branch.teller), #(me - mark),
      ped and 'yes' or (pedFailed[branch.id] and 'MODEL FAILED' or 'no'))
    if ped and DoesEntityExist(ped) then
      local p = GetEntityCoords(ped)
      line = line .. ('  at %.2f,%.2f,%.2f h%.1f  (off mark %.2fm, dz %+.2f)')
        :format(p.x, p.y, p.z, GetEntityHeading(ped), #(p - mark), p.z - mark.z)
    end
    print(line)
    print(('    configured mark %.2f,%.2f,%.2f h%.2f'):format(mark.x, mark.y, mark.z, heading))
  end
end, false)

AddEventHandler('onResourceStop', function(res)
  if res ~= GetCurrentResourceName() then return end
  for _, blip in pairs(blips) do -- keyed by branch id, so pairs not ipairs
    RemoveBlip(blip)
  end
  for _, ped in pairs(peds) do
    if ped then DeleteEntity(ped) end
  end
end)
