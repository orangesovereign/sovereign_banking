--[[
  bridge/vorp.lua — the ONLY file that talks to VORP directly (design §9).
  Everything else calls Bridge.*; porting to RSG/standalone later means
  rewriting this one file. Loaded on both sides; each side defines only what
  it needs.

  Wallet notes (server):
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

Bridge = {}

local Core
do
  local ok, core = pcall(function() return exports.vorp_core:GetCore() end)
  if ok and core then
    Core = core
  elseif IsDuplicityVersion() then
    Log.error('FATAL: could not acquire VORP core — is vorp_core started before sovereign_banking?')
  else
    print('^1[sovereign_banking] could not acquire VORP core on client^7')
  end
end

-- ============================================================================
-- CLIENT side
-- ============================================================================
if not IsDuplicityVersion() then
  --- Client notification (teller feedback, errors).
  function Bridge.Notify(msg, duration)
    if Core and Core.NotifyRightTip then
      local ok = pcall(function() Core.NotifyRightTip(msg, duration or 4000) end)
      if ok then return end
    end
    TriggerEvent('vorp:TipRight', msg, duration or 4000)
  end
  return
end

-- ============================================================================
-- SERVER side
-- ============================================================================

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

--- Does this charid exist at all (online or not)? Reads VORP's characters
--- table — a VORP coupling, which is why it lives in the bridge.
function Bridge.CharacterExists(charid)
  local row = Db.scalar(
    'SELECT charidentifier FROM characters WHERE charidentifier = ? LIMIT 1',
    { tostring(charid) })
  return row ~= nil
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

--- Phase 2+: job/whitelist checks for Tax Collector, society bosses, admins.
function Bridge.GetJob(src)
  local char = getCharacter(src)
  if not char then return nil end
  return char.job, tonumber(char.jobGrade or char.jobgrade) or 0
end

--- Display name for a character (statement/roster rendering), or the charid
--- itself when unknown. VORP characters-table coupling lives here.
function Bridge.GetCharName(charid)
  local row = Db.single(
    'SELECT firstname, lastname FROM characters WHERE charidentifier = ? LIMIT 1',
    { tostring(charid) })
  if not row then return tostring(charid) end
  -- Parenthesised so gsub's second return (the replacement count) is dropped.
  local name = (('%s %s'):format(row.firstname or '', row.lastname or '')
    :gsub('^%s+', ''):gsub('%s+$', ''))
  return name
end

-- ============================================================================
-- vorp_inventory stashes (design §5.5 safety deposit boxes). API shape varies
-- between vorp_inventory versions, so try the modern table form first and
-- fall back to the older positional form.
-- ============================================================================

function Bridge.RegisterStash(stashId, name, slots)
  local ok = pcall(function()
    exports.vorp_inventory:registerInventory({
      id = stashId,
      name = name,
      limit = slots,
      acceptWeapons = true,
      shared = false,
      ignoreItemStackLimit = false,
      whitelistItems = false,
      UsePermissions = false,
      UseBlackList = false,
      whitelistWeapons = false,
    })
  end)
  if ok then return true end
  ok = pcall(function()
    exports.vorp_inventory:registerInventory(stashId, name, slots)
  end)
  if not ok then
    Log.error('could not register stash %s — check vorp_inventory version', stashId)
  end
  return ok
end

--- How many of an item a character carries (0 when unknown). Used only to
--- clamp a lawful seizure to what the debtor actually has (design §5.14).
function Bridge.GetItemCount(src, itemName)
  local count = 0
  local ok = pcall(function()
    local item = exports.vorp_inventory:getItem(tonumber(src), itemName)
    if type(item) == 'table' then
      count = tonumber(item.count) or tonumber(item.amount) or 0
    elseif type(item) == 'number' then
      count = item
    end
  end)
  if not ok then
    ok = pcall(function()
      count = tonumber(exports.vorp_inventory:getItemCount(tonumber(src), itemName)) or 0
    end)
  end
  return ok and count or 0
end

--- Remove items from a character. Read-back verified, for the same reason the
--- wallet is: vorp_inventory's subItem gives no reliable success signal, and a
--- seizure must never pay a collector for goods the debtor still holds.
--- Returns true only when the count actually fell by the requested amount.
function Bridge.RemoveItem(src, itemName, count)
  count = tonumber(count) or 1
  local before = Bridge.GetItemCount(src, itemName)
  if before < count then return false end

  local ok, err = pcall(function()
    exports.vorp_inventory:subItem(tonumber(src), itemName, count)
  end)
  if not ok then
    Log.error('could not remove %s x%s from %s: %s',
      itemName, tostring(count), tostring(src), tostring(err))
    return false
  end

  local after = Bridge.GetItemCount(src, itemName)
  if after ~= before - count then
    Log.error('item removal did not apply: %s x%s from %s (%s -> %s)',
      itemName, tostring(count), tostring(src), tostring(before), tostring(after))
    return false
  end
  return true
end

function Bridge.OpenStash(src, stashId)
  local ok = pcall(function()
    exports.vorp_inventory:openInventory(tonumber(src), stashId)
  end)
  if not ok then
    Log.error('could not open stash %s for %s', stashId, tostring(src))
  end
  return ok
end

--- Roster for a society (design §5.8 payroll): every character holding one of
--- the given VORP job names. Offline characters included — payroll pays into
--- bank accounts, not wallets.
function Bridge.GetCharactersByJob(jobs)
  if type(jobs) ~= 'table' or #jobs == 0 then return {} end
  local marks = {}
  for i = 1, #jobs do marks[i] = '?' end
  local rows = Db.query(([[
    SELECT charidentifier, firstname, lastname, job, jobgrade
    FROM characters WHERE job IN (%s)
    ORDER BY jobgrade DESC, lastname ASC
  ]]):format(table.concat(marks, ', ')), jobs) or {}
  local out = {}
  for _, r in ipairs(rows) do
    out[#out + 1] = {
      charid = tostring(r.charidentifier),
      name = (('%s %s'):format(r.firstname or '', r.lastname or ''))
        :gsub('^%s+', ''):gsub('%s+$', ''),
      job = r.job,
      grade = tonumber(r.jobgrade) or 0,
    }
  end
  return out
end
