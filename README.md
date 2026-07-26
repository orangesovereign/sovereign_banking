# Sovereign Bank (`sovereign_banking`)

Central financial authority for the Sovereign script suite. RedM · VORP Core ·
oxmysql. Period-authentic to 1896: banking is a place you ride to — no ATMs, no
mobile ledgers, no cheques.

**Design docs:** [`sovereign_banking_spec.md`](sovereign_banking_spec.md) (features) ·
[`sovereign_banking_techspec.md`](sovereign_banking_techspec.md) (engineering).
**Bringing it into service:** [`TESTING.md`](TESTING.md) — three interactive
testing ledgers (B1 Foundation · B2 Commerce & Credit · B3 Enforcement & Ops).

> **Folder name matters:** exports resolve by resource name, so this must be
> installed as `sovereign_banking` — matching the rest of the county
> (`sovereign_medical`, `sovereign_stores`, `sovereign_stables`). Events are
> `sovereign_banking:*` and tables are `sovereign_banking_*` for the same reason.

## Status

| Phase | Scope | Status |
|-------|-------|--------|
| **0 — Foundation** | VORP bridge, schema, money engine, ledger, idempotency, core exports | **Built** |
| **1 — Accounts & teller UX** | branches, teller NUI, savings & named accounts, statements, shared access, proximity gating | **Built** |
| **2 — Society & commerce** | society accounts, atomic payroll, invoices/fines/taxes, delinquency pipeline | **Built** |
| **3 — Credit & storage** | fixed-cost loans, savings interest, safety deposit boxes, gold exchange | **Built** |
| **4 — Ops & polish** | admin panel, reconciliation, money-supply dashboard, Discord audit, migration shim, heist reserve | **Built** |

The two remaining spec areas are now built as well: **collections & the Tax
Collector** (§5.14 — queue, escort, lawful seizure, liens) and **business
accounts + the Tax Ledger** (§5.15). Both lie dormant until their prerequisites
exist: collections needs a `taxcollector` job in `Config.Societies`, and the Tax
Ledger fills in when `sovereign_stores` calls `RegisterBusiness` on a purchase.

## Install

1. Ensure `vorp_core`, `oxmysql`, and `vorp_inventory` start **before** `sovereign_banking`.
2. Drop the resource in as `sovereign_banking` and add `ensure sovereign_banking` after them.
3. Schema installs itself on first boot (`sql/install.sql`, idempotent). To
   import manually instead, run the file and set `Config.AutoRunSchema = false`.
4. First boot seeds system accounts, society accounts, and branch cash reserves.
5. Grant yourself the admin panel in `server.cfg`:
   `add_ace group.admin banking.admin allow`

### Configure before going live

- **`Config.Societies`** — the VORP job names for each society must match your
  server's jobs. Ships with `lawman`, `medical`, `tax_office`; societies whose
  jobs nobody holds simply lie dormant.
- **`Config.Locations.banks`** — teller coordinates are close approximations.
  Fine-tune them to your map.
- **`Config.Gold.pricePerGold`, `Config.Loans`, `Config.Interest`,
  `Config.BusinessTax`** — economy tuning.

## Money model

- **All amounts are integer minor units ("cents"):** `$12.34` → `1234`. The only
  float boundary is the VORP wallet, handled inside `bridge/vorp.lua`.
- **Wallet** (cash in hand) is owned by VORP; **bank balances** are owned by this
  resource. Wallet payouts work anywhere — a rancher gets paid in the field —
  but account operations require standing at a teller, verified server-side.
- Every movement writes an immutable row to `sovereign_banking_transactions`.
  `Reconcile(accountId)` proves balance == ledger sum; the scheduler audits a
  rolling slice of accounts continuously.
- **Account numbers 1–1000 are reserved for government accounts**
  (`SVB-0000001` gov, `SVB-0000002` insurance, societies from №10). Player
  accounts start at `SVB-0001001`.

## Integration — the Sovereign contract

Every mutating export returns `(ok: boolean, resultOrErrorCode)` and never
throws. Error codes are strings like `ERR_INSUFFICIENT_FUNDS` (see
[`shared/constants.lua`](shared/constants.lua)).

### Core money

```lua
-- Pay a wage in cash (works anywhere — no branch needed):
local ok, res = exports.sovereign_banking:AddMoney(charid, 0, 2500, {
  reason = 'payroll',
  memo   = 'Herding wages',
  idem   = jobRunUuid,   -- optional: retries with the same key are no-ops
})

-- Charge for goods from the wallet; fails cleanly if they can't pay:
local ok, err = exports.sovereign_banking:RemoveMoney(charid, 0, 1250, { reason = 'purchase' })
if not ok then print('payment failed:', err) end

-- Credit straight into their bank account instead:
exports.sovereign_banking:AddMoney(charid, 0, 50000, { target = 'bank', reason = 'loan_disburse' })

exports.sovereign_banking:CanAfford(charid, 0, 1250)          -- boolean, no mutation
exports.sovereign_banking:GetWalletBalance(charid, 0)         -- nil if offline
exports.sovereign_banking:GetBankBalance(accountId, 0)
exports.sovereign_banking:GetPrimaryAccount(charid)
exports.sovereign_banking:Transfer(fromAcctId, toAcctId, 0, 10000, { memo = 'Cattle sale' })
exports.sovereign_banking:GetTransactions(accountId, { limit = 25, category = 'transfer' })
```

