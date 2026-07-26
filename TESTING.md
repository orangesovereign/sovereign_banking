# Sovereign Bank — Testing Ledger

A ledger of record for bringing `sov_bank` into service. Work it top to bottom;
each entry says what to do and what *should* happen. Mark the result and note
the error code on any failure — every failure in this resource returns a code
(`ERR_*`), and the code tells you which layer refused.

**Marking:** `[x]` passed · `[!]` failed (note the code) · `[-]` skipped/blocked

**Nothing in this resource has been run against a live server yet.** Everything
to date is syntax-checked and browser-tested against mock data. Entries marked
**⚠ HIGH RISK** are the assumptions most likely to break on first contact.

---

## 0. Pre-flight — before the first start

- [ ] `vorp_core`, `oxmysql`, `vorp_inventory` all start **before** `sov_bank`
- [ ] Resource folder is named **`sov_bank`** (exports resolve by folder name)
- [ ] `Config.Societies` job names match your real VORP jobs
      *(today only `medical` is live; `lawman` and `tax_office` are placeholders)*
- [ ] `add_ace group.admin sovbank.admin allow` in `server.cfg`
- [ ] Database user can `CREATE TABLE` and `ALTER TABLE` (boot does both)
- [ ] Take a database backup — first boot writes schema and seeds accounts

---

## 1. Boot & schema

| # | Do this | Expect |
|---|---------|--------|
| 1.1 | Start the resource | `Sovereign Bank v0.6.0 ready` in console, no red |
| 1.2 | `SHOW TABLES LIKE 'sov_bank_%'` | 11 tables |
| 1.3 | Console: `sovbank account <yourCharid>` | account row, number `SVB-0001001`+ |
| 1.4 | `SELECT id, account_number, owner_id FROM sov_bank_accounts WHERE owner_type='system'` | `1 / SVB-0000001 / SYS-GOV`, `2 / SVB-0000002 / SYS-INSURANCE` |
| 1.5 | Same for `owner_type='society'` | `lawman` №10, `medical` №11, `tax_office` №12 |
| 1.6 | `SELECT * FROM sov_bank_reserves` | one row per branch, `balance = cap` |
| 1.7 | Restart the resource twice | no duplicate accounts, no errors — all seeding is idempotent |

- [ ] 1.1  - [ ] 1.2  - [ ] 1.3  - [ ] 1.4  - [ ] 1.5  - [ ] 1.6  - [ ] 1.7

**If 1.3 shows an account numbered below 1001**, the reserved-range `ALTER` did
not apply — check for a SQL permission error at boot.

---

## 2. Automated suite — the money invariants

Run from the **server console** (not in-game chat). With a player online, pass
their server id to also exercise the wallet path:

```
sovbanktest 1
```

The suite creates throwaway accounts, drives the real engine, and deletes
everything it made. Expect `suite done: N passed, 0 failed`.

It covers, and these are the claims that matter most:

- [ ] 2.1 Player accounts are numbered outside the reserved range
- [ ] 2.2 Government fund holds `SVB-0000001`, insurance `SVB-0000002`
- [ ] 2.3 Credit/debit apply and report the right `balanceAfter`
- [ ] 2.4 A ledger row is written with amount, direction and `balance_after`
- [ ] 2.5 Overdraw is refused with `ERR_INSUFFICIENT_FUNDS`, **no state change**
- [ ] 2.6 Fuzzed amounts (negative, zero, float, huge, string) → `ERR_BAD_AMOUNT`
- [ ] 2.7 Unknown currency → `ERR_BAD_CURRENCY`; disabled → `ERR_CURRENCY_DISABLED`
- [ ] 2.8 **Idempotency**: replaying a `tx_uuid` returns the original, applies once
- [ ] 2.9 Transfer applies the configured fee
- [ ] 2.10 **Conservation**: source + destination + insurance sum is unchanged
- [ ] 2.11 Transfer replay with the same key is a no-op
- [ ] 2.12 Self-transfer refused; transfer into a frozen account refused
- [ ] 2.13 **Concurrency**: 10 racing transfers, only the affordable number succeed
- [ ] 2.14 **Reconciliation**: ledger sum == stored balance for every account touched
- [ ] 2.15 Wallet round-trip (credit→deposit→withdraw→debit) conserves both sides

**Not covered — needs a deliberate failure to provoke:** the wallet-apply
compensation branch (§5.5). To test it, stop `vorp_core` mid-deposit; the DB leg
should reverse with a `compensation` ledger row and the op return
`ERR_WALLET_APPLY`.

- [ ] 2.16 Compensation branch (optional, destructive — dev server only)

---

## 3. Teller UX — at a branch

Ride to a bank. Hold **[G]** at the counter.

