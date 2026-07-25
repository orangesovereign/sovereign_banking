--[[
  server/api/callbacks.lua — client→server RPC for the teller NUI
  (design §6.3, tech spec §7.3).

  Implemented as a self-contained request/response layer over net events
  instead of VORP's callback API (whose register/trigger names vary between
  VORP versions — tech spec §16.5). Semantics are identical; the client side
  lives in client/nui.lua.

  Security model (tech spec §11):
  - EVERY handler is proximity-gated: the server resolves the player's actual
    position and rejects with ERR_NOT_AT_BRANCH unless they are at a teller.
  - Per-source token-bucket rate limiting.
  - The client only ever sends intent (account ids, amounts); identity comes
    from the connection, balances are re-read server-side, and access levels
    are enforced on every call.
]]

local Err = Constants.Err
local handlers = {}

-- ============================================================================
-- Rate limiting: token bucket per source (15 burst, 1/sec refill)
-- ============================================================================

local buckets = {}
local BUCKET_MAX, REFILL_PER_SEC = 15, 1

local function allowRequest(src)
  local now = os.time()
  local b = buckets[src]
  if not b then
    b = { tokens = BUCKET_MAX, last = now }
    buckets[src] = b
  end
  b.tokens = math.min(BUCKET_MAX, b.tokens + (now - b.last) * REFILL_PER_SEC)
  b.last = now
  if b.tokens < 1 then return false end
  b.tokens = b.tokens - 1
  return true
end

AddEventHandler('playerDropped', function()
  buckets[source] = nil
end)

-- ============================================================================
-- Transport
-- ============================================================================

RegisterNetEvent('sov_bank:rpc:request', function(name, reqId, payload)
  local src = source
  if type(name) ~= 'string' or reqId == nil then return end

  local function respond(res)
    TriggerClientEvent('sov_bank:rpc:response', src, reqId, res)
  end

  if not allowRequest(src) then
    Log.warn('rate-limited rpc from %s (%s)', src, name)
    return respond({ ok = false, error = Err.RATE_LIMITED })
  end

  local fn = handlers[name]
  if not fn then
    return respond({ ok = false, error = Err.INTERNAL })
  end

  local ok, res = pcall(fn, src, type(payload) == 'table' and payload or {})
  if not ok then
    Log.error('rpc %s crashed: %s', name, tostring(res))
    res = { ok = false, error = Err.INTERNAL }
  end
  respond(res)
end)

-- ============================================================================
-- Guards & helpers
-- ============================================================================

--- Wraps a handler with the teller context: at-branch check + charid resolve.
local function guarded(fn)
  return function(src, payload)
    local branch = Branches.forSource(src)
    if not branch then return { ok = false, error = Err.NOT_AT_BRANCH } end
    local charid = Bridge.GetCharId(src)
    if not charid then return { ok = false, error = Err.UNKNOWN_CHAR } end
    return fn({ src = src, branch = branch, charid = charid }, payload)
  end
end

--- Amounts from the NUI arrive as integer minor units; never trust them.
local function parseAmount(v)
  local n = tonumber(v)
  if not n then return nil end
  n = math.floor(n)
  if not Util.isValidAmount(n) then return nil end
  return n
end

--- Fresh accounts + wallet snapshot; returned after every mutation so the UI
--- never has to guess at state.
local function snapshot(ctx)
  local out = {}
  for _, a in ipairs(Accounts.listForChar(ctx.charid)) do
    out[#out + 1] = {
      id = a.id,
      number = a.account_number,
      name = a.name,
      kind = a.kind,
      status = a.status,
      access = a.access_level,
      isOwner = a.owner_type == 'character' and tostring(a.owner_id) == ctx.charid,
      balances = {
        money = tonumber(a.balance_money) or 0,
        gold = tonumber(a.balance_gold) or 0,
        rol = tonumber(a.balance_rol) or 0,
      },
    }
  end
  local wallet = {}
  for id, name in pairs(Constants.CurrencyName) do
    if Config.Currencies[name] then
      wallet[name] = Bridge.WalletGet(ctx.src, id) or 0
    end
  end
  return { accounts = out, wallet = wallet }
end

local function okWith(ctx, extra)
  local data = snapshot(ctx)
  if extra then
    for k, v in pairs(extra) do data[k] = v end
  end
  return { ok = true, data = data }
end

-- ============================================================================
-- Handlers
-- ============================================================================

handlers['getTellerData'] = guarded(function(ctx)
  Accounts.ensurePrimary(ctx.charid)
  return okWith(ctx, {
    branch = { id = ctx.branch.id, name = ctx.branch.name, features = ctx.branch.features or {} },
    config = {
      currencies = Config.Currencies,
      maxAccounts = Config.MaxAccounts,
      fees = {
        same = Config.Fees.transferSameBranch,
        cross = Config.Fees.transferCrossBranch,
      },
      savingsAPR = Config.Interest.savingsAPR,
    },
  })
end)