**The `opts` table** (shared by mutating calls): `reason` (ledger category),
`memo` (statement line), `source` (auto-filled with the calling resource),
`target` (`'wallet'` | `'bank'` | accountId), `idem` (idempotency key), `silent`
(suppress notification), `allowNeg` (overdraft — only when `Config.Credit.enabled`).

### Societies & payroll — for the lawman, medical, and job scripts

```lua
exports.sovereign_banking:GetSocietyBalance('lawman', 0)
exports.sovereign_banking:AddToSociety('medical', 0, 5000, { reason = 'fee', memo = 'Doctoring' })
exports.sovereign_banking:RemoveFromSociety('lawman', 0, 2500, { reason = 'purchase' })

-- Atomic batch: society debited once, every hand's BANK ACCOUNT credited.
-- Works for offline characters — the wage waits at the counter.
local ok, res = exports.sovereign_banking:RunPayroll('lawman', {
  { charid = '42', amount = 25000, memo = 'Weekly wage' },
  { charid = '77', amount = 15000 },
}, { idem = payrollRunUuid })
-- res = { paid = {...}, total = 40000, txId = '...' }
```

### Bills — invoices, fines, taxes

Invoices are **civil** forever. Fines and taxes are **government debt** and are
the only debts that can reach a warrant (design §5.14 hard rule).

```lua
-- Civil invoice from a player or a society; proceeds go to the issuer.
exports.sovereign_banking:IssueInvoice(issuerCharid, targetCharid, 0, 12500, 'Cattle feed')
exports.sovereign_banking:IssueInvoice({ type = 'society', id = 'medical' }, targetCharid,
  0, 8000, 'Surgery')

-- Government debt; proceeds go to SYS-GOV.
exports.sovereign_banking:IssueFine(targetCharid, 0, 5000, 'Disturbing the peace',
  { idem = citationUuid })
exports.sovereign_banking:LevyTax(targetCharid, 0, 20000, 'Property tax, Q2')

exports.sovereign_banking:GetDebtStatus(charid)   -- { tier = 0..3, totalOwed, bills = {...} }
exports.sovereign_banking:PayBill(billId, charid, 'wallet')   -- e.g. auto-debit at booking
exports.sovereign_banking:CancelBill(billId)
```

### Lawman handoff

The bank runs tiers 0–2 alone. Lawmen hear about a debt at exactly one moment —
when government debt crosses the arrestable threshold:

```lua
AddEventHandler('sovereign_banking:server:warrantFiled', function(d)
  -- d = { charid, billId, kind, amount, reason }   kind is only 'fine' or 'tax'
  Warrants.file(d.charid, d.amount, d.reason)
end)

AddEventHandler('sovereign_banking:server:billPaid', function(d)
  if d.wasWarrant then Warrants.clear(d.payerCharid, d.billId) end
end)
```

Other outbound events: `transactionCompleted`, `balanceChanged`, `debtOverdue`,
`debtInCollections`, `loanDefaulted`, `accountFrozen`.

### Heists — for the robbery script

A robbery **can never touch a player or society balance**. The only pool
reachable is the branch's physical cash reserve; that guarantee is structural,
not a config toggle.

```lua
local onHand = exports.sovereign_banking:GetBranchReserve('valentine', 0)

local ok, res = exports.sovereign_banking:ClaimBranchReserve('valentine', 0, {
  fraction = math.random(40, 80) / 100,  -- your RNG; clamped to Config.Heist.payoutRange
  looters  = { '42', '77' },             -- split into their wallets
  idem     = heistUuid,
})
-- res = { looted = 143000, remaining = 107000, paid = {...} }
```

### Businesses & the Tax Ledger — for `sovereign_stores`

There is **no sales tax** anywhere in this suite. Business tax is a flat licence
fee per period, sized as a percentage of the building's purchase price, owed
whether or not the shop sells a thing.

```lua
-- On property purchase (the payment should route through the bank anyway):
exports.sovereign_banking:RegisterBusiness('valentine_gunsmith', ownerCharid, 200000, {
  name = 'Valentine Gunsmith',
})
-- Opens a business account, grants the owner access, and sets the tax basis.

exports.sovereign_banking:GetBusinessAccount('valentine_gunsmith')  -- account row
exports.sovereign_banking:GetTaxLedger('valentine_gunsmith')        -- assessed/remitted/owed/due
exports.sovereign_banking:IsBusinessOwner(charid, 'valentine_gunsmith')
```

