--[[
  shared/util.lua — money math, uuid, validation helpers.
  All monetary values are integer minor units ("cents"): $12.34 → 1234.
  Floats only exist at the VORP wallet boundary (bridge/vorp.lua converts).
]]

Util = {}

-- os.* is server-only in CitizenFX; uuid generation is only used server-side.
if IsDuplicityVersion() then
  math.randomseed(os.time() + math.floor(os.clock() * 1000))
end

--- RFC-4122-shaped v4 uuid (36 chars — fits sov_bank_transactions.tx_uuid).
function Util.uuid()
  local template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
  return (template:gsub('[xy]', function(c)
    local v = (c == 'x') and math.random(0, 15) or math.random(8, 11)
    return string.format('%x', v)
  end))
end

--- Strict amount validation (tech spec §11): positive integer, bounded.
--- Rejects floats, zero, negatives, NaN, inf. Amounts are minor units.
function Util.isValidAmount(n)
  return type(n) == 'number'
    and n == math.floor(n)
    and n > 0
    and n <= 9e12
end

--- Display ↔ minor-unit conversion. Boundary use only (bridge, NUI).
function Util.toMinor(display)
  return math.floor((tonumber(display) or 0) * 100 + 0.5)
end

function Util.toDisplay(minor)
  return (tonumber(minor) or 0) / 100
end

--- Human string for notifications/statements: 1234 → "$12.34".
function Util.formatAmount(minor, currency)
  local v = Util.toDisplay(minor)
  if currency == Constants.Currency.GOLD then
    return ('%.2f Gold'):format(v)
  elseif currency == Constants.Currency.ROL then
    return ('%.2f Rol'):format(v)
  end
  return ('$%.2f'):format(v)
end

--- Truncate a string to n chars (nil-safe). Used for memo/category columns.
function Util.truncate(s, n)
  if type(s) ~= 'string' then return nil end
  if #s <= n then return s end
  return s:sub(1, n)
end

function Util.now()
  return os.time()
end
