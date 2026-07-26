--[[
  server/api/compat.lua — migration shim (design §6.5).

  Drop-in exports mirroring the money signatures third-party RedM scripts
  already expect, so existing resources route through Sovereign Bank (and land
  in the ledger) without being rewritten:

      exports['sov_bank']:addMoney(src, 0, 12.50)

  Two deliberate differences from the native exports in exports.lua:
  - These take a PLAYER SOURCE (what VORP-style scripts pass around), not a
    charidentifier. A charid is accepted as a fallback for offline paths.
  - Amounts are DISPLAY units (dollars, 12.50) because that is what legacy
    callers pass; the bank converts to minor units at this boundary and
    nowhere else.

  Off unless Config.Compat.enabled — a shim that silently intercepts money
  calls should be an explicit choice, not a default.
]]

if not (Config.Compat and Config.Compat.enabled) then return end

--- Legacy callers pass a PLAYER SOURCE. Deliberately no charid fallback:
--- VORP charidentifiers and FiveM server ids are both small positive integers,
--- so "if no player is at this source, assume it's a charid" silently pays a
--- completely unrelated character whenever the two namespaces overlap. A
--- caller with a charid should use the native exports instead.
local function resolveCharid(idOrSrc)
  local n = tonumber(idOrSrc)
  if not n or n <= 0 then return nil end
  return Bridge.GetCharId(n)
end

local function legacyOpts(reason)
  return {
    reason = reason,
    source = 'compat',
    target = Config.Compat.target or 'wallet',
    silent = true,
  }
end

local function warnUnresolved(fn, idOrSrc)
  Log.warn('compat.%s: no loaded character at source %s — ignoring', fn, tostring(idOrSrc))
end

--- Balance in DISPLAY units, or 0 when unavailable. Reads whichever pool
--- Config.Compat.target names, so a legacy "can they afford it?" check and the
--- debit that follows it look at the same money.
local function getMoney(idOrSrc, currency)
  local charid = resolveCharid(idOrSrc)
  if not charid then warnUnresolved('getMoney', idOrSrc) return 0 end
  currency = tonumber(currency) or 0
  local opts = legacyOpts(nil)
  local minor
  if opts.target == 'wallet' then
    minor = API.GetWalletBalance(charid, currency)
  else
    local acct = Accounts.getPrimary(charid)
    minor = acct and API.GetBankBalance(acct.id, currency) or 0
  end
  return Util.toDisplay(minor or 0)
end

local function addMoney(idOrSrc, currency, amount)
  local charid = resolveCharid(idOrSrc)
  if not charid then warnUnresolved('addMoney', idOrSrc) return false end
  local ok = API.AddMoney(charid, tonumber(currency) or 0,
    Util.toMinor(tonumber(amount) or 0), legacyOpts('compat_add'))
  return ok == true
end

local function removeMoney(idOrSrc, currency, amount)
  local charid = resolveCharid(idOrSrc)
  if not charid then warnUnresolved('removeMoney', idOrSrc) return false end
  local ok = API.RemoveMoney(charid, tonumber(currency) or 0,
    Util.toMinor(tonumber(amount) or 0), legacyOpts('compat_remove'))
  return ok == true
end

local function canAfford(idOrSrc, currency, amount)
  local charid = resolveCharid(idOrSrc)
  if not charid then return false end
  return API.CanAfford(charid, tonumber(currency) or 0,
    Util.toMinor(tonumber(amount) or 0), legacyOpts(nil)) == true
end

exports('getMoney', getMoney)
exports('addMoney', addMoney)
exports('removeMoney', removeMoney)
exports('canAfford', canAfford)

-- Currency-specific aliases some resources use.
exports('getGold', function(idOrSrc) return getMoney(idOrSrc, 1) end)
exports('addGold', function(idOrSrc, amount) return addMoney(idOrSrc, 1, amount) end)
exports('removeGold', function(idOrSrc, amount) return removeMoney(idOrSrc, 1, amount) end)

-- Event forms for fire-and-forget callers (server-side TriggerEvent only).
AddEventHandler('sov_bank:compat:addMoney', addMoney)
AddEventHandler('sov_bank:compat:removeMoney', removeMoney)

Log.info('migration shim enabled — legacy money exports route through the bank')
