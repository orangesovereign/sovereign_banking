# Sovereign Bank — Technical Specification

**Companion to:** `sovereign_bank_spec.md` (design & feature spec, v2.6)
**Resource name:** `sov_bank`
**Platform:** RedM (CitizenFX / Cfx.re) · **Framework:** VORP Core
**Language:** Lua (server + client) · **UI:** NUI (HTML/CSS/JS)
**DB:** MySQL via `oxmysql`
**Status:** Specification — not implemented. This is the build blueprint.

> This document translates the design spec into an engineering plan: file layout,
> manifest, database DDL, module contracts, the money-engine algorithm, the full
> export/event/callback surface with return conventions, step-by-step data flows,
> the real-time scheduler, the security model, and a test plan. Section references
> like "(design §5.14)" point back to the feature spec.

---

## 1. Scope & Dependencies

### 1.1 Runtime dependencies
| Dependency | Purpose | Hard/soft |
|-----------|---------|-----------|
| `vorp_core` | Characters, wallet currency, callbacks, notifications | **Hard** |
| `oxmysql` | Database access | **Hard** |
| `vorp_inventory` | Safety deposit boxes (stashes), item valuation/seizure | **Hard** (v1) |
| Restraint resource (server's choice) | Rope/hogtie for collection encounters | **Soft** (gated via export) |
| `sovereign_stores` | Business registration, storefronts | **Soft** (integration) |
| Lawman resource | Warrant pickup | **Soft** (integration) |
| Discord webhook | Audit mirroring | **Optional** |

### 1.2 Assumptions
- VORP Core money API is authoritative for the wallet: `Core.getUser(src)`,
  `user.getUsedCharacter`, `character.addCurrency(type, amount)`,
  `character.removeCurrency(type, amount)`, getters `character.money/gold/rol`,
  and `character.charIdentifier`. Currency type IDs: `0` money, `1` gold, `2` rol.
- All monetary values are **integer minor units** ("cents"): dollars×100,
  gold×100. No floats cross a function boundary or hit the DB.
- Server time (`os.time()`, epoch seconds) is the clock for all "real-life day"
  timers (interest, tax, reserve replenish). No in-game-day dependency.

---

## 2. Resource Layout

```
sov_bank/
├── fxmanifest.lua
├── config/
│   ├── config.lua            # tunables (design §8)
│   └── locations.lua         # branches, tellers, blips
├── shared/
│   ├── constants.lua         # enums, currency ids, categories, error codes
│   └── util.lua              # money math, uuid, rounding, validation helpers
├── bridge/
│   └── vorp.lua              # ONLY file that calls VORP directly (design §9)
├── server/
│   ├── main.lua              # bootstrap, resource lifecycle
│   ├── db.lua                # oxmysql wrappers, prepared queries
│   ├── engine/
│   │   ├── money.lua         # atomic mutation core, idempotency, locks
│   │   └── ledger.lua        # transaction writes, reconciliation
│   ├── modules/
│   │   ├── accounts.lua      # create/close/access/freeze
│   │   ├── transfers.lua     # transfer, direct pay, fees→insurance
│   │   ├── loans.lua         # fixed-cost loans (design §5.3)
│   │   ├── savings.lua       # interest accrual (design §5.4)
│   │   ├── sdb.lua           # safety deposit boxes (design §5.5)
│   │   ├── gold.lua          # gold exchange/vault (design §5.6)
│   │   ├── billing.lua       # invoices/fines/taxes (design §5.7)
│   │   ├── collections.lua   # delinquency pipeline, Tax Collector (design §5.14)
│   │   ├── seizure.lua       # lawful seizure → repayment (design §5.14)
│   │   ├── business.lua      # business accounts + Tax Ledger (design §5.15)
│   │   ├── society.lua       # society funds, payroll (design §5.8)
│   │   └── heist.lua         # branch cash reserve (design §5.11)
│   ├── api/
│   │   ├── exports.lua       # export surface (design §6.1)
│   │   ├── events.lua        # inbound/outbound net events (design §6.2)
│   │   └── callbacks.lua     # VORP callbacks, proximity-gated (design §6.3)
│   ├── admin.lua             # /bankadmin, reconciliation, dashboards
│   ├── scheduler.lua         # timed jobs (interest, tax, replenish)
│   └── logging.lua           # audit + Discord
├── client/
│   ├── main.lua              # blips, teller peds, interaction points
│   ├── teller.lua            # open/close teller, proximity state
│   └── nui.lua               # NUI message bridge
├── web/                      # NUI (single-page)
│   ├── index.html
│   ├── app.js
│   └── style.css
└── sql/
    └── install.sql           # full schema (§4)
```

---

## 3. fxmanifest.lua

```lua
fx_version 'cerulean'
games { 'rdr3' }
rdr3_warning 'I acknowledge that this is a prerelease build of RedM, and I am aware my resources *will* become incompatible once RedM ships.'

author 'Sovereign'
description 'Sovereign Bank — central financial authority for the Sovereign suite'
version '0.1.0'

shared_scripts {
  '@vorp_core/shared/main.lua',   -- if version exposes shared
  'config/config.lua',
  'config/locations.lua',
  'shared/constants.lua',
  'shared/util.lua',
}

server_scripts {
  '@oxmysql/lib/MySQL.lua',
  'bridge/vorp.lua',
  'server/db.lua',
  'server/logging.lua',
  'server/engine/ledger.lua',
  'server/engine/money.lua',
  'server/modules/accounts.lua',
  'server/modules/transfers.lua',
  'server/modules/loans.lua',
  'server/modules/savings.lua',
  'server/modules/sdb.lua',
  'server/modules/gold.lua',
  'server/modules/billing.lua',
  'server/modules/collections.lua',
  'server/modules/seizure.lua',
  'server/modules/business.lua',
  'server/modules/society.lua',
  'server/modules/heist.lua',
  'server/api/callbacks.lua',
  'server/api/events.lua',
  'server/api/exports.lua',
  'server/admin.lua',
  'server/scheduler.lua',
  'server/main.lua',
}

client_scripts {
  'bridge/vorp.lua',
  'client/main.lua',
  'client/teller.lua',
  'client/nui.lua',
}

ui_page 'web/index.html'
files { 'web/index.html', 'web/app.js', 'web/style.css' }

dependencies { 'vorp_core', 'oxmysql', 'vorp_inventory' }
```

Load order matters: `bridge` → `db`/`logging` → `ledger` → `money` → modules →
`api` → `admin`/`scheduler` → `main`. Modules depend on the engine; the API layer
depends on modules; nothing depends on the API layer internally.

---

## 4. Database Schema (`sql/install.sql`)

All amounts `BIGINT` minor units. All timers `DATETIME`/epoch. InnoDB, utf8mb4.

```sql
CREATE TABLE IF NOT EXISTS sov_bank_accounts (
  id                INT UNSIGNED NOT NULL AUTO_INCREMENT,
  account_number    VARCHAR(24)  NOT NULL,
  owner_type        ENUM('character','society','business','joint','system') NOT NULL,
  owner_id          VARCHAR(64)  NOT NULL,
  name              VARCHAR(64)  NOT NULL DEFAULT 'Checking',
  kind              ENUM('checking','savings','society','business') NOT NULL DEFAULT 'checking',
  balance_money     BIGINT NOT NULL DEFAULT 0,
  balance_gold      BIGINT NOT NULL DEFAULT 0,
  balance_rol       BIGINT NOT NULL DEFAULT 0,
  status            ENUM('active','frozen','closed') NOT NULL DEFAULT 'active',
  credit_limit      BIGINT NOT NULL DEFAULT 0,
  created_at        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_account_number (account_number),
  KEY idx_owner (owner_type, owner_id),
  KEY idx_status (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS sov_bank_access (
  id             INT UNSIGNED NOT NULL AUTO_INCREMENT,
  account_id     INT UNSIGNED NOT NULL,
  charidentifier VARCHAR(64) NOT NULL,
  access_level   ENUM('owner','admin','withdraw','deposit','read') NOT NULL,
  granted_by     VARCHAR(64) NULL,
  created_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_acct_char (account_id, charidentifier),
  KEY idx_char (charidentifier),
  CONSTRAINT fk_access_acct FOREIGN KEY (account_id)
    REFERENCES sov_bank_accounts(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS sov_bank_transactions (
  id                       BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tx_uuid                  CHAR(36) NOT NULL,
  account_id               INT UNSIGNED NULL,
  counterparty_account_id  INT UNSIGNED NULL,
  currency                 TINYINT NOT NULL,           -- 0/1/2
  direction                ENUM('credit','debit') NOT NULL,
  amount                   BIGINT NOT NULL,            -- positive
  balance_after            BIGINT NULL,
  category                 VARCHAR(40) NOT NULL,
  source_resource          VARCHAR(48) NULL,
  memo                     VARCHAR(140) NULL,
  created_at               TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_tx_uuid (tx_uuid),                     -- idempotency
  KEY idx_account_time (account_id, created_at),
  KEY idx_category (category)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS sov_bank_loans (
  id                INT UNSIGNED NOT NULL AUTO_INCREMENT,
  charidentifier    VARCHAR(64) NOT NULL,
  account_id        INT UNSIGNED NOT NULL,
  principal         BIGINT NOT NULL,
  total_due         BIGINT NOT NULL,
  balance_remaining BIGINT NOT NULL,
  interest_flat     DECIMAL(5,4) NOT NULL,
  due_by            DATETIME NULL,
  status            ENUM('pending','active','paid','defaulted','denied') NOT NULL DEFAULT 'pending',
  approved_by       VARCHAR(64) NULL,
  created_at        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_char (charidentifier),
  KEY idx_status (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS sov_bank_savings_accrual (
  account_id       INT UNSIGNED NOT NULL,
  last_accrued_at  DATETIME NOT NULL,
  PRIMARY KEY (account_id),
  CONSTRAINT fk_accrual_acct FOREIGN KEY (account_id)
    REFERENCES sov_bank_accounts(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS sov_bank_sdb (
  id             INT UNSIGNED NOT NULL AUTO_INCREMENT,
  account_id     INT UNSIGNED NULL,
  owner_id       VARCHAR(64) NOT NULL,
  size           ENUM('small','medium','large') NOT NULL,
  stash_id       VARCHAR(64) NOT NULL,
  rent_paid_until DATETIME NULL,
  created_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_stash (stash_id),
  KEY idx_owner (owner_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS sov_bank_bills (
  id                INT UNSIGNED NOT NULL AUTO_INCREMENT,
  bill_uuid         CHAR(36) NOT NULL,
  issuer_type       ENUM('character','society','system') NOT NULL,
  issuer_id         VARCHAR(64) NOT NULL,
  target_charid     VARCHAR(64) NOT NULL,
  kind              ENUM('invoice','fine','tax') NOT NULL,
  currency          TINYINT NOT NULL,
  amount            BIGINT NOT NULL,
  balance_remaining BIGINT NOT NULL,
  status            ENUM('pending','overdue','in_collections','warrant','paid','cancelled','expired') NOT NULL DEFAULT 'pending',
  due_at            DATETIME NULL,
  assigned_collector VARCHAR(64) NULL,
  memo              VARCHAR(140) NULL,
  created_at        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  paid_at           TIMESTAMP NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_bill_uuid (bill_uuid),
  KEY idx_target (target_charid),
  KEY idx_status (status),
  KEY idx_kind (kind)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS sov_bank_business_tax (
  business_id     VARCHAR(64) NOT NULL,
  building_price  BIGINT NOT NULL,             -- tax basis (design §5.15)
  license_rate    DECIMAL(5,4) NOT NULL DEFAULT 0.2500,
  assessed        BIGINT NOT NULL DEFAULT 0,
  remitted        BIGINT NOT NULL DEFAULT 0,
  balance_owed    BIGINT NOT NULL DEFAULT 0,   -- assessed - remitted
  last_assessed_at DATETIME NULL,
  last_remit_at   DATETIME NULL,
  next_due_at     DATETIME NULL,
  PRIMARY KEY (business_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS sov_bank_seizures (
  id               INT UNSIGNED NOT NULL AUTO_INCREMENT,
  bill_id          INT UNSIGNED NOT NULL,
  collector_charid VARCHAR(64) NOT NULL,
  debtor_charid    VARCHAR(64) NOT NULL,
  items_json       JSON NOT NULL,
  assessed_value   BIGINT NOT NULL,
  applied_amount   BIGINT NOT NULL,
  surplus_returned BIGINT NOT NULL DEFAULT 0,
  created_at       TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_bill (bill_id),
  KEY idx_debtor (debtor_charid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS sov_bank_liens (
  id             INT UNSIGNED NOT NULL AUTO_INCREMENT,
  bill_id        INT UNSIGNED NULL,           -- debt the lien secures (if any)
  account_id     INT UNSIGNED NULL,           -- lien against an account
  debtor_charid  VARCHAR(64) NOT NULL,
  amount         BIGINT NOT NULL,             -- secured amount
  status         ENUM('active','released','satisfied') NOT NULL DEFAULT 'active',
  placed_by      VARCHAR(64) NOT NULL,        -- Tax Collector charid
  created_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  released_at    TIMESTAMP NULL,
  PRIMARY KEY (id),
  KEY idx_debtor (debtor_charid),
  KEY idx_status (status),
  KEY idx_bill (bill_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS sov_bank_reserves (
  branch_id        VARCHAR(48) NOT NULL,
  currency         TINYINT NOT NULL DEFAULT 0,
  balance          BIGINT NOT NULL DEFAULT 0,   -- physical cash on hand
  cap              BIGINT NOT NULL,
  last_refilled_at DATETIME NULL,
  PRIMARY KEY (branch_id, currency)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

**System accounts** (design §5.11): seed rows in `sov_bank_accounts` with
`owner_type='system'` and reserved `owner_id`s — `SYS-INSURANCE` (fee sink /
insurance fund) and `SYS-GOV` (government fund for taxes/fines). Created idempotently
on first boot in `server/main.lua`.

---

## 5. Money Engine (`server/engine/money.lua`)

The single choke point for every balance change. No module writes a balance
directly; they all call the engine.

### 5.1 Value & currency helpers (`shared/util.lua`)
- `Money.toMinor(display)` / `Money.toDisplay(minor)` — boundary conversion only.
- `Money.assertValid(amount)` — integer, ≥ 0, within `MAX_SAFE` bound; else error.
- `Money.column(currency)` → `'balance_money' | 'balance_gold' | 'balance_rol'`.

### 5.2 Return convention
Every mutating engine/module/export function returns `(ok, result)`:
- `ok == true` → `result` is a table (e.g. `{txId=..., balanceAfter=...}`).
- `ok == false` → `result` is a string **error code** from `Constants.Err`
  (e.g. `ERR_INSUFFICIENT_FUNDS`, `ERR_FROZEN`, `ERR_NOT_AT_BRANCH`,
  `ERR_BAD_AMOUNT`, `ERR_NO_ACCOUNT`, `ERR_NO_CREDIT`). Functions **never throw**
  to callers; internal errors are caught, logged, and returned as `ERR_INTERNAL`.

### 5.3 Idempotency
- Every mutation carries a `tx_uuid` (`opts.idem` or a generated v4 UUID).
- Before applying, the engine checks `sov_bank_transactions.tx_uuid`; if present,
  it returns the original stored result (`{txId, balanceAfter, replayed=true}`)
  without re-applying. The `UNIQUE` constraint is the backstop against races.

### 5.4 Per-account locking
- In-process lock table keyed by `accountId` (and by `charid` for wallet-only ops).
- `Money.withLock(key, fn)` serializes mutations on the same key using a small
  queue of coroutine resumes. Prevents interleaved read-modify-write double-spends
  within this resource. (Cross-resource safety is provided by the SQL transaction +
  unique idempotency key.)

### 5.5 Atomic mutation pattern (the core algorithm)
Bank-balance and wallet mutations must both succeed or neither persists. Because
VORP holds the wallet and MySQL holds the bank balance, the engine uses a
**commit-then-apply with compensation** sequence:

```
function Money.move(spec)      -- spec: {charid, accountId, currency, delta, category, opts}
  return Money.withLock(spec.lockKey, function()
    if idempotent hit then return stored end

    MySQL.transaction(function(txn)
      -- 1. re-read authoritative balance INSIDE the txn (row lock: SELECT ... FOR UPDATE)
      -- 2. validate: frozen? sufficient funds (or within credit_limit if allowNeg)?
      -- 3. UPDATE sov_bank_accounts SET balance_x = balance_x + delta
      -- 4. INSERT sov_bank_transactions (tx_uuid, ..., balance_after)
    end)                        -- COMMIT here; DB is now source of truth

    -- 5. If the op also touches the wallet (deposit/withdraw), apply via bridge:
    local walletOk = Bridge.WalletAdd/Remove(charid, currency, amount)
    if not walletOk then
      -- COMPENSATE: reverse the committed DB leg with an offsetting txn,
      -- return ERR_WALLET_APPLY. Ledger stays balanced (both entries present).
    end

    return ok, {txId, balanceAfter}
  end)
end
```

Transfers are a single `MySQL.transaction` touching two account rows plus two
ledger entries (debit + credit) — no wallet leg, so no compensation needed.
Wallet↔bank ops (deposit/withdraw) are the only ones with the compensation branch.

### 5.6 Reconciliation
`Ledger.reconcile(accountId)` sums signed ledger amounts per currency and compares
to the stored balance; drift is logged at `error` and surfaced in the admin
dashboard. Run on demand and on a low-frequency scheduler tick.

---

## 6. Framework Bridge (`bridge/vorp.lua`)

The **only** module referencing VORP symbols. Neutral interface (design §9):

| Bridge fn | VORP mapping |
|-----------|--------------|
| `Bridge.GetCharId(src)` | `Core.getUser(src).getUsedCharacter.charIdentifier` |
| `Bridge.GetSourceFromCharId(id)` | `Core.getUserByCharId(id)` → its source |
| `Bridge.GetCharacter(src)` | `Core.getUser(src).getUsedCharacter` |
| `Bridge.WalletGet(src, cur)` | `char.money` / `char.gold` / `char.rol` |
| `Bridge.WalletAdd(src, cur, amt)` | `char.addCurrency(cur, amt)` |
| `Bridge.WalletRemove(src, cur, amt)` | `char.removeCurrency(cur, amt)` |
| `Bridge.Notify(src, msg, type)` | VORP notification export |
| `Bridge.RegisterCallback(name, fn)` | `Core.Callback.Register(name, fn)` |
| `Bridge.GetJob(src)` / `Bridge.HasJob(src, job)` | character job fields (Tax Collector/whitelist checks) |

Wallet functions take `src` where possible (VORP is source-keyed); the engine
resolves `charid → src` via `Bridge.GetSourceFromCharId` for offline-safe paths and
no-ops the wallet leg when the character is offline (bank-only operations don't need
the wallet).

---

## 7. Server API Surface

### 7.1 Exports (`server/api/exports.lua`) — design §6.1
All mutating exports share the `opts` table (design §6.1) and the `(ok, result)`
convention (§5.2). Summary contract table:

| Export | Params | Returns |
|--------|--------|---------|
| `AddMoney` | charid, currency, amount, opts | ok, {txId, balanceAfter} |
| `RemoveMoney` | charid, currency, amount, opts | ok, {txId, balanceAfter} |
| `CanAfford` | charid, currency, amount, opts | bool |
| `GetWalletBalance` | charid, currency | number |
| `GetBankBalance` | accountId, currency | number |
| `GetPrimaryAccount` | charid | account table |
| `Transfer` | fromAcct, toAcct, currency, amount, opts | ok, {txId} |
| `AddToSociety` / `RemoveFromSociety` | society, currency, amount, opts | ok, result |
| `GetSocietyBalance` | society, currency | number |
| `RunPayroll` | society, payrollTable, opts | ok, {paid, failed} |
| `IssueInvoice` | issuer, targetCharid, currency, amount, memo | ok, {billId} |
| `IssueFine` / `LevyTax` | targetCharid, currency, amount, memo, opts | ok, {billId} |
| `GetCollectionsQueue` | filterOpts | list |
| `RecordCollection` | billId, amount, opts | ok, {balanceRemaining} |
| `PlaceLien` | targetCharid, accountId, amount, opts | ok, {lienId} |
| `EscalateToLawman` | billId, opts | ok, {warrantFiled} (govt debt only) |
| `GetDebtStatus` | charid | {tier, bills[]} |
| `StartEscort` | collectorId, debtorId, billId | ok |
| `ValuateItems` | itemList | number (assessed value) |
| `SeizeAssets` | collectorId, debtorId, billId, itemList, opts | ok, {applied, surplus, shortfall} |
| `IsSeizureAuthorized` | collectorId, debtorId | bool |
| `GetBusinessAccount` | business | account table |
| `RegisterBusiness` | business, ownerCharid, buildingPrice, opts | ok, {taxBasis} |
| `AssessBusinessTax` | business, opts | ok, {assessed, balanceOwed} |
| `GetTaxLedger` | business | tax-ledger table |
| `RemitTax` | business, amount, opts | ok, {balanceOwed} |
| `IsBusinessOwner` | charid, business | bool |
| `CreateLoan` | charid, principal, rate, opts | ok, {loanId, totalDue} |
| `GetBranchReserve` | branchId, currency | number |
| `ClaimBranchReserve` | branchId, currency, opts | ok, {looted} |
| `GetTransactions` | accountId, filterOpts | list |

### 7.2 Net events (`server/api/events.lua`) — design §6.2
- Inbound wrappers: `sov_bank:server:addMoney`, `:removeMoney`, `:transfer`, … —
  thin `TriggerEvent` shims over the exports for event-style callers.
- Outbound broadcasts (bank → listeners): `transactionCompleted`,
  `balanceChanged`, `loanDefaulted`, `accountFrozen`, `billPaid`, `debtOverdue`,
  `debtInCollections`, `warrantFiled`, `assetsSeized`, and client `notify`.

### 7.3 VORP callbacks (`server/api/callbacks.lua`) — design §6.3
Client→server with reply, **every one proximity-gated**: the handler resolves the
player's server-side coords and rejects (`ERR_NOT_AT_BRANCH`) if not within
`Config.Locations` teller range. Names: `sov_bank:getAccounts`, `:deposit`,
`:withdraw`, `:transfer`, `:openLoan`, `:repayLoan`, `:sdb*`, `:goldExchange`,
`:getStatements`, `:business*`, `:remitTax`, `:society*`, `:collections*`.

---

## 8. Key Data Flows (sequences)

### 8.1 Deposit (wallet → bank)
1. Client at teller → `TriggerServerCallback('sov_bank:deposit', cb, accountId, currency, amount)`.
2. Callback: proximity check → resolve charid → access check (`deposit`+ on account).
3. `Money.move{charid, accountId, currency, delta=+amount, category='deposit', wallet='remove'}`.
4. Engine: lock → idempotency → SQL txn (credit account, ledger row) → commit →
   `Bridge.WalletRemove`. On wallet fail → compensate.
5. Fire `balanceChanged` + `transactionCompleted`; `cb(ok, result)` → NUI refresh.

### 8.2 Transfer (with fee → insurance)
1. Validate both accounts exist/active; access on source.
2. Compute fee (`Config.Fees`, same/cross branch).
3. One SQL txn: debit source (amount+fee), credit destination (amount), credit
   `SYS-INSURANCE` (fee); three ledger rows sharing a `group_uuid` in memo.
4. Commit → `transactionCompleted` ×n. No wallet leg → no compensation.

### 8.3 Payroll (`RunPayroll`) — atomic batch
1. Sum `payrollTable`; verify society balance ≥ total (unless `allowNeg`).
2. Single SQL txn: debit society once, credit each employee account (or wallet
   leg queued), N ledger rows. Any row fails → whole txn rolls back → `ERR_PAYROLL`.
3. Return `{paid[], failed[]}`.

### 8.4 Loan lifecycle
- `CreateLoan`: `total_due = principal + round(principal × originationRate)`; row
  `pending`; if `requireApproval` false → auto-active + disburse via `Money.move`.
- Approve (admin/teller): status→`active`, disburse principal to `account_id`.
- `repayLoan`: `Money.move` debtor→`SYS-GOV`/lender, decrement `balance_remaining`;
  at 0 → `paid`. Past `due_by` unpaid → scheduler marks `defaulted`, fires
  `loanDefaulted`, optional account freeze.

### 8.5 Collection encounter + seizure (design §5.14)
1. Tax Collector opens queue (`GetCollectionsQueue`) at the Tax Office.
2. Field encounter ladder (RP): demand → `StartEscort` (flag "accompany to bank") →
   if refused/fled → restraint resource calls `IsSeizureAuthorized(collector,debtor)`
   (checks open tier-2 debt) before allowing rope/hogtie.
3. `SeizeAssets`: server re-verifies debt → `ValuateItems` (via `Config.Collections.
   seizure.valuation`) → cap to `balance_remaining`+fees → remove items (inventory) →
   credit proceeds to creditor via `Money.move` → apply to bill → return surplus to
   debtor → write `sov_bank_seizures` row → fire `assetsSeized`. Shortfall keeps
   the bill open (govt debt may escalate).

### 8.6 Business tax (design §5.15)
- On building purchase (routed through bank) → `RegisterBusiness(business, owner,
  price)` sets `building_price`, `license_rate=Config.BusinessTax.licenseRate`,
  `next_due_at = now + assessEveryRealDays`.
- Scheduler each due period → `AssessBusinessTax`: `amount = round(building_price ×
  license_rate)`; `assessed += amount`, `balance_owed += amount`, ledger
  `tax_assessed`; set next `due_at`.
- `RemitTax` at teller → `Money.move` owner/business→`SYS-GOV`, `remitted +=`,
  `balance_owed -=`, ledger `tax_remit`.
- If `balance_owed > 0` past `next_due_at` + grace and `overdueBecomesGovtDebt` →
  `billing.lua` opens a `tax` bill and hands it to `collections.lua` (tier flow).

### 8.7 Branch heist (design §5.11)
- Heist script (owns the action) → `ClaimBranchReserve(branchId, 0, opts)`.
- Engine: read `sov_bank_reserves`, compute `looted = reserve × opts.fraction`
  (payout randomization varies per call via server RNG in the heist script, passed
  in `opts` and clamped to `payoutRange`), cap to reserve, decrement reserve under
  a `reserve:<branch>` mutex with a `balance >= looted` guard, credit looters'
  wallets, write a `heist` ledger row. Player accounts are never queried or
  touched. Scheduler refills reserve toward `cap` on `replenishRealHrs`.
- **Implementation note:** the heist ledger row is written with `account_id NULL`
  (like wallet-only ops) with the branch named in `memo`, rather than against a
  per-branch system *account*. The reserve is a separate pool from the accounts
  table, so keeping these rows off every account keeps `Ledger.reconcile` (§5.6)
  exact — and makes "a robbery cannot touch a player balance" structurally true
  rather than merely enforced.

---

## 9. Scheduler (`server/scheduler.lua`)

Real-life-time driven; all timers use `os.time()` epoch seconds. Two mechanisms:

1. **Lazy evaluation (preferred):** interest and tax are computed when the relevant
   account/business is touched — compare `now` to `last_accrued_at`/`next_due_at`,
   post any elapsed whole periods (capped by `Config.Interest.catchUpCap`). This is
   offline-safe: a player who was away 30 days gets correct (capped) accrual the
   moment they bank, with zero background cost while offline.
2. **Sweep tick (backstop):** a low-frequency loop (e.g. every 30 min) that:
   - posts due savings interest for accounts not otherwise touched,
   - assesses due business taxes and opens delinquency bills,
   - marks overdue loans `defaulted`,
   - advances bills through tiers (pending→overdue→in_collections) by age,
   - refills branch reserves toward cap,
   - runs periodic reconciliation on a rotating slice of accounts.

Guard against double-posting via `last_*_at` timestamps + idempotency keys derived
from `(accountId, periodIndex)` so lazy and sweep paths can never both post the
same period.

---

## 10. Client & NUI

### 10.1 Client (`client/`)
- `main.lua`: spawn blips + teller peds from `config/locations.lua`; register
  interaction (prompt/target) at each teller.
- `teller.lua`: on interact → set `atBranch` state, open NUI (`SetNuiFocus`), send
  `open` message with the branch's enabled feature set. Closing clears focus and
  `atBranch`.
- `nui.lua`: marshals NUI callbacks ↔ VORP server callbacks. The client sends
  *intent only*; it never sends or trusts a balance.

### 10.2 NUI protocol (`web/`)
- SPA with views: Accounts, Statements, Transfer, Loans, SDB, Gold, Business/Tax
  (if owner), Society (if boss), Collections (if Tax Collector).
- Message shape: `{ action, payload }` in, `{ ok, data|error }` out. No browser
  storage (session-memory only). All numbers rendered via `toDisplay`.
- The NUI never assumes proximity; the server re-checks on every callback (§7.3).

---

## 11. Security Model

- **Server-authoritative:** client sends intent; server validates identity, access,
  proximity, amount, and balance inside the transaction. (§5.5, §7.3)
- **Proximity gating:** all account operations require a server-verified teller
  distance check; wallet-only payouts (job wages) are exempt (design §6.1 note).
- **Access control:** every account op checks `sov_bank_access` level; society/
  business ops check role/whitelist via bridge.
- **Seizure guardrails:** `SeizeAssets` requires a verified open tier-2 debt, caps
  to owed+fees, honors exempt-items, and logs every seizure (design §5.14).
- **Idempotency + locking:** prevents duplicate/racing mutations (§5.3–5.4).
- **Rate limiting:** per-source token bucket on callbacks; reject floods.
- **No client trust for money:** amounts are validated (`assertValid`) and bounded;
  negative balances only under `Config.Credit.enabled` within `credit_limit`.
- **Audit:** every mutation → ledger + optional Discord (`server/logging.lua`).
- **Admin actions** are ledgered as `admin_adjust` with the actor recorded.

---

## 12. Error Handling & Logging

- Central `Constants.Err` code table; all layers return codes, never raw strings.
- `logging.lua` levels: `debug/info/warn/error`; `error` always persists.
- Discord webhooks per category (`tx`, `loans`, `admin`) when
  `Config.Discord.enabled`. Payloads are batched to avoid rate limits.
- Player-facing failures map error codes → friendly `Bridge.Notify` messages.

---

## 13. Performance & Scaling

- Hot reads (balance, accounts) served from a short-TTL in-memory cache keyed by
  accountId, invalidated on any mutation to that account.
- Indexes cover the hot paths: `idx_account_time` (statements), `idx_target`/
  `idx_status` (collections sweeps), `uq_tx_uuid` (idempotency).
- Statements paginate via `balance_after` snapshots — no on-read summation.
- Concurrency: engine lock is per-account, so unrelated accounts never contend.
- Sweep tick processes accounts/businesses in bounded slices to avoid frame hitches.

---

## 14. Testing & QA Plan

**Correctness (money invariants):**
- Deposit/withdraw round-trips leave wallet+bank sum invariant.
- Transfer conserves total across source+dest+insurance (fee accounted, not lost).
- Reconciliation: ledger sum == stored balance for every account after a scripted
  workload of N random ops.
- Idempotency: replaying the same `tx_uuid` never double-applies.
- Concurrency: parallel withdrawals on one account can't overdraw (lock test).
- Compensation: simulated wallet-apply failure leaves a balanced ledger and no net
  change.

**Feature scenarios (integration):**
- Loan create→disburse→repay→paid; and →default path.
- Savings interest lazy vs. sweep produce identical postings (no double-post).
- Business tax: register→assess→remit→delinquent→collections→(escalate) warrant.
- Collection encounter: escort-pays vs. refuse→seize; seizure caps + surplus return
  + audit row correctness.
- Heist: `ClaimBranchReserve` never alters any player/society account balance
  (assert by diffing all balances before/after).

**Security:**
- Callbacks reject when not at a branch; access-level enforcement; rate-limit trips.
- Fuzz amounts (negative, float, huge) → `ERR_BAD_AMOUNT`, no state change.

Recommend a `sov_bank_test` dev-only resource driving the exports headlessly, plus
a manual QA checklist for NUI flows.

---

## 15. Deployment & Migration

1. Import `sql/install.sql`.
2. Ensure `vorp_core`, `oxmysql`, `vorp_inventory` start **before** `sov_bank`.
3. Configure `config/config.lua` + `config/locations.lua` (branches, rates, tax,
   heist reserves).
4. First boot seeds `SYS-INSURANCE` and `SYS-GOV` system accounts and per-branch
   reserve rows. Account numbers 1–1000 are reserved for government accounts
   (`Config.ReservedNumbers`): system rows are pinned to ids/numbers inside the
   range (`SVB-0000001` gov, `SVB-0000002` insurance) and the table's
   AUTO_INCREMENT starts at 1001, so organic accounts brand from `SVB-0001001`.
5. Schema versioning: a `sov_bank_meta(version)` row; `main.lua` runs ordered
   migration steps when the code version exceeds the stored version.

---

## 16. Open Technical Questions

1. **Cross-resource money-apply ordering.** Compensation (§5.5) handles wallet-apply
   failure, but confirm VORP's `addCurrency/removeCurrency` return a reliable
   success signal; if not, wrap with a read-back verify.
2. **Item valuation source** (`ValuateItems`): pull from `sovereign_stores`/economy
   sell prices vs. a static price table — needs the stores contract (design §12.6a).
3. **Restraint resource identity** for `IsSeizureAuthorized` wiring (design §12.6a).
4. **Building-purchase entry point:** confirm property purchase routes through the
   bank so `RegisterBusiness` fires automatically (design §5.15 note).
5. **Callback API exactness:** confirm the installed VORP version's callback
   register/trigger names (`Core.Callback.Register` vs `TriggerServerCallback`).
6. **Payroll wallet vs. bank default:** do wages land in wallet or bank by default?

---

*End of technical specification. Pairs with `sovereign_bank_spec.md` (design). Keep
both in lockstep: a design change updates the feature spec first, then this doc's
affected sections (schema, exports, flows).*
