--[[
  server/engine/money.lua — the single choke point for every balance change
  (tech spec §5). No module writes a balance directly; they all come through
  here. Guarantees:

  - Per-account mutex serializes concurrent mutations (tech spec §5.4).
  - Idempotency: an operation replayed with the same opts.idem returns the
    original result instead of re-applying (tech spec §5.3).
  - Multi-leg operations (transfers) commit every balance update + ledger row
    in ONE SQL transaction, so a crash can never leave half a movement.
  - Wallet legs (deposit/withdraw) follow commit-then-apply with compensation:
    the DB commits first, the VORP wallet is applied second, and a wallet
    failure writes an offsetting ledger entry + reverses the balance
    (tech spec §5.5).

  Implementation note vs tech spec §5.5: oxmysql's transaction API takes a
  fixed statement array — there is no way to read a row or branch on
  affectedRows *inside* the transaction. The equivalent guarantees are built
  from three layers instead:
    1. the per-account mutex makes this resource's read-validate-write
       sequences race-free (the bank is the only writer of its tables);
    2. debit UPDATEs still carry a funds guard in their WHERE clause as
       defense-in-depth against out-of-band writes;
    3. a post-commit verification compares each stored balance to the expected
       value and rolls the operation back loudly if a guard silently no-opped.
]]

Money = {}

local Err = Constants.Err

-- ============================================================================
-- Per-key mutex (tech spec §5.4)
-- ============================================================================

local lockQueues = {}

