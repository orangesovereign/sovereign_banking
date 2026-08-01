--[[
  config/locations.lua — bank branches, tellers, blips (design §5.10).
  No ATMs. Branches only. Consumed by the client (blips, teller peds, prompts)
  and by the server-side proximity gate on every account operation.

  Two coordinates per branch, and they are NOT the same place:

    teller  — the CUSTOMER's side of the counter. The hold-prompt fires within
              tellerRange of it and the server re-checks this distance on every
              account operation, so treat it as a security boundary.
    ped     — vector4: where the CLERK stands, behind the counter, and which
              way he faces (w = heading). Optional; falls back to teller +
              tellerHeading. Survey it in game with a coord tool while standing
              on the clerk's mark, facing the customer.

  Surveyed in game: Valentine, Tumbleweed. Rhodes, Saint Denis and Blackwater
  are still close approximations — walk them and replace the vector4s the same
  way.
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
      teller = vector3(-308.75, 775.3, 118.66), -- customer side of the counter
      tellerHeading = 185.0,
      tellerRange   = 2.5,
      ped      = vector4(-308.06, 774.02, 118.65, 18.99), -- surveyed in game
      pedModel = 's_m_m_bankclerk_01',
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
      pedModel = 's_m_m_bankclerk_01',
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
      pedModel = 's_m_m_bankclerk_01',
      features = { transfers = true, sdb = true, gold = true, loans = true },
      reserve = { cap = 400000 }, -- city bank holds more (design §5.11)
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
      pedModel = 's_m_m_bankclerk_01',
      features = { transfers = true, sdb = true, gold = true, loans = true },
      reserve = { cap = 300000 },
    },
    {
      id     = 'tumbleweed',
      name   = 'Bank of Tumbleweed',
      subtitle = 'New Austin Branch',
      hours  = { 'Monday - Saturday', '8:00 am - 5:00 pm', 'Sunday', 'Closed' },
      blip   = vector3(-5533.06, -2950.96, -0.74),
      -- DERIVED, not surveyed: projected 1.4m out from the clerk's mark along
      -- his heading, the same geometry Valentine has. The same projection
      -- reproduces Valentine's surveyed counter to within 0.24m, so it is
      -- sound, but walk it and replace this with a real reading when you can.
      teller = vector3(-5533.06, -2950.96, -0.74),
      tellerHeading = 22.17,
      tellerRange   = 2.5,
      ped      = vector4(-5533.59, -2949.66, -0.74, 202.17), -- surveyed in game
      pedModel = 's_m_m_bankclerk_01',
      features = { transfers = true, sdb = true, gold = true, loans = true },
      -- A frontier branch keeps less cash on hand than the towns back east.
      reserve = { cap = 200000 },
    },
  },
}
