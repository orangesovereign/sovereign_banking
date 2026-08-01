# Sovereign Bank — Testing Ledgers

Testing for `sovereign_banking` lives in the county's interactive ledger format, the same
as `sovereign_medical` and `sovereign_stables`. Open the HTML files directly in a
browser — each is self-contained, marks persist between visits, and the
**Build the Report** button at the foot produces a block to paste back to Claude.

| Ledger | Covers | Gate it closes |
|--------|--------|----------------|
| [B1 — Foundation](docs/testing/B1-FOUNDATION-LEDGER.html) | pre-flight, boot & schema, the `banking_test` money invariants, the counter, deposits & the wire, shared access, abuse pokes | **The counter may open to players** |
| [B2 — Commerce & Credit](docs/testing/B2-COMMERCE-LEDGER.html) | bills, settlement & routing, the delinquency ladder, society funds & payroll, loans, savings interest, gold, deposit boxes | **Other scripts may issue debt and pay wages** |
| [B3 — Enforcement & Ops](docs/testing/B3-ENFORCEMENT-LEDGER.html) | business tax ledger, collections queue, lawful seizure, the branch reserve guarantee, `/bankadmin`, the export contract, closing audit | **Heists may be enabled; the Tax Collector job may be handed out** |

159 items in all, 54 of them blockers — four of which are regression tests for
bugs a pre-boot audit turned up (see the notes on those items).

## How to work them

Run them in order — each assumes the one before is green. Work with the **server
console** and a **database window** open beside the game; every step carries a
chip saying whether it happens in game or at the console.

Mark each line **Pass**, **Fail** or **Skip**. On a failure, paste the `ERR_`
code into the note — every refusal in this resource returns a code, and the code
names the layer that refused. Then press **Build the Report** and send it back.

**Blockers** are marked in red. A failed blocker holds its gate shut; the report
lists them explicitly at the bottom so nothing slips through.

## Upgrading from the `sov_bank` naming

The resource, its events, and its tables were renamed to `sovereign_banking_*`
to match the rest of the county. If you booted an earlier build, the old tables
are still in the database holding nothing of value — drop them once:

```bash
mysql -u root -p -e "SET @s := (SELECT IFNULL(CONCAT('DROP TABLE ', GROUP_CONCAT(table_name)), 'SELECT 1') FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name LIKE 'sov\_bank\_%'); PREPARE d FROM @s; EXECUTE d;" your_database
```

## Before you start

Nothing in this resource has ever run against a live server. Everything to date
is syntax-checked and browser-tested against mock data, so treat all of it as
unproven until these ledgers say otherwise.

Three known soft spots, called out where they matter:

- **Deposit boxes (B2, Art. VIII)** — your `vorp_inventory` is an
  escrow-encrypted, modified build that declares stashes in config, while this
  module registers them at runtime. Its export names could not be verified from
  source. Nothing else depends on the inventory, so a failure there is contained.
- **Teller coordinates** — five of the six branches in `config/locations.lua`
  are placed from surveyed clerk marks. **Saint Denis is still an unwalked
  guess** — the two guesses since checked in game were 53m (Blackwater) and 7m
  (Rhodes) out, both far enough that no prompt could fire, so assume the same of
  it until proven. If no prompt appears at a counter, run `banking_peds` in F8
  and compare your position.
- **Job names** — only `medical` is live today. `lawman` and `tax_office` are
  placeholders, so the articles depending on them are skippable for now.

## Rebuilding a ledger

The ledgers are generated so all three stay identical in format. If entries need
changing, edit the entry list in
[`docs/testing/src/build_ledgers.py`](docs/testing/src/build_ledgers.py) and
regenerate rather than hand-patching the HTML — the embedded fonts make these
files unpleasant to edit directly.

```bash
python "docs/testing/src/build_ledgers.py"
```

`src/fonts.css` holds the three embedded faces (Cinzel, Baskerville, Fell)
lifted from the medical ledgers so every county ledger looks the same.
