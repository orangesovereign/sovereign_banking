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

  Surveyed in game: everywhere but Saint Denis, which is still the shipped
  guess — walk it and replace the vector4 the same way. Treat it as unproven
  rather than imprecise: of the guesses that have been checked, Blackwater's
  was 53m out and Rhodes' 7m, both far enough that no prompt could ever fire.
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
      ped      = vector4(-308.04, 774.04, 118.65, 12.81), -- surveyed in game
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
      blip   = vector3(1292.11, -1302.12, 76.99),
      teller = vector3(1292.11, -1302.12, 76.99), -- derived, see Tumbleweed
      tellerHeading = 140.04,
      tellerRange   = 2.5,
      ped      = vector4(1291.21, -1303.19, 76.99, 320.04), -- surveyed in game
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
      blip   = vector3(-850.00, -1235.91, 44.41),
      teller = vector3(-850.00, -1235.91, 44.41), -- derived, see Tumbleweed
      tellerHeading = 85.76,
      tellerRange   = 2.5,
      ped      = vector4(-851.4, -1235.81, 44.41, 265.76), -- surveyed in game
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
    {
      id     = 'armadillo',
      name   = 'Bank of Armadillo',
      subtitle = 'New Austin Branch',
      hours  = { 'Monday - Saturday', '8:00 am - 5:00 pm', 'Sunday', 'Closed' },
      blip   = vector3(-3665.95, -2627.28, -13.64),
      teller = vector3(-3665.95, -2627.28, -13.64), -- derived, see Tumbleweed
      tellerHeading = 173.57,
      tellerRange   = 2.5,
      ped      = vector4(-3666.11, -2628.67, -13.64, 353.57), -- surveyed in game
      pedModel = 's_m_m_bankclerk_01',
      features = { transfers = true, sdb = true, gold = true, loans = true },
      reserve = { cap = 200000 },
    },
  },
}
