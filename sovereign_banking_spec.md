# Sovereign Bank — Design & Feature Specification

**Target framework:** VORP Core (RedM)
**Setting:** 1896 — the American frontier. Every feature must be believable for
the period. No electronic anything, no remote access, no ATMs, no mobile devices.
**Role:** Central financial authority for the Sovereign script suite
**Integration model:** Server exports + net events (+ VORP callbacks)
**Status:** Design spec — not implemented. This document is the blueprint.

> **Revision note (v2):** period-authenticity pass applied. Removed ATMs, mobile
> ledgers, and cheques; interest is savings-only and accrues on real-life days;
> fines/taxes now route through the lawman system; medical added as a society
> account. See §13 changelog.

---

## 1. Vision & Guiding Principles

Sovereign Bank is not "a bank UI." It is the **money authority** for the entire
server. Every dollar, gold piece, and rol that moves — a job payout, a store
purchase, a fine, a heist score, a payroll run — should be able to route through
Sovereign Bank so there is exactly one source of truth for balances, one audit
trail, and one set of rules.

Six principles drive every decision below:

1. **Period-authentic to 1896.** If it couldn't exist on the frontier in 1896, it
   isn't in the bank. Banking is a *place you ride to*, not a service in your
   pocket. This constraint is a feature — it makes money physical and travel
   meaningful, and it shapes every UX decision.
2. **Server-authoritative, always.** The client never decides an amount, never
   holds a trusted balance, and never triggers a raw money mutation. The client
   asks; the server validates, mutates, and confirms.
3. **Single source of truth.** VORP Core still physically holds a character's
   wallet (`character.money/gold/rol`), but Sovereign Bank owns the *bank-side*
   balances and is the only resource that should perform account mutations. Other
   scripts talk to the bank, not to each other's balances.
4. **Every movement is a ledger entry.** No money is added or removed without a
   corresponding immutable transaction row. Balances are always reconcilable
   against the ledger.
5. **Integration-first.** The bank is designed to be *called by* Sovereign
   scripts. Its export surface is the product as much as its UI is.
6. **Idempotent & atomic.** Money operations are transactional (all-or-nothing)
   and support idempotency keys so a double-fired event or a network retry can
   never double-charge or double-pay.

**Non-goals (v1):** stock market / investments, cross-server banking, and full
NPC-economy simulation. These are noted in the roadmap but out of scope.

---

## 2. Currency Model

Sovereign Bank tracks all three VORP currencies natively, using VORP's own type
IDs so there is never a translation mismatch:

| Currency | VORP type ID | Bank usage |
|----------|--------------|------------|
| Money (dollars) | `0` | Primary account currency, cash-in-hand vs. banked |
| Gold | `1` | Second-class account currency, gold vault, exchange |
| Rol | `2` | Tracked, optional premium/token currency (config-gated) |

Two conceptual pools per character:

- **Wallet (cash-in-hand):** owned by VORP Core (`character.money` etc.). Physical,
  can be robbed/dropped per server rules. This is the *only* money you carry.
- **Bank balance:** owned by Sovereign Bank, stored in its own tables.
  **Never at risk in a robbery** — banked funds are *government-insured* and can
  never be lost to a branch heist (see §5.11). Interest-bearing (savings only),
  transferable, lendable — but only reachable in person at a bank branch (see
  §5.9–5.10).

The bank moves value between wallet ↔ bank balance, between bank balances
(transfers), and to/from external systems (payroll, fines, stores) while keeping
both sides consistent.

> **Precision note:** store all monetary values as **integer cents**, never
> floats. `$12.34` → `1234`. This eliminates rounding drift across interest,
> fees, and splits, and matches the period convention of operating in small
> denominations, which keeps frontier inflation slow.

---

## 3. High-Level Architecture

```
                    ┌───────────────────────────────────────┐
  Other Sovereign   │            SOVEREIGN BANK              │
  scripts  ────────▶│  (server-authoritative money engine)  │
  (jobs, stores,    │                                       │
   lawman, heists)  │  ┌─────────────┐   ┌───────────────┐  │
        exports/    │  │  Money API  │   │  Ledger /     │  │
        events      │  │  (validate, │──▶│  Transaction  │  │
                    │  │   mutate)   │   │  Engine       │  │
                    │  └─────┬───────┘   └──────┬────────┘  │
                    │        │                  │           │
                    │   ┌────▼─────┐      ┌─────▼──────┐    │
                    │   │  VORP    │      │  oxmysql   │    │
                    │   │  Core    │      │  (accounts,│    │
                    │   │  bridge  │      │  tx, loans)│    │
                    │   └──────────┘      └────────────┘    │
                    └───────────────────────────────────────┘
                                    ▲
                                    │ net events / callbacks
                                    ▼
                    Client UI (NUI teller — only at a bank branch)
```

**Layered internally so VORP is swappable later:**

- **Framework bridge layer** — the *only* code that calls VORP directly
  (`Core.getUser`, `getUsedCharacter`, `addCurrency`, `removeCurrency`). Isolating
  this means a future RSG/standalone port only rewrites one file.
- **Money engine** — validation, limits, fees, atomic mutations, idempotency.
- **Ledger engine** — writes immutable transaction rows, reconciliation.
- **Feature modules** — accounts, transfers, loans, SDB, gold exchange, societies,
  invoices. Each module only talks to the money + ledger engines.
- **Integration API layer** — exports, events, callbacks exposed to other
  resources.
- **Presentation** — NUI teller and admin panel (branch-only; no ATM, no mobile).

---

## 4. Data Model (oxmysql / MySQL)

