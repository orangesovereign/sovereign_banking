--[[
  bridge/vorp.lua — the ONLY file that talks to VORP directly (design §9).
  Everything else calls Bridge.*; porting to RSG/standalone later means
  rewriting this one file.

  Wallet notes:
  - VORP stores wallet currency as display floats (dollars). The bank operates
    exclusively in integer minor units ("cents"); conversion happens here and
    nowhere else.
  - Wallet mutations are read-back-verified (tech spec §16.1): VORP's
    add/removeCurrency don't return a reliable success signal, so we compare
    balances before/after and report success only when the delta applied.
  - Offline characters have no live wallet: wallet functions return nil/false
    and the engine maps that to ERR_OFFLINE. Bank-only operations don't need
    the wallet (tech spec §6).
]]

if not IsDuplicityVersion() then return end -- server bridge only (Phase 0)

Bridge = {}

local Core
do
  local ok, core = pcall(function() return exports.vorp_core:GetCore() end)
  if ok and core then
    Core = core
  else
    Log.error('FATAL: could not acquire VORP core — is vorp_core started before sov_bank?')
  end
end

local CURRENCY_FIELD = { [0] = 'money', [1] = 'gold', [2] = 'rol' }

local function getCharacter(src)
  if not Core or not src then return nil end
  local user = Core.getUser(tonumber(src))
  if not user then return nil end
  return user.getUsedCharacter
end

Bridge.GetCharacter = getCharacter

--- Stable character key for a connected player, as a string (DB owner key).
function Bridge.GetCharId(src)
  local char = getCharacter(src)
  if not char or char.charIdentifier == nil then return nil end
  return tostring(char.charIdentifier)
end

--- Resolve a charid back to a live source, or nil if offline.
function Bridge.GetSourceFromCharId(charid)
  charid = tostring(charid)
  for _, sid in ipairs(GetPlayers()) do
    local src = tonumber(sid)
    local char = getCharacter(src)
    if char and tostring(char.charIdentifier) == charid then
      return src
    end
  end
  return nil
end

--- Wallet balance in minor units, or nil if the character isn't available.
function Bridge.WalletGet(src, currency)
  local field = CURRENCY_FIELD[currency]
  local char = getCharacter(src)
  if not char or not field then return nil end
  local v = char[field]
  if type(v) ~= 'number' then return nil end
  return Util.toMinor(v)
end

-- Applies a signed wallet delta (minor units) with read-back verification.
local function walletApply(src, currency, minorDelta)
  local before = Bridge.WalletGet(src, currency)
  if before == nil then return false end
  local char = getCharacter(src)
  if not char then return false end

  local displayAmt = Util.toDisplay(math.abs(minorDelta))
  local ok = pcall(function()
    if minorDelta >= 0 then
      char.addCurrency(currency, displayAmt)
    else
      char.removeCurrency(currency, displayAmt)
    end
  end)
  if not ok then return false end

  local after = Bridge.WalletGet(src, currency)
  return after == before + minorDelta
end

function Bridge.WalletAdd(src, currency, minor)
  return walletApply(src, currency, minor)
end

function Bridge.WalletRemove(src, currency, minor)
  return walletApply(src, currency, -minor)
end

function Bridge.Notify(src, msg, duration)
  if not Core or not src then return end
  pcall(function()
    Core.NotifyRightTip(tonumber(src), msg, duration or 4000)
  end)
end

--- fn(src) fires once a player has picked a character (wallet is live).
function Bridge.OnCharacterSelected(fn)
  AddEventHandler('vorp:SelectedCharacter', function(source, ...)
    fn(tonumber(source))
  end)
end

--- Phase 1+: job/whitelist checks for Tax Collector, society bosses, admins.
function Bridge.GetJob(src)
  local char = getCharacter(src)
  if not char then return nil end
  return char.job, char.jobGrade
end
