# Sovereign Bank (`sov_bank`)

Central financial authority for the Sovereign script suite. RedM · VORP Core ·
oxmysql. Period-authentic to 1896: banking is a place you ride to — no ATMs, no
mobile ledgers, no cheques.

**Design docs:** [`sovereign_bank_spec.md`](sovereign_bank_spec.md) (features) ·
[`sovereign_bank_techspec.md`](sovereign_bank_techspec.md) (engineering).

> **Folder name matters:** other scripts call `exports.sov_bank:...`, so install
> this resource as `sov_bank` (clone/rename the folder), not `sovereign_banking`.

## Status — Phase 1: Accounts & teller UX ✅ (in review)

| Phase | Scope | Status |
|-------|-------|--------|
| **0 — Foundation** | VORP bridge, schema, money engine, ledger, idempotency, core exports | **Built** |
| **1 — Accounts & teller UX** | branches/blips/teller peds, teller NUI, savings & named accounts, statements, shared access, proximity gating | **Built** |
| 2 — Society & commerce | society accounts, payroll, invoices, fines/taxes, collections | — |
| 3 — Credit & storage | loans, savings interest, safety deposit boxes, gold exchange | — |
| 4 — Ops & polish | admin panel, reconciliation dashboard, Discord, migration shim | — |

### Phase 1 highlights

- **Branches** ([locations.lua](config/locations.lua)): Valentine, Rhodes,
  Saint Denis, Blackwater — blips, teller peds, and a hold-**[G]** prompt at the
  counter (key configurable via `Config.Teller.promptKey`). Coordinates are
  close approximations; fine-tune to your map.
- **Teller NUI** (`web/`): accounts overview, deposit/withdraw, statements with
  category filter and paging, wire & pay (own-account moves free, wires to
  others carry the fee), open checking/savings accounts, shared-access
  management, close-at-zero.
- **Proximity gating**: every NUI request is re-checked server-side against the
  branch teller position (`Config.Teller.serverSlack` of tolerance) — the
  client's claim is never trusted. Requests are rate-limited per player.
- **Shared access** (design §5.1): hierarchical owner → admin → withdraw →
  deposit → read. Admins manage non-admin grants; only the owner appoints
  admins; anyone but the owner can remove themselves.
- **RPC layer**: client↔server calls use a self-contained request/response
  channel (`sov_bank:rpc:*`) instead of VORP's callback API, sidestepping the
  version-to-version callback naming differences (tech spec §16.5).

Phase 0 is deliberately the integration backbone: other Sovereign scripts can
already pay wages, charge purchases, and move bank balances through the exports
— no UI required.

## Install

1. Ensure `vorp_core` and `oxmysql` start **before** `sov_bank`.
2. Drop the resource in as `sov_bank` and add `ensure sov_bank` after them.
3. Schema installs itself on first boot (`sql/install.sql`, idempotent). To
   import manually instead, run the file and set `Config.AutoRunSchema = false`.
4. First boot seeds the `SYS-INSURANCE` and `SYS-GOV` system accounts.

## Money model

- **All amounts are integer minor units ("cents"):** `$12.34` → `1234`. The
  only float boundary is the VORP wallet, handled inside `bridge/vorp.lua`.
- **Wallet** (cash in hand) is owned by VORP; **bank balances** are owned by
  this resource. Wallet payouts work anywhere; bank operations will be
  branch-gated when the teller UI lands (Phase 1).
- Every movement writes an immutable row to `sov_bank_transactions`.
  `exports.sov_bank:Reconcile(accountId)` proves balance == ledger sum.

## Exports (Phase 0)

Every mutating export returns `(ok: boolean, resultOrErrorCode)` and never
throws. Error codes are strings like `ERR_INSUFFICIENT_FUNDS` (see
`shared/constants.lua`).

```lua
-- Pay a wage in cash (works anywhere — no branch needed):
local ok, res = exports.sov_bank:AddMoney(charid, 0, 2500, {
  reason = 'payroll',
  memo   = 'Herding wages',
  idem   = jobRunUuid,   -- optional: retries with the same key are no-ops
})

-- Charge for goods from the wallet; fails cleanly if they can't pay:
local ok, err = exports.sov_bank:RemoveMoney(charid, 0, 1250, { reason = 'purchase' })
if not ok then print('payment failed:', err) end

-- Credit straight into their bank account instead:
exports.sov_bank:AddMoney(charid, 0, 50000, { target = 'bank', reason = 'loan_disburse' })

-- Checks & reads:
exports.sov_bank:CanAfford(charid, 0, 1250)                -- wallet, boolean
exports.sov_bank:CanAfford(charid, 0, 1250, { target = 'bank' })
exports.sov_bank:GetWalletBalance(charid, 0)               -- nil if offline
exports.sov_bank:GetBankBalance(accountId, 0)
exports.sov_bank:GetPrimaryAccount(charid)                 -- full account row

-- Atomic account→account transfer (fee routes to the insurance fund):
exports.sov_bank:Transfer(fromAcctId, toAcctId, 0, 10000, {
  memo = 'Cattle sale', crossBranch = true,
})

-- Teller-flow primitives (Phase 1 UI will call these via gated callbacks):
exports.sov_bank:Deposit(charid, accountId, 0, 5000)
exports.sov_bank:Withdraw(charid, accountId, 0, 5000)

-- Statements & audit:
exports.sov_bank:GetTransactions(accountId, { limit = 25, category = 'transfer' })
exports.sov_bank:Reconcile(accountId)
```

**The `opts` table** (shared by mutating calls): `reason` (ledger category),
`memo` (statement line), `source` (auto-filled with the calling resource),
`target` (`'wallet'` | `'bank'` | accountId), `idem` (idempotency key),
`silent` (suppress notification), `allowNeg` (overdraft — only honored when
`Config.Credit.enabled`).

### Events

Fire-and-forget inbound (server→server only; clients can never trigger these):
`sov_bank:server:addMoney`, `:removeMoney`, `:transfer`.

Outbound announcements: `sov_bank:server:transactionCompleted`,
`sov_bank:server:balanceChanged` (more arrive with later phases).

### Console diagnostics

```
sovbank account <charid>        -- primary account row
sovbank reconcile <accountId>   -- ledger vs balance drift report
sovbank tx <accountId> [limit]  -- recent ledger rows
```

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