local function lockAcquire(key)
  local q = lockQueues[key]
  if not q then
    lockQueues[key] = { waiting = {} }
    return
  end
  local p = promise.new()
  q.waiting[#q.waiting + 1] = p
  Citizen.Await(p)
end

local function lockRelease(key)
  local q = lockQueues[key]
  if not q then return end
  local nextUp = table.remove(q.waiting, 1)
  if nextUp then
    nextUp:resolve(true)
  else
    lockQueues[key] = nil
  end
end

--- Runs fn while holding every lock in keys. Keys are deduped and acquired in
--- sorted order so two multi-account ops can never deadlock. fn must return
--- (ok, result); a crash inside fn maps to ERR_INTERNAL.
function Money.withLocks(keys, fn)
  local uniq, seen = {}, {}
  for _, k in ipairs(keys) do
    if not seen[k] then
      seen[k] = true
      uniq[#uniq + 1] = k
    end
  end
  table.sort(uniq)
  for i = 1, #uniq do lockAcquire(uniq[i]) end
  local res = table.pack(pcall(fn))
  for i = #uniq, 1, -1 do lockRelease(uniq[i]) end
  if not res[1] then
    Log.error('money operation crashed: %s', tostring(res[2]))
    return false, Err.INTERNAL
  end
  return res[2], res[3]
end

-- ============================================================================
-- Validation & shared helpers
-- ============================================================================

local function checkCurrencyAndAmount(currency, amount)
  local name = Constants.CurrencyName[currency]
  if not name then return false, Err.BAD_CURRENCY end
  if not Config.Currencies[name] then return false, Err.CURRENCY_DISABLED end
  if not Util.isValidAmount(amount) then return false, Err.BAD_AMOUNT end
  return true
end

local function statusErr(status)
  return status == 'frozen' and Err.FROZEN or Err.ACCOUNT_CLOSED
end

local function replayOf(row)
  return {
    txId = row.tx_uuid,
    balanceAfter = row.balance_after and tonumber(row.balance_after) or nil,
    replayed = true,
  }
end

-- ============================================================================
-- Leg machinery. A "leg" is one account-side balance change plus its ledger
-- row. Multi-leg operations concatenate their legs into a single SQL
-- transaction.
--
-- leg = {
--   acct         = fresh account row (read under lock),
--   currency     = 0|1|2,
--   delta        = signed minor units,
--   floorBal     = debit floor (0, or -credit_limit when overdraft allowed),
--   unguarded    = true to skip the funds guard (compensation legs only),
--   uuid, category, memo, source, counterparty,
-- }
-- After commit, leg.newBal holds the account's expected post-op balance.
-- ============================================================================

local function legStatements(leg)
  local col = Constants.CurrencyColumn[leg.currency]
  leg.newBal = (tonumber(leg.acct[col]) or 0) + leg.delta

  local update
  if leg.delta < 0 and not leg.unguarded then
    update = {
      query = ('UPDATE sov_bank_accounts SET %s = %s + ? WHERE id = ? AND status = \'active\' AND %s + ? >= ?')
        :format(col, col, col),
      values = { leg.delta, leg.acct.id, leg.delta, leg.floorBal or 0 },
    }
  else
    update = {
      query = ('UPDATE sov_bank_accounts SET %s = %s + ? WHERE id = ? AND status = \'active\'')
        :format(col, col),
      values = { leg.delta, leg.acct.id },
    }
  end

  -- Dynamic column list keeps optional fields as SQL NULL (oxmysql params
  -- must be dense arrays — a nil hole would truncate them).
  local cols, marks, vals = {}, {}, {}
  local function add(c, v)
    if v ~= nil then
      cols[#cols + 1] = c
      marks[#marks + 1] = '?'
      vals[#vals + 1] = v
    end
  end
  add('tx_uuid', leg.uuid)
  add('account_id', leg.acct.id)
  add('counterparty_account_id', leg.counterparty)
  add('currency', leg.currency)
  add('direction', leg.delta >= 0 and 'credit' or 'debit')
  add('amount', math.abs(leg.delta))
  add('balance_after', leg.newBal)
  add('category', Util.truncate(leg.category, 40) or 'adjust') -- column is NOT NULL
  add('source_resource', Util.truncate(leg.source, 48))
  add('memo', Util.truncate(leg.memo, 140))

  local insert = {
    query = ('INSERT INTO sov_bank_transactions (%s) VALUES (%s)')
      :format(table.concat(cols, ', '), table.concat(marks, ', ')),
    values = vals,
  }
  return update, insert
end

--- Commit legs atomically, then verify every stored balance matches the
--- expected value. Returns 'ok' | 'replay', row | 'fail', errCode.
local function commitLegs(legs)
  local stmts = {}
  for _, leg in ipairs(legs) do
    local update, insert = legStatements(leg)
    stmts[#stmts + 1] = update
    stmts[#stmts + 1] = insert
  end

  if not Db.transaction(stmts) then
    -- Most likely a duplicate tx_uuid: a concurrent caller with the same
    -- idempotency key won the race. Return their stored result.
    local row = Ledger.findByUuid(legs[1].uuid)
    if row then return 'replay', row end
    return 'fail', Err.INTERNAL
  end

  -- Post-commit verification, once per (account, currency) against the FINAL
  -- expected balance (several legs may touch the same account — e.g. a
  -- transfer's amount + fee debits). Under the mutex only out-of-band writes
  -- can make a guard no-op; if that ever happens, undo the whole operation
  -- and scream — reconciliation is the final backstop.
  -- Same-account legs are pre-folded by the caller (each later leg's acct row
  -- reflects the earlier leg's delta), so the LAST leg's newBal for a key is
  -- that account's final expected balance.
  local finals, order = {}, {}
  for _, leg in ipairs(legs) do
    local key = tostring(leg.acct.id) .. ':' .. tostring(leg.currency)
    if not finals[key] then
      order[#order + 1] = key
      finals[key] = { accountId = leg.acct.id, currency = leg.currency, expected = leg.newBal, netDelta = 0 }
    end
    finals[key].expected = leg.newBal
    finals[key].netDelta = finals[key].netDelta + leg.delta
  end

  for _, key in ipairs(order) do
    local f = finals[key]
    local col = Constants.CurrencyColumn[f.currency]
    local observed = tonumber(Db.scalar(
      ('SELECT %s FROM sov_bank_accounts WHERE id = ?'):format(col), { f.accountId }))
    if observed ~= f.expected then
      Log.error('CRITICAL: balance guard mismatch on account %s (expected %s, observed %s) — rolling back op %s',
        tostring(f.accountId), tostring(f.expected), tostring(observed), tostring(legs[1].uuid))
      for _, k in ipairs(order) do
        local g = finals[k]
        local c = Constants.CurrencyColumn[g.currency]
        local obs = tonumber(Db.scalar(
          ('SELECT %s FROM sov_bank_accounts WHERE id = ?'):format(c), { g.accountId }))
        if obs == g.expected then -- this account's updates applied; reverse them
          Db.execute(('UPDATE sov_bank_accounts SET %s = %s - ? WHERE id = ?'):format(c, c),
            { g.netDelta, g.accountId })
        end
      end
      for _, l in ipairs(legs) do
        Db.execute('DELETE FROM sov_bank_transactions WHERE tx_uuid = ?', { l.uuid })
      end
      return 'fail', Err.INTERNAL
    end
  end

  return 'ok'
end

local function announceLegs(legs)
  for _, leg in ipairs(legs) do
    local charid = leg.acct.owner_type == 'character' and tostring(leg.acct.owner_id) or nil
    Events.transactionCompleted({
      charid = charid,
      accountId = leg.acct.id,
      currency = leg.currency,
      amount = math.abs(leg.delta),
      direction = leg.delta >= 0 and 'credit' or 'debit',
      category = leg.category,
      txId = leg.uuid,
    })
    Events.balanceChanged({
      charid = charid,
      accountId = leg.acct.id,
      currency = leg.currency,
      newBalance = leg.newBal,
    })
  end
end

-- Debit floor for an account: 0, or -credit_limit when overdraft is permitted.
local function debitFloor(acct, meta)
  if meta.allowNeg and Config.Credit.enabled then
    return -(tonumber(acct.credit_limit) or 0)
  end
  return 0
end

-- ============================================================================
-- Bank-account operations (no wallet leg)
-- ============================================================================

local function accountOp(accountId, currency, amount, sign, meta)
  meta = meta or {}
  local ok, err = checkCurrencyAndAmount(currency, amount)
  if not ok then return false, err end
  accountId = tonumber(accountId)
  if not accountId then return false, Err.NO_ACCOUNT end

  return Money.withLocks({ 'acct:' .. accountId }, function()
    if meta.idem then
      local row = Ledger.findByUuid(meta.idem)
      if row then return true, replayOf(row) end
    end

    local acct = Accounts.getById(accountId)
    if not acct then return false, Err.NO_ACCOUNT end
    if acct.status ~= 'active' then return false, statusErr(acct.status) end

    local floorBal = 0
    if sign < 0 then
      floorBal = debitFloor(acct, meta)
      local col = Constants.CurrencyColumn[currency]
      local bal = tonumber(acct[col]) or 0
      if bal - amount < floorBal then
        return false, floorBal < 0 and Err.NO_CREDIT or Err.INSUFFICIENT_FUNDS
      end
    end

    local leg = {
      acct = acct, currency = currency, delta = sign * amount, floorBal = floorBal,
      uuid = meta.idem or Util.uuid(), category = meta.category,
      memo = meta.memo, source = meta.source, counterparty = meta.counterparty,
    }
    local status, data = commitLegs({ leg })
    if status == 'replay' then return true, replayOf(data) end
    if status == 'fail' then return false, data end

    announceLegs({ leg })
    return true, { txId = leg.uuid, balanceAfter = leg.newBal }
  end)
end

function Money.accountCredit(accountId, currency, amount, meta)
  return accountOp(accountId, currency, amount, 1, meta)
end

function Money.accountDebit(accountId, currency, amount, meta)
  return accountOp(accountId, currency, amount, -1, meta)
end

-- ============================================================================
-- Wallet-only operations (job payouts, store purchases — work anywhere,
-- design §6.1 note). Ledgered with account_id NULL.
-- ============================================================================

local function walletOp(charid, currency, amount, sign, meta)
  meta = meta or {}
  local ok, err = checkCurrencyAndAmount(currency, amount)
  if not ok then return false, err end
  charid = tostring(charid)

  return Money.withLocks({ 'char:' .. charid }, function()
    if meta.idem then
      local row = Ledger.findByUuid(meta.idem)
      if row then return true, replayOf(row) end
    end

    local src = Bridge.GetSourceFromCharId(charid)
    if not src then return false, Err.OFFLINE end

    if sign < 0 then
      local bal = Bridge.WalletGet(src, currency)
      if not bal then return false, Err.OFFLINE end
      if bal < amount then return false, Err.INSUFFICIENT_FUNDS end
    end

    -- Ledger first (commit point), wallet second, compensate on failure.
    local uuid = meta.idem or Util.uuid()
    local direction = sign >= 0 and 'credit' or 'debit'
    local rowId = Ledger.write({
      tx_uuid = uuid, currency = currency, direction = direction, amount = amount,
      category = meta.category, source_resource = meta.source, memo = meta.memo,
    })
    if not rowId then
      local row = Ledger.findByUuid(uuid)
      if row then return true, replayOf(row) end
      return false, Err.INTERNAL
    end

    local applied = (sign >= 0)
      and Bridge.WalletAdd(src, currency, amount)
      or Bridge.WalletRemove(src, currency, amount)
    if not applied then
      Ledger.write({
        tx_uuid = Util.uuid(), currency = currency,
        direction = sign >= 0 and 'debit' or 'credit', amount = amount,
        category = Constants.Category.COMPENSATION, source_resource = 'sov_bank',
        memo = ('reversal of %s'):format(uuid),
      })
      return false, Err.WALLET_APPLY
    end

    if not meta.silent then
      Bridge.Notify(src, ('%s %s'):format(
        sign >= 0 and 'Received' or 'Paid', Util.formatAmount(amount, currency)))
    end
    Events.transactionCompleted({
      charid = charid, accountId = nil, currency = currency, amount = amount,
      direction = direction, category = meta.category, txId = uuid,
    })
    return true, { txId = uuid, walletAfter = Bridge.WalletGet(src, currency) }
  end)
end

function Money.walletCredit(charid, currency, amount, meta)
  return walletOp(charid, currency, amount, 1, meta)
end

function Money.walletDebit(charid, currency, amount, meta)
  return walletOp(charid, currency, amount, -1, meta)
end

-- ============================================================================
-- Deposit / Withdraw (wallet ↔ bank, requires the character online).
-- Commit-then-apply with compensation (tech spec §5.5).
-- ============================================================================

function Money.deposit(charid, accountId, currency, amount, meta)
  meta = meta or {}
  local ok, err = checkCurrencyAndAmount(currency, amount)
  if not ok then return false, err end
  charid = tostring(charid)
  accountId = tonumber(accountId)
  if not accountId then return false, Err.NO_ACCOUNT end

  return Money.withLocks({ 'acct:' .. accountId, 'char:' .. charid }, function()
    if meta.idem then
      local row = Ledger.findByUuid(meta.idem)
      if row then return true, replayOf(row) end
    end

    local src = Bridge.GetSourceFromCharId(charid)
    if not src then return false, Err.OFFLINE end
    local acct = Accounts.getById(accountId)
    if not acct then return false, Err.NO_ACCOUNT end
    if acct.status ~= 'active' then return false, statusErr(acct.status) end

    local wbal = Bridge.WalletGet(src, currency)
    if not wbal then return false, Err.OFFLINE end
    if wbal < amount then return false, Err.INSUFFICIENT_FUNDS end

    local leg = {
      acct = acct, currency = currency, delta = amount,
      uuid = meta.idem or Util.uuid(),
      category = meta.category or Constants.Category.DEPOSIT,
      memo = meta.memo, source = meta.source,
    }
    local status, data = commitLegs({ leg })
    if status == 'replay' then return true, replayOf(data) end
    if status == 'fail' then return false, data end

    if not Bridge.WalletRemove(src, currency, amount) then
      -- Compensate: reverse the committed bank credit. Unguarded — the
      -- reversal must always apply. Ledger keeps both entries.
      local comp = {
        acct = Accounts.getById(accountId), currency = currency, delta = -amount,
        unguarded = true, uuid = Util.uuid(),
        category = Constants.Category.COMPENSATION, source = 'sov_bank',
        memo = ('reversal of %s'):format(leg.uuid),
      }
      commitLegs({ comp })
      return false, Err.WALLET_APPLY
    end

    if not meta.silent then
      Bridge.Notify(src, ('Deposited %s'):format(Util.formatAmount(amount, currency)))
    end
    announceLegs({ leg })
    return true, {
      txId = leg.uuid, balanceAfter = leg.newBal,
      walletAfter = Bridge.WalletGet(src, currency),
    }
  end)
end

function Money.withdraw(charid, accountId, currency, amount, meta)
  meta = meta or {}
  local ok, err = checkCurrencyAndAmount(currency, amount)
  if not ok then return false, err end
  charid = tostring(charid)
  accountId = tonumber(accountId)
  if not accountId then return false, Err.NO_ACCOUNT end

  return Money.withLocks({ 'acct:' .. accountId, 'char:' .. charid }, function()
    if meta.idem then
      local row = Ledger.findByUuid(meta.idem)
      if row then return true, replayOf(row) end
    end

    local src = Bridge.GetSourceFromCharId(charid)
    if not src then return false, Err.OFFLINE end
    local acct = Accounts.getById(accountId)
    if not acct then return false, Err.NO_ACCOUNT end
    if acct.status ~= 'active' then return false, statusErr(acct.status) end

    local floorBal = debitFloor(acct, meta)
    local col = Constants.CurrencyColumn[currency]
    local bal = tonumber(acct[col]) or 0
    if bal - amount < floorBal then
      return false, floorBal < 0 and Err.NO_CREDIT or Err.INSUFFICIENT_FUNDS
    end

    local leg = {
      acct = acct, currency = currency, delta = -amount, floorBal = floorBal,
      uuid = meta.idem or Util.uuid(),
      category = meta.category or Constants.Category.WITHDRAW,
      memo = meta.memo, source = meta.source,
    }
    local status, data = commitLegs({ leg })
    if status == 'replay' then return true, replayOf(data) end
    if status == 'fail' then return false, data end

    if not Bridge.WalletAdd(src, currency, amount) then
      local comp = {
        acct = Accounts.getById(accountId), currency = currency, delta = amount,
        unguarded = true, uuid = Util.uuid(),
        category = Constants.Category.COMPENSATION, source = 'sov_bank',
        memo = ('reversal of %s'):format(leg.uuid),
      }
      commitLegs({ comp })
      return false, Err.WALLET_APPLY
    end

    if not meta.silent then
      Bridge.Notify(src, ('Withdrew %s'):format(Util.formatAmount(amount, currency)))
    end
    announceLegs({ leg })
    return true, {
      txId = leg.uuid, balanceAfter = leg.newBal,
      walletAfter = Bridge.WalletGet(src, currency),
    }
  end)
end

-- ============================================================================
-- Transfer (bank → bank, atomic, fee routes to the insurance fund —
-- design §5.2, tech spec §8.2). No wallet leg, so no compensation branch.
-- meta.crossBranch selects the cross-branch ("wire") fee.
-- ============================================================================

function Money.transfer(fromAccountId, toAccountId, currency, amount, meta)
  meta = meta or {}
  local ok, err = checkCurrencyAndAmount(currency, amount)
  if not ok then return false, err end
  fromAccountId, toAccountId = tonumber(fromAccountId), tonumber(toAccountId)
  if not fromAccountId or not toAccountId then return false, Err.NO_ACCOUNT end
  if fromAccountId == toAccountId then return false, Err.SAME_ACCOUNT end

  -- Fee (design §8). Rounded half-up; collected fees fund SYS-INSURANCE.
  local feeCfg = meta.crossBranch and Config.Fees.transferCrossBranch
    or Config.Fees.transferSameBranch
  local fee = 0
  if feeCfg then
    if feeCfg.type == 'flat' then
      fee = math.floor(tonumber(feeCfg.value) or 0)
    elseif feeCfg.type == 'percent' then
      fee = math.floor(amount * (tonumber(feeCfg.value) or 0) + 0.5)
    end
  end
  if fee < 0 then fee = 0 end

  local insAcctId = nil
  if fee > 0 then
    local ins = Accounts.getSystem(Constants.SystemAccounts.INSURANCE)
    -- No insurance account, or insurance is a party to the transfer → waive.
    if ins and ins.id ~= fromAccountId and ins.id ~= toAccountId then
      insAcctId = ins.id
    else
      fee = 0
    end
  end

  local lockKeys = { 'acct:' .. fromAccountId, 'acct:' .. toAccountId }
  if insAcctId then lockKeys[#lockKeys + 1] = 'acct:' .. insAcctId end

  return Money.withLocks(lockKeys, function()
    if meta.idem then
      local row = Ledger.findByUuid(meta.idem)
      if row then return true, replayOf(row) end
    end

    local from = Accounts.getById(fromAccountId)
    local to = Accounts.getById(toAccountId)
    if not from or not to then return false, Err.NO_ACCOUNT end
    if from.status ~= 'active' then return false, statusErr(from.status) end
    if to.status ~= 'active' then return false, statusErr(to.status) end

    local col = Constants.CurrencyColumn[currency]
    local fromBal = tonumber(from[col]) or 0
    local total = amount + fee
    local floorBal = debitFloor(from, meta)
    if fromBal - total < floorBal then
      return false, floorBal < 0 and Err.NO_CREDIT or Err.INSUFFICIENT_FUNDS
    end

    local primaryUuid = meta.idem or Util.uuid()
    local legs = {
      { -- debit source: transfer amount
        acct = from, currency = currency, delta = -amount, floorBal = floorBal,
        uuid = primaryUuid, category = meta.category or Constants.Category.TRANSFER,
        memo = meta.memo, source = meta.source, counterparty = toAccountId,
      },
      { -- credit destination
        acct = to, currency = currency, delta = amount,
        uuid = Util.uuid(), category = meta.category or Constants.Category.TRANSFER,
        memo = meta.memo, source = meta.source, counterparty = fromAccountId,
      },
    }
    if fee > 0 then
      local ins = Accounts.getById(insAcctId)
      if not ins then return false, Err.INTERNAL end
      legs[#legs + 1] = { -- debit source: fee
        acct = from, currency = currency, delta = -fee, floorBal = floorBal,
        uuid = Util.uuid(), category = Constants.Category.FEE,
        memo = ('transfer fee (%s)'):format(primaryUuid), source = meta.source,
        counterparty = insAcctId,
      }
      legs[#legs + 1] = { -- credit insurance fund
        acct = ins, currency = currency, delta = fee,
        uuid = Util.uuid(), category = Constants.Category.FEE,
        memo = ('transfer fee (%s)'):format(primaryUuid), source = meta.source,
        counterparty = fromAccountId,
      }
    end

    -- Both source legs hit the same account row: fold expected balances so
    -- newBal/balance_after stay correct when legs share an account.
    -- legStatements reads leg.acct[col] at build time, so give the second
    -- source leg a view of the balance after the first.
    if fee > 0 then
      local fromAfterAmount = {}
      for k, v in pairs(from) do fromAfterAmount[k] = v end
      fromAfterAmount[col] = fromBal - amount
      legs[3].acct = fromAfterAmount
    end

    local status, data = commitLegs(legs)
    if status == 'replay' then return true, replayOf(data) end
    if status == 'fail' then return false, data end

    announceLegs(legs)
    return true, {
      txId = primaryUuid, fee = fee,
      balanceAfter = fromBal - total,
    }
  end)
end