All tables use `charIdentifier` (VORP's stable character key) as the owning key,
never the fleeting `source`.

### `sovereign_banking_accounts`
| Column | Type | Notes |
|--------|------|-------|
| id | INT PK AI | Internal account id |
| account_number | VARCHAR(24) UNIQUE | Human-facing (e.g. `SVB-0000123`) |
| owner_type | ENUM('character','society','business','joint','system') | Who owns it |
| owner_id | VARCHAR(64) | charIdentifier, society name, or system key |
| name | VARCHAR(64) | "Checking", "Savings", "Ranch Fund", etc. |
| kind | ENUM('checking','savings','society') | Drives interest eligibility |
| balance_money | BIGINT default 0 | Integer cents |
| balance_gold | BIGINT default 0 | Integer (gold*100) |
| balance_rol | BIGINT default 0 | Optional |
| status | ENUM('active','frozen','closed') | |
| credit_limit | BIGINT default 0 | Overdraft/credit allowance (feature-gated) |
| created_at / updated_at | TIMESTAMP | |

### `sovereign_banking_access`
Shared-account permissions (gangs, families, businesses, factions).
| Column | Type | Notes |
|--------|------|-------|
| id | INT PK AI | |
| account_id | INT FK | |
| charidentifier | VARCHAR(64) | Grantee |
| access_level | ENUM('owner','admin','withdraw','deposit','read') | |
| granted_by | VARCHAR(64) | |
| created_at | TIMESTAMP | |

### `sovereign_banking_transactions` (the ledger — append-only)
| Column | Type | Notes |
|--------|------|-------|
| id | BIGINT PK AI | |
| tx_uuid | CHAR(36) UNIQUE | Idempotency key |
| account_id | INT FK NULL | Null for pure wallet ops |
| counterparty_account_id | INT FK NULL | For transfers |
| currency | TINYINT | 0/1/2 |
| direction | ENUM('credit','debit') | |
| amount | BIGINT | Always positive; direction gives sign |
| balance_after | BIGINT | Snapshot for fast statements |
| category | VARCHAR(40) | `deposit`,`withdraw`,`transfer`,`payroll`,`fine`,`tax`,`purchase`,`loan_disburse`,`loan_repay`,`interest`,`fee`,`heist`,`admin_adjust`… |
| source_resource | VARCHAR(48) | Which script initiated it (attribution) |
| memo | VARCHAR(140) | Human note / statement line |
| created_at | TIMESTAMP | Indexed |

### `sovereign_banking_loans`
Fixed-cost loans (see §5.3 — total owed is set at origination; no compounding).
| Column | Type | Notes |
|--------|------|-------|
| id | INT PK AI | |
| charidentifier | VARCHAR(64) | Borrower |
| account_id | INT FK | Disbursement target |
| principal | BIGINT | Amount lent |
| total_due | BIGINT | Principal + fixed origination interest |
| balance_remaining | BIGINT | Counts down as repaid |
| interest_flat | DECIMAL(5,4) | Rate used to compute total_due at approval |
| due_by | DATETIME NULL | Real-life due date (optional term) |
| status | ENUM('pending','active','paid','defaulted','denied') | |
| approved_by | VARCHAR(64) NULL | Teller/admin |
| created_at / updated_at | TIMESTAMP | |

### `sovereign_banking_sdb` (safety deposit boxes)
Box metadata; contents live in VORP Inventory as a stash keyed to the box id.
| Column | Type | Notes |
|--------|------|-------|
| id | INT PK AI | |
| account_id | INT FK NULL | Optional link |
| owner_id | VARCHAR(64) | |
| size | ENUM('small','medium','large') | Weight/slot limits |
| stash_id | VARCHAR(64) | VORP inventory stash key |
| rent_paid_until | DATETIME NULL | Real-life date, for rental model |
| created_at | TIMESTAMP | |

### `sovereign_banking_savings_accrual`
Tracks last interest posting per savings account (real-life dates — see §5.4).
| Column | Type | Notes |
|--------|------|-------|
| account_id | INT FK PK | |
| last_accrued_at | DATETIME | Real-life timestamp of last interest run |

### `sovereign_banking_bills` (invoices, fines, taxes — no cheques)
| Column | Type | Notes |
|--------|------|-------|
| id | INT PK AI | |
| bill_uuid | CHAR(36) | |
| issuer_type | ENUM('character','society','system') | |
| issuer_id | VARCHAR(64) | |
| target_charid | VARCHAR(64) | Who owes/receives |
| kind | ENUM('invoice','fine','tax') | Fines/taxes issued by lawman system |
| currency | TINYINT | |
| amount | BIGINT | |
| status | ENUM('pending','overdue','in_collections','warrant','paid','cancelled','expired') | Tracks the §5.14 tier |
| due_at | DATETIME NULL | When it becomes overdue |
| assigned_collector | VARCHAR(64) NULL | Tax Collector working it (tier 2) |
| balance_remaining | BIGINT | Supports partial payment plans |
| memo | VARCHAR(140) | |
| created_at / paid_at | TIMESTAMP | |

### `sovereign_banking_business_tax` (Tax Ledger per business — §5.15)
Owned by the bank; the running tax record for a `sovereign_stores` business.
| Column | Type | Notes |
|--------|------|-------|
| business_id | VARCHAR(64) PK | Business/society key |
| building_price | BIGINT | Purchase price of the building — the tax basis |
| license_rate | DECIMAL(5,4) | % of building_price owed per period (default 0.25) |
| assessed | BIGINT | Business license tax assessed to date — no sales tax |
| remitted | BIGINT | Total remitted to the government |
| balance_owed | BIGINT | assessed − remitted |
| last_remit_at | DATETIME NULL | |
| next_due_at | DATETIME NULL | Remittance due date; past it → govt debt (§5.14) |

(Individual assessments/remittances also post to `sovereign_banking_transactions` with
`category` in `tax_assessed` / `tax_remit` for a full audit trail.)

### `sovereign_banking_seizures` (audit log for lawful seizures — §5.14)
| Column | Type | Notes |
|--------|------|-------|
| id | INT PK AI | |
| bill_id | INT FK | Debt the seizure paid toward |
| collector_charid | VARCHAR(64) | Tax Collector who acted |
| debtor_charid | VARCHAR(64) | |
| items_json | JSON/TEXT | Itemized goods seized |
| assessed_value | BIGINT | Total sale value applied |
| applied_amount | BIGINT | Amount put toward the debt |
| surplus_returned | BIGINT | Overage handed back to debtor |
| created_at | TIMESTAMP | |

### `sovereign_banking_config_rates` (optional, live-editable)
Per-branch interest rates, fees, and exchange rates, editable via admin panel
without a restart.

---

## 5. Full Feature Set

### 5.1 Accounts
- Personal checking account auto-created on first character load.
- Optional **savings** account (the only interest-bearing kind — see §5.4).
- Additional named accounts (business, joint) — configurable cap.
- Account numbers in a branded format (`SVB-0000123`). Numbers **1–1000 are
  reserved for government/system accounts** (`SVB-0000001` = Government Fund,
  `SVB-0000002` = Insurance Fund; society accounts join the range in Phase 2);
  player accounts begin at `SVB-0001001`.
- **Shared access** by level: owner / admin / withdraw / deposit / read-only.
- Grant/revoke access by character ID; all changes logged.
- Freeze/close (close only at zero balance, or sweep-to-owner on close).

### 5.2 Core money movement (all in person, at a branch)
- **Deposit** (wallet → bank) and **Withdraw** (bank → wallet) at a teller.
- **Transfer** between accounts, same-branch or cross-branch, with configurable
  flat/percent fee, both legs logged. (A cross-branch transfer is plausibly a
  telegraph/wire between banks — period-appropriate and a nice fee sink.)
  Collected fees route to the government **insurance fund** (see §5.11), which is
  what makes banked balances safe from robbery.
- **Direct pay** — character-to-character send by account number or char id,
  arranged at the teller.
- All movements pass through the atomic money engine (see §7).

### 5.3 Loans & Credit
- Application flow with or without an existing account.
- **Fixed-cost loans:** interest is applied *once at origination* — the borrower
  agrees to a `total_due` (principal + flat interest) up front. No periodic
  compounding. This is both simpler and more period-plausible than a modern
  accruing loan, and it keeps loan interest separate from savings interest.
- Per-branch and per-character rate used to compute `total_due`.
- Teller/admin **approval workflow** (pending → active/denied).
- Repayment: manual at a teller, or optional auto-debit when the borrower banks.
- Optional real-life **due date**; overdue → default handling (freeze account /
  flag credit / hand to collections roleplay).
- **Credit is a toggleable feature** (`Config.Credit.enabled`). When off, there
  are no overdrafts or credit lines and accounts hard-floor at zero; when on,
  per-account `credit_limit` permits controlled negative balances.

### 5.4 Interest — savings only, real-life accrual
- Interest applies **only to `savings`-kind accounts**. Checking, society, and
  joint accounts never accrue.
- Accrual is measured in **real-life days**, not in-game days
  (`Config.Interest.accrualRealDays`), posted as a `category='interest'` ledger
  entry each time an eligible period has elapsed since `last_accrued_at`.
- Accrual is evaluated lazily when the account is touched and/or by a periodic
  server task, so offline characters still earn correctly without a live timer.
- Designed to be modest — a safe place to store wealth, not an idle-farming
  exploit. (See open question in §12 on catch-up caps.)

### 5.5 Safety deposit boxes
- Three sizes with weight/slot limits, backed by VORP Inventory stashes.
- Purchase or rent (cash or gold); optional recurring rent tracked by real-life
  date with a grace period before lockout.
- Access grant/revoke by character id.
- Accessible only at a branch (it's a physical vault).

### 5.6 Gold exchange & vault
- Buy/sell gold ↔ money at a configurable rate with spread/fee (a period-plausible
  assayer/exchange service at the bank).
- Redeem physical gold-bar items into gold currency.
- Gold held as a distinct bank balance (type `1`).

### 5.7 Invoices, fines & taxes (no cheques)
- **No cheques.** Removed as out-of-scope for the period and the suite.
- **Invoices (civil):** any player/business issues a bill to another player; the
  recipient settles it in person at a bank (from bank balance or wallet); funds
  route to the issuer's account. The primary B2B/B2C commerce rail — a written
  promissory note settled at the bank. Invoices are **civil debt**: they can be
  chased by collections but **never** become an arrest warrant (see §5.14).
- **Taxes (government):** levied by the government / **Tax Office**, which the bank
  houses via the whitelisted Tax Collector role (§5.14). Taxes are government debt
  and *can* escalate to law enforcement if unpaid past the arrestable threshold.
- **Fines (government):** issued by the **lawman system** for crimes; the lawman
  script is the authority on who owes what and why, and calls into Sovereign Bank
  to record and collect them. Fines are government debt and follow the same
  escalation path as taxes.
- All three feed the shared **delinquency & collections pipeline** in §5.14, which
  governs how an unpaid bill moves from "overdue" to "in collections" to, for
  government debt only, a lawman warrant.

### 5.8 Society / faction accounts
- Society (business / gang / government) accounts with shared funds.
- **Medical shares a society account** alongside law enforcement — doctors draw
  wages and bank medical fees into a shared Medical fund, same as the Sheriff's
  office. Both are first-class society accounts.
- **Tax Office** is a society account too — the whitelisted Tax Collector role
  (§5.14) is employed here; collection commissions and collected taxes flow
  through this fund.
- Boss-menu hooks: deposit/withdraw, view ledger, run payroll from society fund.
- Rank-based access mapped onto the access-level system.
- This is what lets Sovereign's business, jobs, lawman, and medical scripts keep
  money "in the organization."

### 5.9 Statements — at the bank only
- **No mobile ledger, no pocket ledger, no remote balance checks.** It is 1896:
  to see a balance, deposit, withdraw, transfer, take a loan, or review your
  statement, a character must **physically travel to a bank branch** and speak
  with the teller.
- At the teller: per-account transaction history filtered by category/date, shown
  on the teller NUI. `balance_after` snapshots make statements cheap to render.
- This physicality is intentional — it makes robbery, distance, and travel matter,
  and it's the core period constraint the whole UX is built around.

### 5.10 Bank branches & tellers (no ATMs)
- **No ATMs** — they did not exist in 1896. All banking happens at a staffed
  **teller** inside a bank branch.
- Branches are placed at configurable world locations (`Config.Locations.banks`)
  with blips and a teller ped/interaction point; each branch exposes the full
  feature set.
- Optional per-branch feature and rate overrides (e.g. a small frontier bank may
  not offer loans; a city bank may have better gold rates).
- Robbery/heist integration hooks live here (branch is a physical, robbable place).

### 5.11 Robbery, heists & the insurance fund
- **Player bank balances are never at risk.** A branch robbery can never debit,
  freeze, or reduce any character's or society's bank account. This is guaranteed
  in code, not just by config — the heist system has no path to player balances.
- **In-world justification:** banked money is *government-insured*, and that
  insurance is paid for by the bank fees already levied (transfer fees, exchange
  spreads, etc.). Those fees route into a system account, `SYS-INSURANCE`, which
  is the lore-and-ledger backing for "your money is safe here." No player
  reimbursement flow is ever needed because balances are simply never touched.
- **What a heist actually yields:** each branch holds a separate physical
  **cash reserve** (money on hand in the vault/till) — a distinct pool from every
  player account. A successful robbery pays out from this reserve only, logged as
  `category='heist'` against the branch's system account.
- The reserve is a configurable faucet: a per-branch cap, a payout range, and a
  real-life-timed replenishment so a branch can't be farmed back-to-back. City
  branches can hold more than frontier ones.
- The heist/robbery *gameplay* (cracking the vault, alarms, lawman dispatch) is
  owned by a separate heist/robbery script; Sovereign Bank exposes the reserve
  pool and a `ClaimBranchReserve(branchId, opts)` export it calls to collect the
  score. The bank stays the money authority; the heist script owns the action.

### 5.12 Admin & operations
- `/bankadmin` panel: create/edit branches, set rates/fees, freeze/close
  accounts, approve loans, force adjustments (always ledgered as `admin_adjust`).
- **Reconciliation report:** sum of ledger vs. stored balances; flags drift.
- Money-supply dashboard: total banked money/gold, faucet vs. sink totals by
  category over a window (economy-health telemetry for you as owner).

### 5.13 Security & audit
- Every mutation logged with initiating resource, char id, and idempotency key.
- Optional Discord webhook per event category.
- Rate limiting / anti-spam on client-triggered actions.

### 5.14 Delinquency, collections & the Tax Collector role
The bank owns the full life of an unpaid debt through a **tiered escalation
pipeline**. Lawmen are the last tier, not the first — a debt only reaches them
once it is genuinely arrestable.

**Tier 0 — Billed.** An invoice/tax/fine is created (`pending`) with a due date.

**Tier 1 — Overdue (automated, bank).** Past the due date the bill flips to
`overdue`: configurable late fees apply and the debtor is notified next time they
bank. No humans involved — pure bookkeeping.

**Tier 2 — In collections (Tax Collector, civil).** Once a debt stays overdue past
a threshold it enters the **collections queue** worked by the **Tax Collector** —
a whitelisted job attached to the bank/Tax Office (this is the "whitelisted job"
option, folded in as the civil tier rather than an alternative). The Tax Collector
holds *civil legal authority* to compel payment, distinct from the lawman's
criminal authority: they may detain and seize **for debt** but never arrest or
jail. Tax Collectors:
  - see the collections queue (debtor, amount, debt type, age) at the Tax Office;
  - collect payment on the spot (routes straight into the bank ledger);
  - negotiate/record a **payment plan** (partial payments against `balance_remaining`);
  - place a **lien** on accounts/assets and add collection fees;
  - **escalate** a stubborn evader to the lawman tier — but only for *government*
    debt.
  Tax Collectors earn a base wage plus an optional **commission** on what they
  collect (a tuned faucet/sink — see §8), giving the role a real gameplay loop.

**The collection encounter (RP-gated escalation ladder).** When a Tax Collector
confronts a debtor in the world, force is the *last* option, never the first. The
encounter is designed to move down this ladder only as the debtor refuses:
  1. **Demand & voluntary pay** — the collector presents the debt; the debtor can
     settle on the spot from their wallet (routes into the bank ledger).
  2. **Escort to the bank** — if the debtor can't pay from pocket but is willing,
     they **accompany the collector to a branch** to withdraw from their account
     and pay. (Cooperative path — no force, still resolves the debt.)
  3. **Lawful detainment & seizure** — only if the debtor **refuses, resists, or
     flees** may the collector rope/hogtie them (using the server's existing
     restraint mechanic) and lawfully seize valuables. This step must follow real
     interaction — "not immediately, RP must happen." It is force *of last resort*
     under color of a legitimate, server-verified debt.

**Lawful seizure → repayment.** Seizure is a bounded, audited process, not a
license to rob:
  - **Only against a valid in-collections debt.** The server verifies the target
    actually has an open tier-2 debt before any seizure is permitted; there is no
    generic "rob under authority" path.
  - **Capped at debt + collection fees.** The collector seizes valuables up to the
    amount owed; they may not strip a debtor bare for a small debt.
  - **Seized goods are valued and "sold"** through the bank/Tax Office at a
    configured valuation (a price table, or the store/economy script's sell
    values). Proceeds apply to `balance_remaining`; the creditor (government fund
    or the private invoice issuer) is paid, minus the collector's commission.
  - **Surplus returns to the debtor** (or is banked to them); a **shortfall** keeps
    the remaining balance open — and for *government* debt, that unpaid remainder
    can then feed tier 3 escalation.
  - **Exempt items** are configurable (e.g. essential/quest items, equipped
    weapons) so seizure can't grief core gameplay.
  - **Every seizure is fully logged** — collector, debtor, itemized goods, assessed
    value, amount applied, surplus returned — for audit and dispute resolution.
  - Restraint (rope/hogtie) itself is owned by the existing restraint/interaction
    resource; Sovereign Bank only authorizes the *seizure* tied to the debt.

**Tier 3 — Warrant (lawman, criminal).** Only **government debt** (taxes, fines)
that crosses the **arrestable threshold** — or is escalated by a Tax Collector —
generates a **warrant / county work assignment** handed to the lawman script. At
that point, and only then, lawmen can act. Paying the debt (under duress, at
booking, or via the bank) clears the warrant and closes the bill.

**Hard rule — civil vs. government:**
- **Private invoices are civil forever.** They can be pursued by a Tax Collector
  (liens, seizure, fees) but can **never** become an arrest warrant.
- **Taxes and fines are government debt** and are the *only* debts that can reach
  tier 3.

**Threshold (TBD).** What makes a government debt "arrestable" is not yet decided
and is fully config-driven — some combination of: total amount owed, days overdue,
number of ignored notices, and/or manual Tax Collector escalation. See §8
`Config.Collections` and open question §12.5.

**Ownership split (consistent with the rest of the suite):**
- Sovereign Bank owns the debt, the ledger, the collections queue, the Tax
  Collector job, liens, and payment plans.
- The lawman script owns arrests, jail, and everything that happens *after* a
  warrant is filed. The bank only hands it a warrant and listens for "resolved."
- Banking is **one source** of lawman work among many — never the only one.

### 5.15 Business accounts & the Tax Ledger (`sovereign_stores` integration)
Consistent with place-based banking, a business's money and its tax obligations
both live **under the bank** and are handled **at the teller** — not inside the
store script.

- **Business accounts live under the bank.** A whitelisted shop owner's business
  account(s) are `owner_type='business'` accounts in Sovereign Bank. The owner
  (and authorized employees, via access levels) deposit, withdraw, transfer, and
  view statements for the business **at a bank branch**, exactly like a personal
  account. `sovereign_stores` never holds the money itself — it calls the bank.
- **Sales tax and business tax are different things — do not conflate them.**
  - **Sales tax** (a percentage added to each transaction, a cut of every sale)
    **does not exist** in this server. It is not collected, tracked, or referenced
    anywhere in the suite.
  - **Business tax** is a separate, independent obligation: what a business owes
    for the right to operate, regardless of whether it makes a single sale. This
    is what the Tax Ledger tracks. It is a **flat license fee charged per period**,
    sized as a **percentage of the building's purchase price** — starting at
    **25%** (configurable). A building bought for $2,000 owes $500 per period. This
    scales the fee to property value automatically: bigger holdings cost more to
    keep, making the fee a progressive money sink and a genuine consideration
    before buying an expensive property.
- **The Tax Ledger belongs to the bank.** Each business has a Tax Ledger
  (`sovereign_banking_business_tax`) that the bank owns and displays at the teller. It
  tracks the flat business tax assessed, tax remitted, and the outstanding balance
  owed.
- **Assessment:** each period the bank assesses `licenseRate × building_price`
  (default 25%) into the business's Tax Ledger, on a schedule (`Config.BusinessTax`).
  This is *not* driven by sales — `sovereign_stores` does not report revenue to the
  bank. The **building purchase price** is captured when the property is bought
  (the purchase payment routes through the bank, so the bank records the price and
  sets the tax basis via `RegisterBusiness`).
- **Remittance:** the owner settles what the business owes **at the bank**, from
  the business account or wallet. Paid tax flows to the government fund.
- **Delinquency:** unremitted business tax past `next_due_at` becomes **government
  debt** and enters the §5.14 collections pipeline — a Tax Collector can pursue the
  owner, and it can escalate to a lawman warrant past the arrestable threshold,
  just like any other government debt.
- **Access control:** only whitelisted owners / authorized employees see a given
  business account and its Tax Ledger; enforced through the §5.1 access levels.

This keeps `sovereign_stores` focused on running a store (inventory, pricing,
storefront), while all money and tax authority stays in the bank — one source of
truth, reachable in one believable 1896 place.

---

## 6. Integration API — the Sovereign Contract

This is the heart of "integrates across the server." Other resources should
**never** call VORP money functions directly once the bank is installed — they go
through these. Standard Cfx pattern: **exports** for synchronous calls,
**events** for fire-and-forget, **VORP callbacks** for client→server requests
needing a reply.

### 6.1 Server exports (called by other resources)

```lua
-- ADD money to a character (wallet or bank). Returns bool ok, string txId|err.
exports['sovereign_banking']:AddMoney(charid, currency, amount, opts)
-- REMOVE money. Fails cleanly (returns false) if insufficient funds.
exports['sovereign_banking']:RemoveMoney(charid, currency, amount, opts)
-- Can this char afford it? (no mutation)
exports['sovereign_banking']:CanAfford(charid, currency, amount, opts)
-- Read balances.
exports['sovereign_banking']:GetWalletBalance(charid, currency)
exports['sovereign_banking']:GetBankBalance(accountId, currency)
exports['sovereign_banking']:GetPrimaryAccount(charid)
-- Move money between two accounts atomically.
exports['sovereign_banking']:Transfer(fromAccountId, toAccountId, currency, amount, opts)
-- Society / faction helpers (law, medical, businesses, gangs).
exports['sovereign_banking']:AddToSociety(society, currency, amount, opts)
exports['sovereign_banking']:RemoveFromSociety(society, currency, amount, opts)
exports['sovereign_banking']:GetSocietyBalance(society, currency)
exports['sovereign_banking']:RunPayroll(society, payrollTable, opts)   -- batch, atomic
-- Invoices, fines & taxes.
exports['sovereign_banking']:IssueInvoice(issuer, targetCharid, currency, amount, memo) -- civil
exports['sovereign_banking']:IssueFine(targetCharid, currency, amount, memo, opts)  -- called by lawman
exports['sovereign_banking']:LevyTax(targetCharid, currency, amount, memo, opts)    -- called by Tax Office
-- Collections pipeline (§5.14). Read/act on delinquent debt.
exports['sovereign_banking']:GetCollectionsQueue(filterOpts)          -- Tax Collector view
exports['sovereign_banking']:RecordCollection(billId, amount, opts)   -- on-the-spot / payment plan
exports['sovereign_banking']:PlaceLien(targetCharid, accountId, amount, opts)
exports['sovereign_banking']:EscalateToLawman(billId, opts)           -- govt debt only; files warrant
exports['sovereign_banking']:GetDebtStatus(charid)                    -- what a char owes, by tier
-- Collection encounter & lawful seizure (§5.14). Server verifies a valid debt.
exports['sovereign_banking']:StartEscort(collectorId, debtorId, billId) -- flag "accompany to bank"
exports['sovereign_banking']:ValuateItems(itemList)                   -- assessed sale value of goods
exports['sovereign_banking']:SeizeAssets(collectorId, debtorId, billId, itemList, opts)
-- ^ verifies open tier-2 debt, caps to owed+fees, sells goods, applies proceeds,
--   returns surplus, logs everything. Returns (ok, {applied, surplus, shortfall}).
exports['sovereign_banking']:IsSeizureAuthorized(collectorId, debtorId) -- guard for restraint script
-- Loans.
exports['sovereign_banking']:CreateLoan(charid, principal, rate, opts)
-- Heist/robbery: collect a branch's physical cash reserve. NEVER touches player
-- balances. Returns (ok, amountLooted|err); auto-caps to available reserve.
exports['sovereign_banking']:GetBranchReserve(branchId, currency)
exports['sovereign_banking']:ClaimBranchReserve(branchId, currency, opts)
-- Business accounts & Tax Ledger (§5.15 — sovereign_stores).
exports['sovereign_banking']:GetBusinessAccount(business)             -- account(s) for a business
exports['sovereign_banking']:RegisterBusiness(business, ownerCharid, buildingPrice, opts) -- set tax basis on purchase
exports['sovereign_banking']:AssessBusinessTax(business, opts)        -- assess licenseRate × building_price (NO sales tax)
exports['sovereign_banking']:GetTaxLedger(business)                   -- assessed/remitted/owed/due
exports['sovereign_banking']:RemitTax(business, amount, opts)         -- owner settles at the bank
exports['sovereign_banking']:IsBusinessOwner(charid, business)        -- whitelist/access check
-- Read-only ledger query for other scripts / dashboards.
exports['sovereign_banking']:GetTransactions(accountId, filterOpts)
```

**The `opts` table** (shared across mutating calls) is where robustness lives:

```lua
opts = {
  reason    = 'job_payout',      -- becomes ledger category
  memo      = 'Herding wages',   -- statement line
  source    = 'sov_jobs',        -- initiating resource (auto-filled if omitted)
  target    = 'wallet',          -- 'wallet' | 'bank' | accountId
  idem      = 'uuid-or-nil',     -- idempotency key; dupes are no-ops
  silent    = false,             -- suppress player notification
  allowNeg  = false,             -- permit overdraft (only if Config.Credit.enabled)
}
```

Every mutating export returns `(ok: boolean, resultOrError: string)` — never
throws — so callers can branch safely.

> **Note on payouts vs. banking-in-person:** exports like `AddMoney` with
> `target='wallet'` pay a character directly (e.g. a job wage lands as cash in
> hand). Only *bank-account* operations (deposit/withdraw/transfer/statements)
> require being at a branch. A rancher can still be paid in the field; they just
> can't touch their savings until they ride into town. This preserves the 1896
> constraint without breaking normal gameplay loops.

### 6.2 Events (fire-and-forget + broadcast)

**Inbound (other scripts → bank):** thin event wrappers over the exports, for
resources that prefer events. e.g. `TriggerEvent('sovereign_banking:server:addMoney', ...)`.

**Outbound (bank → everyone, for reactions):** the bank *announces* what it did so
other systems can react without polling.

```lua
'sovereign_banking:server:transactionCompleted'   -- {charid, accountId, currency, amount, direction, category, txId}
'sovereign_banking:server:balanceChanged'         -- {charid, accountId, currency, newBalance}
'sovereign_banking:server:loanDefaulted'          -- {charid, loanId}
'sovereign_banking:server:accountFrozen'          -- {accountId, by}
'sovereign_banking:server:billPaid'               -- {billId, payerCharid, issuerId, amount, kind}
'sovereign_banking:server:debtOverdue'            -- {charid, billId, kind, amount}  (tier 1)
'sovereign_banking:server:debtInCollections'      -- {charid, billId, kind, amount}  (tier 2)
'sovereign_banking:server:warrantFiled'           -- {charid, billId, kind, amount, reason} (tier 3, govt only)
'sovereign_banking:server:assetsSeized'           -- {collectorId, debtorId, billId, items, applied, surplus}
'sovereign_banking:client:notify'                 -- push a UI notification to a player
```

### 6.3 VORP callbacks (client → server with reply)

For the teller NUI to fetch data or request an action and get a result. These are
gated server-side by a proximity check to a valid branch (§5.9–5.10):

```lua
-- registered server-side
Core.Callback.Register('sovereign_banking:getAccounts', function(source, cb, ...) end)
Core.Callback.Register('sovereign_banking:withdraw',    function(source, cb, ...) end)
Core.Callback.Register('sovereign_banking:transfer',    function(source, cb, ...) end)
-- called client-side (only when the player is at a teller)
Core.Callback.TriggerAsync('sovereign_banking:getAccounts', function(result) ... end)
```

### 6.4 Lawman integration (warrants from delinquent government debt)

The bank owns debt and collections (§5.14); the lawman script owns arrests. They
meet at exactly one handoff — the warrant:

- The **bank** runs tiers 0–2 itself (overdue → Tax Collector collections). Lawmen
  are not involved and receive nothing during these tiers.
- When a **government** debt crosses the arrestable threshold (or a Tax Collector
  calls `EscalateToLawman`), the bank files a warrant and fires
  `sovereign_banking:server:warrantFiled` — {charid, billId, kind, amount, reason}. This is
  the *only* moment a debt reaches the lawman script.
- The lawman script picks up the warrant as one of its work sources (among many),
  and owns everything after: pursuit, arrest, jail, booking.
- When the debt is paid (at a teller, via auto-debit at booking, or written off),
  the bank fires `sovereign_banking:server:billPaid`; the lawman script listens and clears
  the warrant on its side.
- **Private invoices never fire `warrantFiled`** — they are civil and cannot reach
  the lawman tier (§5.14 hard rule).
- The bank exposes debt status and account-freeze hooks; escalation *policy* past
  the warrant (bounty, jail time) belongs to the lawman script.

### 6.5 Migration shim (optional but powerful)

Ship an optional compatibility layer that **intercepts common VORP money calls**
so existing third-party scripts route through Sovereign Bank *without being
rewritten*. Provide drop-in exports mirroring the signatures other RedM scripts
expect (`getMoney`, `addMoney`, `removeMoney`) that internally call the bank
engine. This is how you get "integrate with other scripts as well if needed"
without forking every resource.

---

## 7. Transaction Integrity (the part that makes it trustworthy)

1. **Atomicity:** every multi-step money op (transfer, payroll, loan disburse)
   runs inside a single SQL transaction. Wallet mutation via VORP happens *after*
   the DB commit succeeds; if the VORP mutation fails, the DB txn is rolled back
   / compensated and the op reports failure. Never a partial state.
2. **Idempotency:** `tx_uuid` / `opts.idem` is unique-constrained. A retried event
   with the same key returns the original result instead of re-applying.
3. **Server-side validation:** amounts must be positive integers; balances
   re-read inside the txn (no trusting a stale read); negative balances only if
   `Config.Credit.enabled` and within `credit_limit`.
4. **Per-account locking:** serialize concurrent mutations on the same account
   (in-process mutex keyed by accountId) to prevent race-condition double-spends.
5. **Proximity gating:** bank-account operations require the requesting player to
   be at a valid branch, verified server-side — never trust the client's claim.
6. **Reconciliation job:** periodic task sums the ledger per account and compares
   to stored balance; drift is logged/alerted. Ledger is the ground truth.
7. **No client trust:** the client sends *intent* ("withdraw $50 from acct 3"),
   never a balance or a delta the server applies blindly.

---

## 8. Configuration (`config.lua` sketch)

```lua
Config.Currencies    = { money=true, gold=true, rol=false }
Config.StoreAsCents  = true
Config.MaxAccounts   = 4
Config.AccountPrefix = 'SVB-'

Config.Fees = {
  transferSameBranch  = { type='flat',    value=0 },
  transferCrossBranch = { type='percent', value=0.01 }, -- "wire" between banks
  goldExchangeSpread  = 0.05,
  sdbRent = { small=500, medium=1500, large=4000 }, -- cents, per rental period
  routeFeesTo = 'SYS-INSURANCE', -- fees fund the govt insurance account
}

Config.Heist = {
  -- Player balances are NEVER touchable. This only governs the branch cash reserve.
  reserveDefault   = 250000,      -- cents, base vault cash on hand per branch
  payoutRange      = { 0.4, 0.8 },-- fraction of current reserve a heist yields
  replenishRealHrs = 48,          -- real-life hours to refill an emptied reserve
  -- per-branch overrides live in Config.Locations.banks[i].reserve
}

Config.Interest = {
  savingsOnly     = true,   -- interest applies ONLY to savings accounts
  savingsAPR      = 0.02,   -- modest
  accrualRealDays = 7,      -- REAL-LIFE days between accruals
  catchUpCap      = 4,      -- max periods paid at once after long offline (see §12)
}

Config.Credit = {
  enabled = false,          -- master toggle for overdrafts / credit lines
}

Config.Collections = {
  lateFee            = { type='percent', value=0.05 }, -- added when a bill goes overdue
  overdueAfterDays   = 3,      -- real-life days past due_at → tier 1 (overdue)
  collectionsAfterDays = 7,    -- real-life days overdue → tier 2 (Tax Collector queue)
  taxCollectorCommission = 0.10, -- share of collected debt paid to the collector
  liensEnabled       = true,
  seizure = {
    enabled          = true,
    requireRestraint = true,     -- debtor must be roped/hogtied first (RP-gated)
    capToDebt        = true,     -- never seize more than owed + fees
    valuation        = 'store',  -- 'store' (use economy sell prices) | 'table'
    returnSurplus    = true,     -- overage goes back to the debtor
    exemptItems      = { --[[ 'ledger', 'quest_x', equipped weapons... ]] },
  },
  -- Tier 3 / arrestable threshold (TBD — see §12.5). GOVERNMENT DEBT ONLY.
  arrestable = {
    enabled          = true,
    minAmount        = 5000,   -- cents owed to be arrestable
    minOverdueDays   = 14,     -- real-life days
    allowManualEscalation = true, -- Tax Collector can escalate an evader
    -- private invoices can NEVER reach this tier, regardless of amount
  },
}

Config.Loans = {
  enabled=true, requireApproval=true, maxPrincipal=500000,
  originationRate=0.10,     -- flat interest folded into total_due at approval
  maxActivePerChar=1,
  defaultTermRealDays=14,   -- optional real-life due window (0 = no term)
}

Config.Locations = {
  -- No ATMs. Branches only.
  banks = { --[[ {coords, blip, teller, features={...}, rateOverrides={...}} ]] },
}

Config.BusinessTax = {
  -- NO SALES TAX anywhere. This is a flat license fee per period, sized by property.
  licenseRate           = 0.25,  -- fee per period = 25% of the building's purchase price
  assessEveryRealDays   = 7,     -- how often the license fee is assessed
  remitDueRealDays      = 7,     -- how long to remit after assessment before overdue
  overdueBecomesGovtDebt = true, -- unremitted tax → §5.14 collections pipeline
}

Config.Discord = { enabled=false, webhooks={ tx='', loans='', admin='' } }
Config.Notify  = 'vorp'   -- notification backend
```

Design rule: **content and tuning live in config; logic lives in code.** A server
owner should be able to add a branch, change a fee, or toggle credit/interest
without editing a `.lua` logic file.

---

## 9. Framework Bridge (future-proofing)

Even though v1 targets VORP only, isolate every VORP call behind
`bridge/vorp.lua` exposing a neutral interface:

```lua
Bridge.GetCharId(source)                 -> charid
Bridge.GetSourceFromCharId(charid)       -> source|nil
Bridge.WalletGet(charid, currency)       -> amount
Bridge.WalletAdd(charid, currency, amt)  -> ok
Bridge.WalletRemove(charid, currency, amt) -> ok
Bridge.Notify(source, msg, type)
Bridge.RegisterCallback(name, fn)
```

The entire money engine calls `Bridge.*`, never `Core.*`. A later RSG or
standalone port is then a single new bridge file — the ledger, loans, UI, and
export contract are untouched.

---

## 10. Presentation Layer (NUI)

- **Teller UI (branch-only):** accounts overview, deposit/withdraw/transfer,
  statements, loans, SDB, gold exchange, society funds (if boss), invoice/fine
  settlement. This is the *only* player-facing banking surface — there is no ATM
  UI and no mobile/pocket ledger.
- **Admin panel:** branch/rate management, account search, loan approvals,
  reconciliation & money-supply dashboard.
- Framework-agnostic front end talking only via the §6.3 callbacks (proximity-
  gated), so the UI survives a framework port too.

---

## 11. Build Phases (for when you do build)

- **Phase 0 — Foundation:** bridge layer, DB schema, money engine, ledger,
  idempotency, exports for Add/Remove/CanAfford/Get. *(This alone makes it the
  money authority other Sovereign scripts can start using — payouts to wallet
  work immediately, no UI needed.)*
- **Phase 1 — Accounts & teller UX:** checking/savings accounts,
  deposit/withdraw/transfer, teller UI at branches, statements, shared access,
  proximity gating.
- **Phase 2 — Society & commerce:** society accounts (incl. law + medical),
  payroll, invoices, and the lawman fines/taxes collection integration — the
  rails the rest of the Sovereign suite plugs into.
- **Phase 3 — Credit & storage:** loans (fixed-cost), savings interest (real-life
  accrual), safety deposit boxes, gold exchange.
- **Phase 4 — Ops & polish:** admin panel, reconciliation, money-supply
  dashboard, Discord logging, migration shim for third-party scripts.

Phase 0 is deliberately the "integration backbone" so every other Sovereign
script can depend on the exports before the teller UI is even finished.

---

## 12. Open Questions to Resolve Before Building

1. **Rol:** track it as a real currency, or ignore in v1? (Config-gated either way.)
2. **Savings interest tuning:** what APR, and how do we cap "catch-up" accrual so a
   player who's offline for a month doesn't return to a windfall? (`catchUpCap`.)
3. **One primary account per char, or many by default?** (`Config.MaxAccounts`.)
4. **Loan model confirmation:** fixed origination interest (current design) vs. any
   periodic charge — confirm fixed is what you want, and whether there's a term/due
   date or open-ended repayment.
5. **Arrestable threshold (the big TBD):** what tips a *government* debt from
   collections (tier 2) to a lawman warrant (tier 3)? Amount, days overdue,
   ignored-notice count, manual escalation, or a mix? Draft defaults live in
   `Config.Collections.arrestable`. (§5.14)
6. **Collections tuning:** late-fee size, overdue/collections timing, Tax Collector
   commission %, and whether liens need property-script integration in v1.
6a. **Seizure valuation & scope:** where do seized-item values come from (the store
   /economy script's sell prices vs. a bank price table)? What's on the exempt
   list? And which restraint resource owns rope/hogtie so `IsSeizureAuthorized`
   can gate it?
7. **Branch reserve tuning:** confirm reserve size, payout %, and replenish timing
   feel right, and whether an emptied reserve should visibly affect that branch
   (e.g. reduced services until refilled).
8. **Migration shim scope:** which third-party money signatures do we mirror?

**Resolved:**
- *Robbery model* → Player bank balances are **never** at risk; government-insured,
  funded by transfer/other fees into `SYS-INSURANCE`. Heists draw only from a
  per-branch physical cash reserve. (§2, §5.11, §8)
- *Society source of truth* → **Sovereign Bank owns society funds** outright
  (law, medical, tax office, businesses, gangs); other scripts read/mutate via
  exports. (§5.8)
- *Debt collection & lawman handoff* → tiered pipeline: bank runs overdue →
  Tax Collector (whitelisted job) collections → **only government debt** escalates
  to a lawman warrant past the threshold; **private invoices stay civil forever.**
  Banking is one of many lawman work sources, never the only one. (§5.7, §5.14, §6.4)

---

## 13. Changelog

**v2.6 (business tax = license fee sized by building price):**
- Defined **business tax** concretely: a flat **license fee per period** equal to
  `licenseRate × building purchase price`, default **25%** (§5.15).
- Bank captures the **building purchase price** as the tax basis when the property
  is bought (purchase routes through the bank); new export `RegisterBusiness`.
- Added `building_price` and `license_rate` to `sovereign_banking_business_tax`; updated
  `AssessBusinessTax` (now computes from basis) and `Config.BusinessTax.licenseRate`.

**v2.5 (no sales tax):**
- **Removed sales tax entirely** — no per-transaction/percentage tax anywhere.
- Reframed business tax as a **flat, periodic operating (license) tax** assessed by
  the government/Tax Office, not driven by sales. `sovereign_stores` no longer
  reports revenue to the bank. Renamed export `AccrueTax` → `AssessBusinessTax`,
  ledger column `accrued` → `assessed`, categories `tax_accrued` → `tax_assessed`;
  updated `Config.BusinessTax`.

**v2.4 (sovereign_stores: business accounts & Tax Ledger under the bank):**
- Added §5.15: **business accounts live under the bank** (`owner_type='business'`),
  accessed by whitelisted shop owners/employees at the teller — place-based, same
  as personal banking.
- Moved the **Tax Ledger under the bank** (`sovereign_banking_business_tax` table): the bank
  owns the record and the money. Exports `GetBusinessAccount`, `GetTaxLedger`,
  `RemitTax`, `IsBusinessOwner`; `Config.BusinessTax`.
- **Unremitted business tax → government debt** feeding the §5.14 collections
  pipeline (Tax Collector → possible lawman warrant).

**v2.3 (Tax Collector civil authority — detain & seize):**
- Gave the Tax Collector **civil legal authority** to detain and seize *for debt*
  (distinct from lawman criminal authority — no arrest/jail). Two-axis model:
  civil enforcement (collector) vs. criminal enforcement (lawman).
- Added the **RP-gated collection encounter ladder** (§5.14): demand/voluntary pay
  → escort to bank → lawful detainment & seizure, force only as last resort after
  RP and refusal.
- Added **lawful seizure → repayment**: seized valuables valued, "sold", proceeds
  applied to the debt; capped at owed+fees; surplus returned; shortfall persists
  (and can feed tier 3 for govt debt). Exempt-item list; full audit trail.
- New `sovereign_banking_seizures` table; exports `StartEscort`, `ValuateItems`,
  `SeizeAssets`, `IsSeizureAuthorized`; event `assetsSeized`; `Config.Collections.
  seizure` block. Restraint (rope/hogtie) delegated to the existing restraint
  resource; bank only authorizes the debt-tied seizure.

**v2.2 (delinquency pipeline + Tax Collector role):**
- Added §5.14 **tiered delinquency & collections pipeline**: overdue (bank) →
  in-collections (Tax Collector) → warrant (lawman, government debt only).
- Folded the "whitelisted job" idea in as the **Tax Collector** role — a civil
  collections tier attached to the bank/**Tax Office** society account, paid a
  wage + commission (§5.8, §5.14, §8 `Config.Collections`).
- **Hard rule:** private invoices are civil forever and can never become a warrant;
  only taxes and fines (government debt) can reach lawmen (§5.7, §5.14).
- Reframed lawman integration around a single **warrant handoff** (§6.4); added
  `warrantFiled`/`debtOverdue`/`debtInCollections` events and collections exports
  (`GetCollectionsQueue`, `RecordCollection`, `PlaceLien`, `EscalateToLawman`,
  `GetDebtStatus`).
- Extended `sovereign_banking_bills` schema for tiers (status enum, due_at, collector,
  balance_remaining). Arrestable threshold left as configurable TBD (§12.5).

**v2.1 (robbery & society ownership resolved):**
- **Player bank balances are never at risk in a robbery** — government-insured,
  guaranteed in code (§2, §5.11).
- Added the **insurance-fund model**: transfer/other fees route to a `SYS-INSURANCE`
  system account, the in-world justification that balances are safe (§5.2, §5.11, §8).
- Added the **branch cash-reserve heist model**: heists draw only from a per-branch
  physical reserve pool, with `GetBranchReserve`/`ClaimBranchReserve` exports and
  `Config.Heist` tuning (§5.11, §6.1, §8). Renumbered Admin→5.12, Security→5.13.
- **Confirmed Sovereign Bank owns all society funds** (law, medical, business,
  gangs); other scripts access via exports (§5.8, §12 resolved).

**v2 (period-authenticity + integration pass):**
- Added 1896 believability as guiding principle #1; reframed banking as
  place-based throughout.
- **Removed ATMs** (§5.10) — tellers/branches only.
- **Removed mobile/pocket ledger** (§5.9) — all banking is in person at a branch;
  added server-side proximity gating (§7.5, §6.3).
- **Removed cheques** (§5.7); `sovereign_banking_bills.kind` enum reduced to
  invoice/fine/tax.
- **Interest is savings-only and accrues on real-life days** (§5.4); added
  `sovereign_banking_savings_accrual` table and `Config.Interest.savingsOnly/accrualRealDays`.
- **Loans reworked to fixed-cost** (interest applied once at origination); schema
  updated with `total_due`/`interest_flat`; **credit made a master toggle**
  (`Config.Credit.enabled`).
- **Fines & taxes now route through the lawman system** (§5.7, §6.4); bank is the
  collector, lawman is the authority.
- **Medical added as a society account** alongside law enforcement (§5.8).
- Clarified wallet payouts (job wages, etc.) still work anywhere; only bank-account
  operations require a branch (§6.1 note).

*End of specification. This is a living design doc — as the Sovereign suite's
other scripts (jobs, stores, lawman, medical, business) get specced, their exact
integration points should be appended to §6.*
