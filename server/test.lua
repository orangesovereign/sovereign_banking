--[[
  server/test.lua — headless correctness suite (tech spec §14).

  Run from the SERVER console on a dev box:

    sovbanktest            -- bank-side invariants (no player needed)
    sovbanktest <serverId> -- also runs the wallet round-trip using that
                              player's wallet (small amounts, restored after)

  Drives the real engine against the live database with throwaway accounts
  (owners SOVTEST-A/B), then deletes everything it created. The insurance
  fund's test fee income is reversed with a ledgered admin_adjust, so every
  account still reconciles afterward.

  Not covered here (needs a live failure to provoke): the wallet-apply
  compensation branch. That path is exercised manually by killing VORP mid-op.
]]

local TAG = 'sov_bank_test'
local running = false

local function color(ok) return ok and '^2' or '^1' end

local function newSuite()
  return { pass = 0, fail = 0, skipped = 0 }
end

local function check(t, name, cond, detail)
  if cond then
    t.pass = t.pass + 1
    print(('^2  PASS^7  %s'):format(name))
  else
    t.fail = t.fail + 1
    print(('^1  FAIL^7  %s%s'):format(name, detail and (' — ' .. tostring(detail)) or ''))
  end
  return cond
end

local function skip(t, name, why)
  t.skipped = t.skipped + 1
  print(('^3  SKIP^7  %s — %s'):format(name, why))
end

local function balMoney(accountId)
  local a = Accounts.getById(accountId)
  return a and (tonumber(a.balance_money) or 0) or nil
end

local function feeFor(amount, crossBranch)
  local cfg = crossBranch and Config.Fees.transferCrossBranch or Config.Fees.transferSameBranch
  if not cfg then return 0 end
  if cfg.type == 'flat' then return math.floor(tonumber(cfg.value) or 0) end
  if cfg.type == 'percent' then return math.floor(amount * (tonumber(cfg.value) or 0) + 0.5) end
  return 0
end

