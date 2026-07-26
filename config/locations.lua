--[[
  config/locations.lua â€” bank branches, tellers, blips (design Â§5.10).
  No ATMs. Branches only. Consumed by the client (blips, teller peds, prompts)
  and by the server-side proximity gate on every account operation.

  NOTE: coordinates below are close approximations of the in-game bank
  counters â€” fine-tune teller/ped positions and headings on your server.
]]

Config = Config or {}

Config.Locations = {
  banks = {
    {
      id     = 'valentine',
      name   = 'Bank of Valentine',
      subtitle = 'Main Branch',
      hours  = { 'Monday - Saturday', '8:00 am - 5:00 pm', 'Sunday', 'Closed' },
      blip   = vector3(-307.9, 770.9, 118.4),   -- map marker position
      teller = vector3(-308.75, 775.3, 118.66), -- interaction point (counter)
      tellerHeading = 185.0,                    -- ped faces the customer
      tellerRange   = 2.5,
      pedModel = 'U_M_M_NbxGeneralStoreOwner_01',
      features = { transfers = true, sdb = true, gold = true, loans = true },
      -- reserve / rateOverrides used by later phases
      reserve = { cap = 250000 },
    },
    {
      id     = 'rhodes',
      name   = 'Bank of Rhodes',
      subtitle = 'County Branch',
      hours  = { 'Monday - Saturday', '8:00 am - 5:00 pm', 'Sunday', 'Closed' },
      blip   = vector3(1291.3, -1300.2, 76.9),
      teller = vector3(1288.9, -1296.5, 77.04),
      tellerHeading = 315.0,
      tellerRange   = 2.5,
      pedModel = 'U_M_M_NbxGeneralStoreOwner_01',
      features = { transfers = true, sdb = true, gold = true, loans = true },
      reserve = { cap = 250000 },
    },
    {
      id     = 'saint_denis',
      name   = 'Bank of Saint Denis',
      subtitle = 'City Branch',
      hours  = { 'Monday - Saturday', '8:00 am - 6:00 pm', 'Sunday', 'Closed' },
      blip   = vector3(2643.8, -1293.8, 52.3),
      teller = vector3(2646.9, -1289.7, 52.25),
      tellerHeading = 280.0,
      tellerRange   = 2.5,
      pedModel = 'U_M_M_NbxGeneralStoreOwner_01',
      features = { transfers = true, sdb = true, gold = true, loans = true },
      reserve = { cap = 400000 }, -- city bank holds more (design Â§5.11)
    },
    {
      id     = 'blackwater',
      name   = 'Bank of Blackwater',
      subtitle = 'Main Branch',
      hours  = { 'Monday - Saturday', '8:00 am - 5:00 pm', 'Sunday', 'Closed' },
      blip   = vector3(-813.5, -1278.8, 43.7),
      teller = vector3(-817.0, -1276.2, 43.68),
      tellerHeading = 280.0,
      tellerRange   = 2.5,
      pedModel = 'U_M_M_NbxGeneralStoreOwner_01',
      features = { transfers = true, sdb = true, gold = true, loans = true },
      reserve = { cap = 300000 },
    },
  },
}