handlers['deposit'] = guarded(function(ctx, p)
  local amount = parseAmount(p.amount)
  if not amount then return { ok = false, error = Err.BAD_AMOUNT } end
  if not Accounts.hasLevel(tonumber(p.accountId), ctx.charid, 'deposit') then
    return { ok = false, error = Err.ACCESS }
  end
  local ok, res = Money.deposit(ctx.charid, p.accountId, tonumber(p.currency), amount, {
    category = Constants.Category.DEPOSIT,
    source = 'sov_bank',
    memo = ('Teller deposit — %s'):format(ctx.branch.name),
  })
  if not ok then return { ok = false, error = res } end
  return okWith(ctx, { result = res })
end)

handlers['withdraw'] = guarded(function(ctx, p)
  local amount = parseAmount(p.amount)
  if not amount then return { ok = false, error = Err.BAD_AMOUNT } end
  if not Accounts.hasLevel(tonumber(p.accountId), ctx.charid, 'withdraw') then
    return { ok = false, error = Err.ACCESS }
  end
  local ok, res = Money.withdraw(ctx.charid, p.accountId, tonumber(p.currency), amount, {
    category = Constants.Category.WITHDRAW,
    source = 'sov_bank',
    memo = ('Teller withdrawal — %s'):format(ctx.branch.name),
  })
  if not ok then return { ok = false, error = res } end
  return okWith(ctx, { result = res })
end)

handlers['transfer'] = guarded(function(ctx, p)
  local amount = parseAmount(p.amount)
  if not amount then return { ok = false, error = Err.BAD_AMOUNT } end
  local fromId = tonumber(p.fromId)
  if not Accounts.hasLevel(fromId, ctx.charid, 'withdraw') then
    return { ok = false, error = Err.ACCESS }
  end

  local target
  if p.toId then
    target = Accounts.getById(tonumber(p.toId))
  elseif type(p.toNumber) == 'string' then
    target = Accounts.getByNumber(p.toNumber:upper():gsub('%s', ''))
  end
  if not target then return { ok = false, error = Err.NO_ACCOUNT } end

  -- Fee class: moving between your own accounts is free-by-default
  -- (sameBranch); paying anyone else is a "wire" (crossBranch). See config.
  local ownTarget = Accounts.getAccessLevel(target, ctx.charid) == 'owner'

  local ok, res = Money.transfer(fromId, target.id, tonumber(p.currency), amount, {
    category = Constants.Category.TRANSFER,
    source = 'sov_bank',
    memo = Util.truncate(p.memo, 140) or ('Teller transfer — %s'):format(ctx.branch.name),
    crossBranch = (not ownTarget) or nil,
  })
  if not ok then return { ok = false, error = res } end
  return okWith(ctx, { result = res })
end)

handlers['openAccount'] = guarded(function(ctx, p)
  local kind = p.kind == 'savings' and Constants.AccountKind.SAVINGS
    or Constants.AccountKind.CHECKING
  local acct, err = Accounts.createNamed(ctx.charid, p.name, kind)
  if not acct then return { ok = false, error = err } end
  return okWith(ctx, { created = acct.id })
end)

handlers['closeAccount'] = guarded(function(ctx, p)
  local ok, res = Accounts.close(p.accountId, ctx.charid)
  if not ok then return { ok = false, error = res } end
  return okWith(ctx, {})
end)

handlers['statement'] = guarded(function(ctx, p)
  local accountId = tonumber(p.accountId)
  if not Accounts.hasLevel(accountId, ctx.charid, 'read') then
    return { ok = false, error = Err.ACCESS }
  end
  local rows = Ledger.getTransactions(accountId, {
    limit = math.min(tonumber(p.limit) or 25, 100),
    offset = tonumber(p.offset) or 0,
    category = type(p.category) == 'string' and p.category or nil,
  })
  return { ok = true, data = { rows = rows } }
end)

handlers['accountAccess'] = guarded(function(ctx, p)
  local accountId = tonumber(p.accountId)
  local acct = Accounts.getById(accountId)
  if not acct then return { ok = false, error = Err.NO_ACCOUNT } end
  if not Accounts.hasLevel(acct, ctx.charid, 'admin') then
    return { ok = false, error = Err.ACCESS }
  end
  local ownerId = acct.owner_type == 'character' and tostring(acct.owner_id) or nil
  local rows = {}
  for _, r in ipairs(Accounts.listAccess(accountId)) do
    rows[#rows + 1] = {
      charid = r.charidentifier,
      level = r.access_level,
      grantedBy = r.granted_by,
      isOwner = r.charidentifier == ownerId,
    }
  end
  return { ok = true, data = { rows = rows, myLevel = Accounts.getAccessLevel(acct, ctx.charid) } }
end)

handlers['grantAccess'] = guarded(function(ctx, p)
  local ok, res = Accounts.grantAccess(p.accountId, ctx.charid, tostring(p.charid or ''), p.level)
  if not ok then return { ok = false, error = res } end
  return { ok = true, data = {} }
end)

handlers['revokeAccess'] = guarded(function(ctx, p)
  local ok, res = Accounts.revokeAccess(p.accountId, ctx.charid, tostring(p.charid or ''))
  if not ok then return { ok = false, error = res } end
  return { ok = true, data = {} }
end)
