--[[
  config/locations.lua — bank branches, tellers, blips (design §5.10).
  No ATMs. Branches only. Consumed by the Phase 1 client/teller layer and by
  server-side proximity gating on every account operation.
]]

Config = Config or {}

Config.Locations = {
  banks = {
    -- Example branch (uncomment and adjust for your map):
    -- {
    --   id     = 'valentine',
    --   name   = 'Bank of Valentine',
    --   coords = vector3(-308.06, 775.13, 118.66),
    --   teller = vector3(-308.85, 771.68, 118.66),
    --   tellerRange = 2.5,            -- metres for server-side proximity gate
    --   blip   = { sprite = -1230993421, scale = 0.2 },
    --   reserve = { cap = 250000 },   -- overrides Config.Heist.reserveDefault
    --   features = { loans = true, gold = true, sdb = true },
    --   rateOverrides = {},
    -- },
  },
}
