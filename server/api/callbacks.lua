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

--- Admin handlers are gated by PERMISSION rather than proximity: the
--- /bankadmin panel is an ops tool, not a teller service, so it works away
--- from a branch — but every call re-checks the ACE/allow-list server-side.
local function adminGuarded(fn)
  return function(src, payload)
    if not Admin.isAllowed(src) then
      Log.warn('unauthorized admin rpc from %s', tostring(src))
      return { ok = false, error = Err.ACCESS }
    end
    local charid = Bridge.GetCharId(src) or ('src:' .. tostring(src))
    return fn({ src = src, charid = charid, actor = charid }, payload)
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

--- Society membership block for the teller payload (nil when jobless).
local function societyInfo(src)
  local soc, isBoss = Society.forSource(src)
  if not soc then return nil end
  return { id = soc.id, name = soc.name, isBoss = isBoss }
end

handlers['getTellerData'] = guarded(function(ctx)
  Accounts.ensurePrimary(ctx.charid)
  Savings.accrueForChar(ctx.charid) -- lazy interest posting (design §5.4)
  return okWith(ctx, {
    branch = {
      id = ctx.branch.id,
      name = ctx.branch.name,
      subtitle = ctx.branch.subtitle,
      hours = ctx.branch.hours,
      features = ctx.branch.features or {},
    },
    society = societyInfo(ctx.src),
    openBills = #Billing.listOpenFor(ctx.charid),
    config = {
      currencies = Config.Currencies,
      maxAccounts = Config.MaxAccounts,
      fees = {
        same = Config.Fees.transferSameBranch,
        cross = Config.Fees.transferCrossBranch,
      },
      savingsAPR = Config.Interest.savingsAPR,
      loans = {
        enabled = Config.Loans.enabled ~= false,
        rate = Config.Loans.originationRate,
        maxPrincipal = Config.Loans.maxPrincipal,
        termDays = Config.Loans.defaultTermRealDays,
      },
      gold = Config.Gold and Config.Gold.enabled and Config.Currencies.gold
        and Gold.quote() or nil,
      sdb = Config.SDB and Config.SDB.enabled and {
        rent = Config.Fees.sdbRent,
        periodDays = Config.SDB.rentPeriodRealDays,
        maxPerChar = Config.SDB.maxPerChar,
        sizes = Config.SDB.sizes,
      } or nil,
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
  local filter = {
    limit = math.min(tonumber(p.limit) or 25, 100),
    offset = tonumber(p.offset) or 0,
    category = type(p.category) == 'string' and p.category or nil,
  }
  local rows = Ledger.getTransactions(accountId, filter)
  local total = Ledger.countTransactions(accountId, filter)
  return { ok = true, data = { rows = rows, total = total } }
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

-- ============================================================================
-- Bills (design §5.7 — settled in person at the counter)
-- ============================================================================

local function issuerDisplay(bill)
  if bill.issuer_type == 'society' then
    local soc = Society.get(bill.issuer_id)
    return soc and soc.name or bill.issuer_id
  end
  if bill.issuer_type == 'character' then
    return Bridge.GetCharName(bill.issuer_id)
  end
  return 'Sovereign County'
end

local function billView(bill)
  return {
    id = bill.id,
    kind = bill.kind,
    status = bill.status,
    amount = tonumber(bill.amount) or 0,
    remaining = tonumber(bill.balance_remaining) or 0,
    currency = tonumber(bill.currency) or 0,
    memo = bill.memo,
    issuer = issuerDisplay(bill),
    dueAt = tonumber(bill.due_epoch),
    createdAt = tonumber(bill.created_epoch),
  }
end

handlers['bills'] = guarded(function(ctx)
  local rows = {}
  for _, bill in ipairs(Billing.listOpenFor(ctx.charid)) do
    rows[#rows + 1] = billView(bill)
  end
  return { ok = true, data = { rows = rows } }
end)

handlers['payBill'] = guarded(function(ctx, p)
  local payWith = p.payWith
  if payWith ~= 'wallet' then
    payWith = tonumber(payWith)
    if not payWith or not Accounts.hasLevel(payWith, ctx.charid, 'withdraw') then
      return { ok = false, error = Err.ACCESS }
    end
  end
  local amount = p.amount ~= nil and parseAmount(p.amount) or nil
  if p.amount ~= nil and not amount then return { ok = false, error = Err.BAD_AMOUNT } end

  local ok, res = Billing.pay(p.billId, ctx.charid, payWith, amount, { source = 'sov_bank' })
  if not ok then return { ok = false, error = res } end

  local rows = {}
  for _, bill in ipairs(Billing.listOpenFor(ctx.charid)) do
    rows[#rows + 1] = billView(bill)
  end
  return okWith(ctx, { result = res, bills = rows, openBills = #rows })
end)

-- ============================================================================
-- Society desk (design §5.8 — boss actions re-verified server-side each call)
-- ============================================================================

--- Society context guard: returns soc, isBoss, account (or responds w/ error).
local function societyCtx(ctx, needBoss)
  local soc, isBoss = Society.forSource(ctx.src)
  if not soc then return nil, { ok = false, error = Err.NO_SOCIETY } end
  if needBoss and not isBoss then return nil, { ok = false, error = Err.NOT_BOSS } end
  local acct = Society.account(soc.id)
  if not acct then return nil, { ok = false, error = Err.NO_SOCIETY } end
  return { soc = soc, isBoss = isBoss, acct = acct }
end

handlers['society'] = guarded(function(ctx)
  local sctx, errRes = societyCtx(ctx, false)
  if not sctx then return errRes end

  local data = {
    id = sctx.soc.id,
    name = sctx.soc.name,
    isBoss = sctx.isBoss,
    account = {
      id = sctx.acct.id,
      number = sctx.acct.account_number,
      balance = tonumber(sctx.acct.balance_money) or 0,
    },
  }
  if sctx.isBoss then
    data.roster = Society.roster(sctx.soc.id)
    data.recent = Ledger.getTransactions(sctx.acct.id, { limit = 8 })
  end
  return { ok = true, data = data }
end)

handlers['societyDeposit'] = guarded(function(ctx, p)
  local sctx, errRes = societyCtx(ctx, true)
  if not sctx then return errRes end
  local amount = parseAmount(p.amount)
  if not amount then return { ok = false, error = Err.BAD_AMOUNT } end
  local ok, res = Money.deposit(ctx.charid, sctx.acct.id, Constants.Currency.MONEY, amount, {
    category = Constants.Category.DEPOSIT,
    source = 'sov_bank',
    memo = ('%s fund deposit — %s'):format(sctx.soc.name, ctx.branch.name),
  })
  if not ok then return { ok = false, error = res } end
  return okWith(ctx, { result = res })
end)

handlers['societyWithdraw'] = guarded(function(ctx, p)
  local sctx, errRes = societyCtx(ctx, true)
  if not sctx then return errRes end
  local amount = parseAmount(p.amount)
  if not amount then return { ok = false, error = Err.BAD_AMOUNT } end
  local ok, res = Money.withdraw(ctx.charid, sctx.acct.id, Constants.Currency.MONEY, amount, {
    category = Constants.Category.WITHDRAW,
    source = 'sov_bank',
    memo = ('%s fund withdrawal — %s'):format(sctx.soc.name, ctx.branch.name),
  })
  if not ok then return { ok = false, error = res } end
  return okWith(ctx, { result = res })
end)

-- ============================================================================
-- Loans (design §5.3 — apply, view, repay; approval via console/admin)
-- ============================================================================

local function loanView(l)
  return {
    id = l.id,
    principal = tonumber(l.principal) or 0,
    totalDue = tonumber(l.total_due) or 0,
    remaining = tonumber(l.balance_remaining) or 0,
    status = l.status,
    dueBy = tonumber(l.due_epoch),
    createdAt = tonumber(l.created_epoch),
  }
end

handlers['loans'] = guarded(function(ctx)
  local rows = {}
  for _, l in ipairs(Loans.listFor(ctx.charid)) do
    rows[#rows + 1] = loanView(l)
  end
  return { ok = true, data = { rows = rows } }
end)

handlers['applyLoan'] = guarded(function(ctx, p)
  local amount = parseAmount(p.amount)
  if not amount then return { ok = false, error = Err.BAD_AMOUNT } end
  local accountId = tonumber(p.accountId)
  -- Disbursement target must be an account the borrower OWNS.
  if accountId and Accounts.getAccessLevel(accountId, ctx.charid) ~= 'owner' then
    return { ok = false, error = Err.ACCESS }
  end
  local ok, res = Loans.create(ctx.charid, amount, nil, accountId, { source = 'sov_bank' })
  if not ok then return { ok = false, error = res } end
  local rows = {}
  for _, l in ipairs(Loans.listFor(ctx.charid)) do rows[#rows + 1] = loanView(l) end
  return okWith(ctx, { result = res, loans = rows })
end)

handlers['repayLoan'] = guarded(function(ctx, p)
  local payWith = p.payWith
  if payWith ~= 'wallet' then
    payWith = tonumber(payWith)
    if not payWith or not Accounts.hasLevel(payWith, ctx.charid, 'withdraw') then
      return { ok = false, error = Err.ACCESS }
    end
  end
  local amount = p.amount ~= nil and parseAmount(p.amount) or nil
  if p.amount ~= nil and not amount then return { ok = false, error = Err.BAD_AMOUNT } end
  local ok, res = Loans.repay(p.loanId, ctx.charid, payWith, amount, { source = 'sov_bank' })
  if not ok then return { ok = false, error = res } end
  local rows = {}
  for _, l in ipairs(Loans.listFor(ctx.charid)) do rows[#rows + 1] = loanView(l) end
  return okWith(ctx, { result = res, loans = rows })
end)

-- ============================================================================
-- Safety deposit boxes (design §5.5)
-- ============================================================================

local function sdbRows(charid)
  local rows = {}
  for _, b in ipairs(SDB.listFor(charid)) do
    rows[#rows + 1] = {
      id = b.id,
      size = b.size,
      paidUntil = tonumber(b.paid_epoch),
      locked = not SDB.canOpen(b),
    }
  end
  return rows
end

handlers['sdbList'] = guarded(function(ctx)
  return { ok = true, data = { rows = sdbRows(ctx.charid) } }
end)

handlers['sdbRent'] = guarded(function(ctx, p)
  local ok, res = SDB.rentNew(ctx.charid, tostring(p.size or ''), { source = 'sov_bank' })
  if not ok then return { ok = false, error = res } end
  return okWith(ctx, { result = res, boxes = sdbRows(ctx.charid) })
end)

handlers['sdbPayRent'] = guarded(function(ctx, p)
  local ok, res = SDB.payRent(p.boxId, ctx.charid, { source = 'sov_bank' })
  if not ok then return { ok = false, error = res } end
  return okWith(ctx, { result = res, boxes = sdbRows(ctx.charid) })
end)

handlers['sdbOpen'] = guarded(function(ctx, p)
  -- The client closes the teller UI on success; the stash opens right after.
  local ok, res = SDB.open(p.boxId, ctx.charid, ctx.src)
  if not ok then return { ok = false, error = res } end
  return { ok = true, data = { openStash = true } }
end)

-- ============================================================================
-- Gold exchange (design §5.6)
-- ============================================================================

handlers['goldExchange'] = guarded(function(ctx, p)
  local goldMinor = parseAmount(p.gold)
  if not goldMinor then return { ok = false, error = Err.BAD_AMOUNT } end
  local dir = p.direction == 'sell' and 'sell' or 'buy'
  local ok, res = Gold.exchange(ctx.charid, dir, goldMinor, { source = 'sov_bank' })
  if not ok then return { ok = false, error = res } end
  return okWith(ctx, { result = res, quote = Gold.quote() })
end)

-- ============================================================================
-- Admin panel (design §5.12) — permission-gated, works away from a branch
-- ============================================================================

local function adminAccountView(a)
  return {
    id = a.id,
    number = a.account_number,
    name = a.name,
    kind = a.kind,
    ownerType = a.owner_type,
    ownerId = a.owner_id,
    status = a.status,
    balances = {
      money = tonumber(a.balance_money) or 0,
      gold = tonumber(a.balance_gold) or 0,
    },
  }
end

handlers['adminData'] = adminGuarded(function(ctx)
  local pending = {}
  for _, l in ipairs(Loans.listPending()) do
    pending[#pending + 1] = {
      id = l.id,
      charid = l.charidentifier,
      name = Bridge.GetCharName(l.charidentifier),
      principal = tonumber(l.principal) or 0,
      totalDue = tonumber(l.total_due) or 0,
    }
  end
  return { ok = true, data = {
    isAdmin = true,
    actor = ctx.charid,
    supply = Admin.moneySupply(7),
    pendingLoans = pending,
  } }
end)

handlers['adminSearch'] = adminGuarded(function(_, p)
  local rows = {}
  for _, a in ipairs(Admin.searchAccounts(p.term, 25)) do
    rows[#rows + 1] = adminAccountView(a)
  end
  return { ok = true, data = { rows = rows } }
end)

handlers['adminSetStatus'] = adminGuarded(function(ctx, p)
  local ok, res = Admin.setStatus(p.accountId, p.status, ctx.actor)
  if not ok then return { ok = false, error = res } end
  return { ok = true, data = { result = res } }
end)

handlers['adminAdjust'] = adminGuarded(function(ctx, p)
  local delta = math.floor(tonumber(p.delta) or 0)
  if delta == 0 then return { ok = false, error = Err.BAD_AMOUNT } end
  local ok, res = Admin.adjust(p.accountId, tonumber(p.currency) or 0, delta,
    ctx.actor, p.reason)
  if not ok then return { ok = false, error = res } end
  return { ok = true, data = { result = res } }
end)

handlers['adminReconcile'] = adminGuarded(function(_, p)
  return { ok = true, data = Admin.reconcileAll(tonumber(p.limit) or 200, 0) }
end)

handlers['adminLoanDecision'] = adminGuarded(function(ctx, p)
  local ok, res = (p.decision == 'approve')
    and Loans.approve(p.loanId, ctx.actor)
    or Loans.deny(p.loanId, ctx.actor)
  if not ok then return { ok = false, error = res } end
  local pending = {}
  for _, l in ipairs(Loans.listPending()) do
    pending[#pending + 1] = {
      id = l.id, charid = l.charidentifier,
      name = Bridge.GetCharName(l.charidentifier),
      principal = tonumber(l.principal) or 0,
      totalDue = tonumber(l.total_due) or 0,
    }
  end
  return { ok = true, data = { result = res, pendingLoans = pending } }
end)

handlers['societyPayroll'] = guarded(function(ctx, p)
  local sctx, errRes = societyCtx(ctx, true)
  if not sctx then return errRes end
  if type(p.entries) ~= 'table' or #p.entries == 0 or #p.entries > 50 then
    return { ok = false, error = Err.PAYROLL_EMPTY }
  end
  local entries = {}
  for _, e in ipairs(p.entries) do
    local amount = parseAmount(e and e.amount)
    if not amount then return { ok = false, error = Err.BAD_AMOUNT } end
    entries[#entries + 1] = { charid = tostring(e.charid or ''), amount = amount }
  end
  local ok, res = Society.payroll(sctx.soc.id, entries, {
    source = 'sov_bank',
    memo = ('%s payroll — run by %s'):format(sctx.soc.name, ctx.charid),
  })
  if not ok then return { ok = false, error = res } end
  return okWith(ctx, { result = res })
end)