The scheduler assesses each period automatically and, once a balance goes
unremitted past its window, opens a `tax` bill against the owner that enters the
collections pipeline. Owners settle at the teller under **Business & Tax**.

### Collections & seizure — for the Tax Collector and restraint scripts

```lua
exports.sovereign_banking:GetCollectionsQueue({ kind = 'tax', limit = 50 })
exports.sovereign_banking:RecordCollection(billId, 5000, {
  collectorCharid = collector, payWith = 'wallet',
})
exports.sovereign_banking:PlaceLien(debtorCharid, accountId, 10000, { billId = billId })
exports.sovereign_banking:StartEscort(collectorCharid, debtorCharid, billId)

-- GOVERNMENT DEBT ONLY — returns ERR_CIVIL_DEBT for a private invoice, always.
exports.sovereign_banking:EscalateToLawman(billId, { collectorCharid = collector })

-- The restraint resource calls this BEFORE allowing rope/hogtie, so force is
-- gated on a server-verified debt rather than a player's claim:
if exports.sovereign_banking:IsSeizureAuthorized(collectorCharid, debtorCharid) then
  -- ...allow the restraint...
end

exports.sovereign_banking:ValuateItems({ { name = 'gold_nugget', count = 2 } })
exports.sovereign_banking:SeizeAssets(collectorCharid, debtorCharid, billId, {
  { name = 'gold_nugget', count = 2 },
})
-- Verifies the open tier-2 debt, caps to what is owed, skips exempt items,
-- removes goods BEFORE paying so a failed removal can't be paid for, applies
-- proceeds, returns surplus to the debtor's account, writes an audit row.
```

### Loans & gold

```lua
exports.sovereign_banking:CreateLoan(charid, 50000, nil, { accountId = acctId })
exports.sovereign_banking:ApproveLoan(loanId, 'sheriff_desk')
exports.sovereign_banking:DenyLoan(loanId, 'sheriff_desk')
exports.sovereign_banking:GetLoans(charid)
exports.sovereign_banking:GetGoldQuote()   -- { buy = 2100, sell = 1900 } per 1.00 gold
```

### Migration shim (optional)

Set `Config.Compat.enabled = true` to expose legacy signatures so third-party
scripts route through the ledger unmodified. These take a **player source** and
**display units** (dollars), unlike the native exports above:

```lua
exports.sovereign_banking:addMoney(source, 0, 12.50)
exports.sovereign_banking:removeMoney(source, 0, 12.50)
exports.sovereign_banking:getMoney(source, 0)
```

## Admin & operations

`/bankadmin` opens the ledger office to anyone with the `banking.admin` ACE:
money-supply telemetry (banked totals, public funds, faucet/sink flows by
category), account search with freeze/thaw and force adjustment, pending loan
approvals, branch till levels, and one-click reconciliation. Force adjustments
are ledgered as `admin_adjust` naming the actor — never silent writes.

Server console equivalents:

```
banking account <charid> | reconcile <accountId> | tx <accountId> [limit]
banking loans [approve|deny <loanId>]
banking_admin supply [days] | reconcile [limit] | search <term>
banking_admin freeze|unfreeze <accountId>
banking_admin adjust <accountId> <deltaMinor> [currency] [reason]
banking_admin reserves
banking_test [serverId]     -- correctness suite (dev servers only)
```

Discord audit mirroring is off by default; set `Config.Discord.enabled` and the
per-category webhooks to mirror large movements, loans, admin actions, and heists.

## Engineering notes

- `bridge/vorp.lua` is the **only** file that touches VORP symbols (design §9).
  Wallet mutations are read-back-verified because VORP's `addCurrency` /
  `removeCurrency` don't return success signals.
- oxmysql's transaction API can't branch on `affectedRows` mid-transaction, so
  the engine layers: per-account mutex (serializes all writes) → funds guard in
  the debit `UPDATE`'s WHERE clause → single-transaction commit of all balance
  updates + ledger rows → post-commit verification with loud rollback. See the
  header comment in `server/engine/money.lua`.
- Deposit/withdraw use commit-then-apply with compensation: the DB commits
  first, the VORP wallet applies second, and a wallet failure writes an
  offsetting ledger entry so the ledger always balances.
- Savings interest is race-safe without holding the account mutex: the
  idempotency key derives from the accrual base timestamp, and the clock
  advances by compare-and-set, so the lazy (teller) and sweep (scheduler) paths
  can never double-post the same period.
- Client↔server calls use a self-contained request/response channel
  (`sovereign_banking:rpc:*`) instead of VORP's callback API, sidestepping version-to-
  version callback naming differences (tech spec §16.5).
