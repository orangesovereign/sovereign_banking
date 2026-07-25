--[[
  server/modules/branches.lua — branch registry + server-side proximity gate
  (design §5.10, tech spec §7.3). The server NEVER trusts the client's claim
  of being at a teller: every account operation re-checks the player's actual
  server-side position.
]]

Branches = {}

function Branches.list()
  return Config.Locations.banks or {}
end

function Branches.getById(id)
  for _, branch in ipairs(Branches.list()) do
    if branch.id == id then return branch end
  end
  return nil
end

--- The branch whose teller this player is actually standing at, or nil.
--- Uses server-side entity coords; allows a small slack on top of the
--- client-side range to absorb sync drift.
function Branches.forSource(src)
  local ped = GetPlayerPed(src)
  if not ped or ped == 0 then return nil end
  local coords = GetEntityCoords(ped)
  for _, branch in ipairs(Branches.list()) do
    local range = (branch.tellerRange or Config.Teller.openRange or 2.5)
      + (Config.Teller.serverSlack or 2.5)
    if #(coords - branch.teller) <= range then
      return branch
    end
  end
  return nil
end