- [ ] 3.1 Blip shows on the map at each of the four branches
- [ ] 3.2 Teller ped spawns and is visible *(RDR3 peds spawn invisible without the outfit native — if you see a T-pose or nothing, that's the bug)*
- [ ] 3.3 Prompt appears within range; UI opens on hold
- [ ] 3.4 Dashboard renders: accounts left, ledger centre, actions right, dark quick-bar
- [ ] 3.5 Branch name/subtitle/hours match `config/locations.lua`
- [ ] 3.6 Ledger dates read as 1896 (real year − 130)
- [ ] 3.7 Walking away from the counter closes the UI
- [ ] 3.8 **ESC** closes a modal first, then the bank

**Coordinates in `config/locations.lua` are approximations.** If the prompt
never appears, stand at the counter and compare your coords to `teller`.

### Money movement

- [ ] 3.9 Deposit $50 — wallet drops, account rises, statement gains a `DEPOSIT` row
- [ ] 3.10 Withdraw $50 — the reverse; net position back where it started
- [ ] 3.11 Deposit more than you carry → *"Insufficient funds"*, nothing moves
- [ ] 3.12 Transfer between two of your own accounts — **no fee**
- [ ] 3.13 Transfer to another player's account number — **1% wire fee**
- [ ] 3.14 `SELECT balance_money FROM sov_bank_accounts WHERE id=2` — insurance fund grew by exactly the fee
- [ ] 3.15 Statement paging and the category filter both work; count line is accurate

---

## 4. Accounts & shared access

- [ ] 4.1 Open a savings account — appears with the savings stamp
- [ ] 4.2 Open accounts up to `Config.MaxAccounts`; the next → `ERR_ACCOUNT_LIMIT`
- [ ] 4.3 Grant another character `withdraw` — it appears in *their* account list as **shared**
- [ ] 4.4 That character can withdraw but **cannot** grant access (`ERR_ACCESS`)
- [ ] 4.5 Grant `admin` — only the owner may do this
- [ ] 4.6 An admin cannot revoke another admin; the owner can
- [ ] 4.7 The owner row cannot be revoked by anyone, including the owner
- [ ] 4.8 Close an emptied account; closing a funded one → `ERR_NOT_EMPTY`
- [ ] 4.9 A closed account disappears from the list but its ledger rows remain

---

## 5. Bills — invoices, fines, taxes

Issue from the server console or another script:

```lua
exports.sov_bank:IssueInvoice('42', '77', 0, 12500, 'Cattle feed')
exports.sov_bank:IssueFine('77', 0, 5000, 'Disturbing the peace')
```

- [ ] 5.1 Bills appear at the teller with a red count badge on **Pay Bills / Taxes**
- [ ] 5.2 Invoice shows the issuing character's name; fine/tax shows *Sovereign County*
- [ ] 5.3 Pay in full from a bank account — bill closes, badge clears
- [ ] 5.4 Pay **partially** from the wallet — balance drops, bill stays open
- [ ] 5.5 Invoice proceeds land in the **issuer's** account
- [ ] 5.6 Fine/tax proceeds land in **SYS-GOV** (`SVB-0000001`)
- [ ] 5.7 Paying a closed bill → `ERR_BILL_CLOSED`
- [ ] 5.8 Paying someone else's bill → `ERR_ACCESS`

### Delinquency (needs time or hand-edited `due_at`)

Backdate a bill to force a tier, then wait for the sweep (≤15 min) or restart:

```sql
UPDATE sov_bank_bills SET due_at = NOW() - INTERVAL 20 DAY WHERE id = ?;
```

- [ ] 5.9 `pending` → `overdue`, late fee applied **exactly once** (re-run the sweep, confirm it doesn't stack)
- [ ] 5.10 `overdue` → `in_collections` after the threshold
- [ ] 5.11 A **fine/tax** past the arrestable threshold → `warrant`, fires `warrantFiled`
- [ ] 5.12 **An invoice NEVER reaches `warrant`** — backdate one 200 days and confirm it stays `in_collections`

> 5.12 is the hard rule of the whole debt design. If a private invoice ever
> produces a warrant, stop and report it.

---

## 6. Society & payroll

Needs a character holding a job in `Config.Societies` (today: medical).

- [ ] 6.1 A member sees the society rail; a jobless character does not
- [ ] 6.2 A member below `bossGrade` sees the balance but no controls
- [ ] 6.3 A boss can deposit and withdraw from the fund
- [ ] 6.4 Roster lists everyone holding the society's jobs
- [ ] 6.5 Payroll with two hands: society debited **once**, both hands' bank accounts credited
- [ ] 6.6 Payroll totalling more than the fund holds → refused, **nothing moves**
- [ ] 6.7 Payroll to an **offline** character still credits their account
- [ ] 6.8 `Reconcile` on the society account after payroll shows no drift

---

## 7. Loans

- [ ] 7.1 Apply for $500 — preview reads *"Borrow $500.00, owe $550.00"* at 10%
- [ ] 7.2 Application lands as `pending`; `sovbank loans` lists it
- [ ] 7.3 `sovbank loans approve <id>` — principal credited, status `active`, `due_by` set
- [ ] 7.4 Repay partially, then in full — status `paid`
- [ ] 7.5 Repayments land in **SYS-GOV**
- [ ] 7.6 A second application while one is open → `ERR_LOAN_LIMIT`
- [ ] 7.7 `sovbank loans deny <id>` on a fresh application → `denied`, nothing disbursed
- [ ] 7.8 Backdate `due_by` and wait for the sweep → `defaulted`, fires `loanDefaulted`

---

## 8. Savings interest

Force elapsed time rather than waiting a week:

```sql
UPDATE sov_bank_savings_accrual SET last_accrued_at = NOW() - INTERVAL 21 DAY
WHERE account_id = ?;
```

- [ ] 8.1 Visit the teller — interest posts as an `INTEREST` ledger row
- [ ] 8.2 Amount is capped at `catchUpCap` periods (default 4), not all 3 weeks
- [ ] 8.3 **Checking accounts never accrue** — only savings
- [ ] 8.4 Visit again immediately — **no second posting**
- [ ] 8.5 Backdate again and let the *scheduler* post it — same result, no double-post
- [ ] 8.6 `Reconcile` on the savings account shows no drift

> 8.4/8.5 test the lazy and sweep paths converging. Both compute the same
> idempotency key from the accrual base, so only one can ever land.

---

## 9. ⚠ HIGH RISK — Safety deposit boxes

**Your `vorp_inventory` is an escrow-encrypted, modified build with a
config-declared stash system (`config/stash.lua`), while this module registers
stashes at runtime.** The export names could not be verified from source. This
is the most likely first-boot failure in the resource.

- [ ] 9.1 Rent a small box — rent leaves the wallet, box appears
- [ ] 9.2 Rent lands in **SYS-INSURANCE**
- [ ] 9.3 **Open the box — a stash UI actually appears** ← the critical one
- [ ] 9.4 Put an item in, close, reopen — the item is still there
- [ ] 9.5 Restart the resource, reopen — contents survive (`registerAll` on boot)
- [ ] 9.6 Rent past `maxPerChar` → `ERR_SDB_LIMIT`
- [ ] 9.7 Backdate `rent_paid_until` past the grace period → box shows **rent due**, opening → `ERR_RENT_DUE`
- [ ] 9.8 Pay rent — box unlocks

**If 9.3 fails**, note the console error and check `bridge/vorp.lua`
(`RegisterStash` / `OpenStash`) against this build's actual API. Nothing else in
the resource depends on the inventory, so a failure here is contained.

---

## 10. Gold exchange

- [ ] 10.1 Quotes show buy above and sell below `Config.Gold.pricePerGold`
- [ ] 10.2 Buy 2.50 gold — dollars leave, gold arrives, figures match the quote
- [ ] 10.3 Sell it back — you lose exactly the spread, not more
- [ ] 10.4 Sell gold you don't have → `ERR_INSUFFICIENT_FUNDS`, nothing moves

---

## 11. Business accounts & Tax Ledger

No property purchase flow is wired yet, so register by hand:

```lua
exports.sov_bank:RegisterBusiness('valentine_gunsmith', '42', 200000, {
  name = 'Valentine Gunsmith' })
```

- [ ] 11.1 A business account is created and appears in the **owner's** list
- [ ] 11.2 **Business & Tax** rail shows basis $2,000 and a $500 fee per period
- [ ] 11.3 `exports.sov_bank:AssessBusinessTax('valentine_gunsmith')` → owed rises by $500
- [ ] 11.4 Assess again immediately → refused, **owed does not double**
- [ ] 11.5 Remit from the business account — owed drops, SYS-GOV rises
- [ ] 11.6 `Reconcile` on the business account shows **no drift** *(assessments are ledgered with `account_id NULL` precisely so this holds)*
- [ ] 11.7 Backdate `next_due_at`, run the sweep → a `tax` bill opens against the owner
- [ ] 11.8 A non-owner cannot see or remit for the business (`ERR_ACCESS`)

---

## 12. Collections & seizure

Needs a character holding the `tax_office` job. **Dormant until that job exists.**

- [ ] 12.1 A Tax Collector sees the **Collections Queue** rail; nobody else does
- [ ] 12.2 Queue lists tier-2 debts with days overdue
- [ ] 12.3 Claim a debt — it shows as held by you
- [ ] 12.4 Collect cash from a debtor — creditor paid, commission to the Tax Office fund
- [ ] 12.5 Partial collection leaves the bill open (payment plan)
- [ ] 12.6 Escalate a **fine/tax** → `warrant`, fires `warrantFiled`
- [ ] 12.7 **An invoice row has no Escalate control at all**, and the export → `ERR_CIVIL_DEBT`

### Seizure — the guardrails

- [ ] 12.8 `IsSeizureAuthorized(collector, debtorWithNoDebt)` → **false**
- [ ] 12.9 Same for a non-collector against a real debtor → **false**
- [ ] 12.10 `SeizeAssets` with no open tier-2 debt → `ERR_SEIZURE_DENIED`
- [ ] 12.11 Seize against a small debt — take is **capped to what is owed**
- [ ] 12.12 Exempt items are never taken
- [ ] 12.13 Surplus is banked back to the **debtor's** account
- [ ] 12.14 Items actually leave the debtor's inventory
- [ ] 12.15 A row lands in `sov_bank_seizures` with the itemized JSON
- [ ] 12.16 Shortfall leaves the bill open

> 12.8–12.10 are the gate. If a seizure ever succeeds without a verified debt,
> stop and report it — that path is the one place this resource authorizes force.

---

## 13. Heist reserve — the guarantee

**Before:** snapshot every balance.

```sql
SELECT SUM(balance_money) AS total FROM sov_bank_accounts;
```

```lua
exports.sov_bank:ClaimBranchReserve('valentine', 0, {
  fraction = 0.6, looters = { '42' } })
```

- [ ] 13.1 Returns `looted` and `remaining`; the looter's **wallet** grows
- [ ] 13.2 `sov_bank_reserves` for that branch drops by exactly `looted`
- [ ] 13.3 **The account total above is UNCHANGED** ← the guarantee
- [ ] 13.4 A `heist` ledger row exists with `account_id NULL`
- [ ] 13.5 Claim again on an emptied till → `ERR_INSUFFICIENT_FUNDS`
- [ ] 13.6 Backdate `last_refilled_at` past `replenishRealHrs` → the sweep refills to cap
- [ ] 13.7 Replay the same `idem` key → no second payout

> 13.3 is the promise the whole insurance-fund fiction rests on. Diff the totals
> before and after; they must match to the cent.

---

## 14. Admin panel

- [ ] 14.1 `/bankadmin` opens for an ACE holder
- [ ] 14.2 `/bankadmin` **refuses** a player without it
- [ ] 14.3 Money supply figures match the database
- [ ] 14.4 Account search finds by number, owner id, and name
- [ ] 14.5 Freeze an account — its owner can no longer withdraw (`ERR_FROZEN`)
- [ ] 14.6 Thaw restores access
- [ ] 14.7 Force adjust — balance moves **and** an `admin_adjust` row names you
- [ ] 14.8 Adjust beyond `Config.Admin.adjustMax` → refused
- [ ] 14.9 Reconcile reports zero drift across all accounts
- [ ] 14.10 Pending loans can be approved and denied from the panel
- [ ] 14.11 Branch till meters match `sov_bank_reserves`

---

## 15. Security

- [ ] 15.1 Open the teller, walk out of range, then act via the still-open UI → `ERR_NOT_AT_BRANCH`
- [ ] 15.2 Spam a teller action ~20× quickly → `ERR_RATE_LIMITED`, no double-apply
- [ ] 15.3 A client-fired `sov_bank:server:addMoney` from a hacked client does **nothing** *(inbound money events are `AddEventHandler` only, never net events)*
- [ ] 15.4 Acting on an account you have no access to → `ERR_ACCESS`
- [ ] 15.5 Negative and fractional amounts from the UI → `ERR_BAD_AMOUNT`

---

## 16. Integration — for the rest of the suite

- [ ] 16.1 Another resource can `exports.sov_bank:AddMoney(...)` and it ledgers with **that resource** named in `source_resource`
- [ ] 16.2 `RemoveMoney` fails cleanly (returns `false`) rather than throwing
- [ ] 16.3 An `idem` key makes a retried payout a no-op
- [ ] 16.4 `sov_bank:server:transactionCompleted` fires and can be listened to
- [ ] 16.5 A listener on `warrantFiled` receives government debt only

---

## Drift log

Record anything that surprised you. Reconciliation drift especially — it means
a balance and its ledger disagree, which should be impossible.

| Date | Entry | What happened | Error code | Resolved |
|------|-------|---------------|------------|----------|
|      |       |               |            |          |

---

## Sign-off

- [ ] Sections 1–4 pass — **safe to let players bank**
- [ ] Sections 5–8 pass — **safe to let other scripts issue debt and pay wages**
- [ ] Section 13 passes — **safe to enable heists**
- [ ] Section 12 passes — **safe to give anyone the Tax Collector job**

Tested by ­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­ on ­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­­