local function runSuite(playerSrc)
  local t = newSuite()
  print('^5[sov_bank] correctness suite — tech spec §14^7')

  -- ---------------------------------------------------------------- setup
  local A = Accounts.create(Constants.OwnerType.CHARACTER, 'SOVTEST-A', 'Test A',
    Constants.AccountKind.CHECKING)
  local B = Accounts.create(Constants.OwnerType.CHARACTER, 'SOVTEST-B', 'Test B',
    Constants.AccountKind.CHECKING)
  if not (A and B) then
    print('^1  ABORT: could not create test accounts^7')
    return
  end
  local ins = Accounts.getSystem(Constants.SystemAccounts.INSURANCE)
  local gov = Accounts.getSystem(Constants.SystemAccounts.GOV)
  local feeIncome = 0 -- reversed at cleanup

  -- ------------------------------------------------- reserved numbering
  check(t, 'player accounts numbered outside the reserved range (>= 1001)',
    A.id >= 1001 and B.id >= 1001, ('got ids %s, %s'):format(A.id, B.id))
  check(t, 'government fund holds reserved number SVB-0000001',
    gov and gov.account_number == (Config.AccountPrefix or 'SVB-') .. '0000001',
    gov and gov.account_number or 'missing')
  check(t, 'insurance fund holds reserved number SVB-0000002',
    ins and ins.account_number == (Config.AccountPrefix or 'SVB-') .. '0000002',
    ins and ins.account_number or 'missing')

  -- ------------------------------------------------------- basic credits
  local ok, res = Money.accountCredit(A.id, 0, 10000, { category = 'adjust', source = TAG })
  check(t, 'accountCredit applies and reports balanceAfter',
    ok and res.balanceAfter == 10000 and balMoney(A.id) == 10000,
    ok and ('balanceAfter=%s stored=%s'):format(res.balanceAfter, balMoney(A.id)) or tostring(res))

  local row = ok and Ledger.findByUuid(res.txId) or nil
  check(t, 'ledger row written with amount, direction and balance_after',
    row and tonumber(row.amount) == 10000 and row.direction == 'credit'
      and tonumber(row.balance_after) == 10000,
    row and 'row mismatch' or 'row missing')

  ok, res = Money.accountDebit(A.id, 0, 2500, { category = 'adjust', source = TAG })
  check(t, 'accountDebit applies', ok and balMoney(A.id) == 7500, tostring(res))

  -- ---------------------------------------------------------- guardrails
  ok, res = Money.accountDebit(A.id, 0, 10 ^ 9, { source = TAG })
  check(t, 'overdraw refused with ERR_INSUFFICIENT_FUNDS and no state change',
    not ok and res == Constants.Err.INSUFFICIENT_FUNDS and balMoney(A.id) == 7500,
    tostring(res))

  local fuzzOk = true
  local fuzzDetail = nil
  for _, bad in ipairs({ -5, 0, 1.5, 2 ^ 53, 'abc' }) do
    local o, e = Money.accountCredit(A.id, 0, bad, { source = TAG })
    if o or e ~= Constants.Err.BAD_AMOUNT then
      fuzzOk = false
      fuzzDetail = ('amount %s -> %s/%s'):format(tostring(bad), tostring(o), tostring(e))
      break
    end
  end
  check(t, 'fuzzed amounts (negative, zero, float, huge, string) all ERR_BAD_AMOUNT',
    fuzzOk and balMoney(A.id) == 7500, fuzzDetail)

  ok, res = Money.accountCredit(A.id, 9, 100, { source = TAG })
  check(t, 'unknown currency refused', not ok and res == Constants.Err.BAD_CURRENCY, tostring(res))

  if Config.Currencies.rol == false then
    ok, res = Money.accountCredit(A.id, 2, 100, { source = TAG })
    check(t, 'disabled currency (rol) refused',
      not ok and res == Constants.Err.CURRENCY_DISABLED, tostring(res))
  else
    skip(t, 'disabled currency refused', 'rol is enabled in config')
  end

  -- --------------------------------------------- regressions (audited fixes)
  -- Memos are cut on a character boundary: a byte-wise cut through a
  -- multi-byte sequence produces invalid UTF-8 that MySQL rejects outright,
  -- failing the whole transaction.
  local multibyte = string.rep('é', 100) -- 200 bytes, 100 characters
  local cutMemo = Util.truncate(multibyte, 140)
  check(t, 'truncate cuts on a character boundary, not a byte boundary',
    cutMemo ~= nil and utf8.len(cutMemo) ~= nil and utf8.len(cutMemo) <= 140,
    cutMemo and ('len=%s bytes=%d'):format(tostring(utf8.len(cutMemo)), #cutMemo) or 'nil')

  ok, res = Money.accountCredit(A.id, 0, 100,
    { category = 'adjust', source = TAG, memo = multibyte })
  check(t, 'a movement with a multi-byte memo commits', ok, tostring(res))

  -- A trailing nil shortens an oxmysql parameter array, so an optional last
  -- argument must never reach the driver as nil.
  local billOk, billRes = Billing.issue(Constants.BillKind.INVOICE,
    { type = 'character', id = 'SOVTEST-A' }, 'SOVTEST-B', 0, 500, nil,
    { source = TAG })
  check(t, 'a bill issued with no memo still writes',
    billOk == true and billRes and billRes.billId ~= nil, tostring(billRes))
  if billOk and billRes and billRes.billId then
    -- SECURITY: collections must refuse a payment drawn from an account the
    -- DEBTOR does not control, or a collector could name any account id in
    -- the bank and drain it under color of a real debt.
    Db.execute("UPDATE sov_bank_bills SET status = 'in_collections' WHERE id = ?",
      { billRes.billId })
    local aBefore2 = balMoney(A.id)
    local sOk, sErr = Collections.record(billRes.billId, 'SOVTEST-COLLECTOR', 100,
      A.id, { source = TAG }) -- account A belongs to SOVTEST-A, not the debtor
    check(t, 'collections refuses an account the debtor does not control',
      sOk == false and sErr == Constants.Err.ACCESS and balMoney(A.id) == aBefore2,
      ('ok=%s err=%s'):format(tostring(sOk), tostring(sErr)))
    Db.execute('DELETE FROM sov_bank_bills WHERE id = ?', { billRes.billId })
  else
    skip(t, 'collections refuses a foreign source account', 'bill could not be issued')
  end

  -- --------------------------------------------------------- idempotency
  local K = Util.uuid()
  local ok1, r1 = Money.accountCredit(A.id, 0, 1000, { idem = K, source = TAG })
  local ok2, r2 = Money.accountCredit(A.id, 0, 1000, { idem = K, source = TAG })
  check(t, 'idempotent replay returns original result, applies once',
    ok1 and ok2 and not r1.replayed and r2.replayed == true and balMoney(A.id) == 8500,
    ('bal=%s r2=%s'):format(balMoney(A.id), json.encode(r2 or {})))

  -- ------------------------------------------- transfer + fee conservation
  local wireFee = feeFor(5000, true)
  local aBefore, bBefore = balMoney(A.id), balMoney(B.id)
  local insBefore = ins and balMoney(ins.id) or 0
  local K2 = Util.uuid()
  ok, res = Money.transfer(A.id, B.id, 0, 5000,
    { crossBranch = true, idem = K2, source = TAG, memo = 'test wire' })
  local aAfter, bAfter = balMoney(A.id), balMoney(B.id)
  local insAfter = ins and balMoney(ins.id) or 0
  feeIncome = feeIncome + (res and res.fee or 0)
  check(t, 'cross-branch transfer applies with the configured fee',
    ok and res.fee == wireFee and aAfter == aBefore - 5000 - wireFee and bAfter == bBefore + 5000,
    ok and ('fee=%s a=%s b=%s'):format(res.fee, aAfter, bAfter) or tostring(res))
  check(t, 'money is conserved across source + destination + insurance',
    (aBefore + bBefore + insBefore) == (aAfter + bAfter + insAfter),
    ('before=%s after=%s'):format(aBefore + bBefore + insBefore, aAfter + bAfter + insAfter))

  local ok3, r3 = Money.transfer(A.id, B.id, 0, 5000,
    { crossBranch = true, idem = K2, source = TAG })
  check(t, 'transfer replay with same idem key is a no-op',
    ok3 and r3.replayed == true and balMoney(A.id) == aAfter and balMoney(B.id) == bAfter,
    json.encode(r3 or {}))

  ok, res = Money.transfer(A.id, A.id, 0, 100, { source = TAG })
  check(t, 'self-transfer refused', not ok and res == Constants.Err.SAME_ACCOUNT, tostring(res))

  Db.execute("UPDATE sov_bank_accounts SET status = 'frozen' WHERE id = ?", { B.id })
  ok, res = Money.transfer(A.id, B.id, 0, 100, { source = TAG })
  check(t, 'transfer into a frozen account refused',
    not ok and res == Constants.Err.FROZEN, tostring(res))
  Db.execute("UPDATE sov_bank_accounts SET status = 'active' WHERE id = ?", { B.id })

  -- ---------------------------------------------------------- concurrency
  -- Top A up to exactly 5000, then race 10 transfers of 1000. With the
  -- same-branch fee f, exactly floor(5000 / (1000+f)) can succeed.
  local sameFee = feeFor(1000, false)
  local target = 5000
  local cur = balMoney(A.id)
  if cur < target then
    Money.accountCredit(A.id, 0, target - cur, { category = 'adjust', source = TAG })
  elseif cur > target then
    Money.accountDebit(A.id, 0, cur - target, { category = 'adjust', source = TAG })
  end
  local expectWins = math.floor(target / (1000 + sameFee))
  local wins, done = 0, 0
  for _ = 1, 10 do
    CreateThread(function()
      local o = Money.transfer(A.id, B.id, 0, 1000, { source = TAG, memo = 'race' })
      if o then wins = wins + 1 end
      if o and sameFee > 0 then feeIncome = feeIncome + sameFee end
      done = done + 1
    end)
  end
  local deadline = GetGameTimer() + 15000
  while done < 10 and GetGameTimer() < deadline do Wait(25) end
  check(t, ('10 racing transfers: exactly %d succeed, no overdraw'):format(expectWins),
    done == 10 and wins == expectWins
      and balMoney(A.id) == target - expectWins * (1000 + sameFee),
    ('done=%d wins=%d bal=%s'):format(done, wins, tostring(balMoney(A.id))))

  -- -------------------------------------------------------- reconciliation
  local recOk = true
  local recDetail = nil
  for _, acctId in ipairs({ A.id, B.id, ins and ins.id or nil }) do
    local rep = Ledger.reconcile(acctId)
    if not rep or not rep.ok then
      recOk = false
      recDetail = ('account %s drift: %s'):format(tostring(acctId), json.encode(rep and rep.drift or 'nil'))
      break
    end
  end
  check(t, 'ledger sum equals stored balance for A, B and insurance', recOk, recDetail)

  -- ---------------------------------------------------- wallet round-trip
  if playerSrc then
    local charid = Bridge.GetCharId(playerSrc)
    if not charid then
      skip(t, 'wallet round-trip', ('no character for server id %s'):format(playerSrc))
    else
      local w0 = Bridge.WalletGet(playerSrc, 0)
      local aBase = balMoney(A.id)
      local o1 = Money.walletCredit(charid, 0, 500, { silent = true, source = TAG, category = 'adjust' })
      local o2 = Money.deposit(charid, A.id, 0, 500, { silent = true, source = TAG })
      local o3 = Money.withdraw(charid, A.id, 0, 500, { silent = true, source = TAG })
      local o4 = Money.walletDebit(charid, 0, 500, { silent = true, source = TAG, category = 'adjust' })
      local wEnd = Bridge.WalletGet(playerSrc, 0)
      check(t, 'wallet round-trip (credit→deposit→withdraw→debit) conserves both sides',
        o1 and o2 and o3 and o4 and wEnd == w0 and balMoney(A.id) == aBase,
        ('wallet %s→%s, account %s→%s'):format(w0, wEnd, aBase, tostring(balMoney(A.id))))
      local rep = Ledger.reconcile(A.id)
      check(t, 'account still reconciles after wallet legs', rep and rep.ok,
        rep and json.encode(rep.drift) or 'nil')
    end
  else
    skip(t, 'wallet round-trip', 'no player id given — run: sovbanktest <serverId>')
  end

  -- --------------------------------------------------------------- cleanup
  if ins and feeIncome > 0 then
    Money.accountDebit(ins.id, 0, feeIncome,
      { category = Constants.Category.ADMIN_ADJUST or 'admin_adjust',
        memo = 'sov_bank_test cleanup: reverse test fee income', source = TAG })
  end
  Db.execute('DELETE FROM sov_bank_transactions WHERE account_id IN (?, ?)', { A.id, B.id })
  Db.execute('DELETE FROM sov_bank_transactions WHERE account_id IS NULL AND source_resource = ?', { TAG })
  Db.execute('DELETE FROM sov_bank_accounts WHERE id IN (?, ?)', { A.id, B.id }) -- access cascades

  print(('%s[sov_bank] suite done: %d passed, %d failed, %d skipped^7')
    :format(color(t.fail == 0), t.pass, t.fail, t.skipped))
end

RegisterCommand('sovbanktest', function(source, args)
  if source ~= 0 then return end -- server console only
  if running then
    print('^3[sov_bank] suite already running^7')
    return
  end
  running = true
  CreateThread(function()
    local ok, err = pcall(runSuite, tonumber(args[1]))
    if not ok then print(('^1[sov_bank] suite crashed: %s^7'):format(tostring(err))) end
    running = false
  end)
end, true)
