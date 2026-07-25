--[[
  server/modules/sdb.lua — safety deposit boxes (design §5.5).

  A box is a rented physical drawer in the branch vault, backed by a
  vorp_inventory stash (contents live entirely in the inventory system; the
  bank stores only the box record). Rent runs on real-life days; past
  rent_paid_until + graceDays the box locks until rent is paid. Rent proceeds
  credit SYS-INSURANCE — vault upkeep is bank income.

  Opening a box is proximity-gated by the callbacks layer, and the teller UI
  closes before the stash opens (NUI focus and inventory focus don't mix).

  v1 keeps boxes owner-only; shared box access is a later addition.
]]

SDB = {}

local Err = Constants.Err
local DAY = 86400

local function stashId(boxId)
  return ('sovbank_sdb_%d'):format(boxId)
end

local function sizeCfg(size)
  return (Config.SDB.sizes or {})[size]
end

local function rentPrice(size)
  return tonumber((Config.Fees.sdbRent or {})[size]) or 0
end

function SDB.get(boxId)
  boxId = tonumber(boxId)
  if not boxId then return nil end
  return Db.single([[
    SELECT *, UNIX_TIMESTAMP(rent_paid_until) AS paid_epoch
    FROM sov_bank_sdb WHERE id = ?
  ]], { boxId })
end

function SDB.listFor(charid)
  return Db.query([[
    SELECT *, UNIX_TIMESTAMP(rent_paid_until) AS paid_epoch
    FROM sov_bank_sdb WHERE owner_id = ? ORDER BY id ASC
  ]], { tostring(charid) }) or {}
end

--- Charge a character's wallet and credit the insurance fund (two-phase with
--- compensation — the same pattern as bill settlement).
local function chargeWallet(charid, amount, memo, source)
  local ins = Accounts.getSystem(Constants.SystemAccounts.INSURANCE)
  if not ins then return false, Err.INTERNAL end
  local ok, res = Money.walletDebit(charid, Constants.Currency.MONEY, amount,
    { category = Constants.Category.SDB_RENT, memo = memo, source = source, silent = true })
  if not ok then return false, res end
  local ok2, res2 = Money.accountCredit(ins.id, Constants.Currency.MONEY, amount,
    { category = Constants.Category.SDB_RENT, memo = memo, source = source })
  if not ok2 then
    Money.walletCredit(charid, Constants.Currency.MONEY, amount, {
      category = Constants.Category.COMPENSATION, source = 'sov_bank',
      memo = ('reversal: %s'):format(memo), silent = true,
    })
    return false, res2
  end
  return true
end

--- Rent a new box (first rent period paid up front, from the wallet).
--- Returns (true, {boxId, paidUntil}) or (false, errCode).
function SDB.rentNew(charid, size, meta)
  meta = meta or {}
  if not (Config.SDB and Config.SDB.enabled) then return false, Err.NO_SDB end
  charid = tostring(charid)
  local cfg = sizeCfg(size)
  local price = rentPrice(size)
  if not cfg or price <= 0 then return false, Err.BAD_KIND end
  if #SDB.listFor(charid) >= (Config.SDB.maxPerChar or 2) then
    return false, Err.SDB_LIMIT
  end

  local ok, err = chargeWallet(charid, price,
    ('Deposit box rent (%s)'):format(size), meta.source)
  if not ok then return false, err end

  local paidUntil = os.time() + math.floor((Config.SDB.rentPeriodRealDays or 7) * DAY)
  local id = Db.insert([[
    INSERT INTO sov_bank_sdb (owner_id, size, stash_id, rent_paid_until)
    VALUES (?, ?, ?, FROM_UNIXTIME(?))
  ]], { charid, size, 'pending', paidUntil })
  if not id then return false, Err.INTERNAL end

  local sid = stashId(id)
  Db.execute('UPDATE sov_bank_sdb SET stash_id = ? WHERE id = ?', { sid, id })
  Bridge.RegisterStash(sid, ('Deposit Box %d'):format(id), cfg.slots or 10)

  Log.info('sdb #%d rented by %s (%s, %s slots)', id, charid, size, cfg.slots)
  return true, { boxId = id, paidUntil = paidUntil }
end

--- Pay another rent period on an existing box. Extends from the later of
--- now / current paid-until, so paying early never wastes days.
function SDB.payRent(boxId, charid, meta)
  meta = meta or {}
  charid = tostring(charid)
  local box = SDB.get(boxId)
  if not box then return false, Err.NO_SDB end
  if tostring(box.owner_id) ~= charid then return false, Err.ACCESS end

  local price = rentPrice(box.size)
  if price <= 0 then return false, Err.INTERNAL end
  local ok, err = chargeWallet(charid, price,
    ('Deposit box #%d rent'):format(box.id), meta.source)
  if not ok then return false, err end

  local now = os.time()
  local base = math.max(now, tonumber(box.paid_epoch) or now)
  local paidUntil = base + math.floor((Config.SDB.rentPeriodRealDays or 7) * DAY)
  Db.execute('UPDATE sov_bank_sdb SET rent_paid_until = FROM_UNIXTIME(?) WHERE id = ?',
    { paidUntil, box.id })
  return true, { boxId = box.id, paidUntil = paidUntil }
end

--- May this box be opened right now? (rent current, within grace)
function SDB.canOpen(box)
  local paid = tonumber(box.paid_epoch)
  if not paid then return true end
  local grace = math.floor((Config.SDB.graceDays or 3) * DAY)
  return os.time() <= paid + grace
end

--- Open the vault drawer (proximity verified by the caller). The teller UI
--- must close first — the caller sequences that.
function SDB.open(boxId, charid, src)
  local box = SDB.get(boxId)
  if not box then return false, Err.NO_SDB end
  if tostring(box.owner_id) ~= tostring(charid) then return false, Err.ACCESS end
  if not SDB.canOpen(box) then return false, Err.RENT_DUE end

  -- Registration is idempotent in vorp_inventory; re-register defensively so
  -- boxes survive inventory-resource restarts.
  local cfg = sizeCfg(box.size) or { slots = 10 }
  Bridge.RegisterStash(box.stash_id, ('Deposit Box %d'):format(box.id), cfg.slots)

  SetTimeout(400, function()
    Bridge.OpenStash(src, box.stash_id)
  end)
  return true, { boxId = box.id }
end

--- Boot: re-register every box's stash so contents are reachable.
function SDB.registerAll()
  local rows = Db.query('SELECT id, stash_id, size FROM sov_bank_sdb') or {}
  for _, r in ipairs(rows) do
    local cfg = sizeCfg(r.size) or { slots = 10 }
    Bridge.RegisterStash(r.stash_id, ('Deposit Box %d'):format(r.id), cfg.slots)
  end
  if #rows > 0 then Log.info('registered %d deposit-box stashes', #rows) end
end
