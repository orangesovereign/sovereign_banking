# Builds the Sovereign Bank interactive testing ledgers in the county house
# format (matching sovereign_medical/docs/testing/*.html): dark 1896 sheet,
# Roman-numeral articles, pass/fail/skip with localStorage, blockers, and a
# Build-the-Report block to paste back.
import json, os, io

SCRATCH = os.path.dirname(os.path.abspath(__file__))
FONTS = open(os.path.join(SCRATCH, 'fonts.css'), encoding='utf-8').read()
OUT_DIR = r'F:\Sovereign County RP\sovereign_banking\docs\testing'

SHELL = r'''<meta charset="utf-8">
<title>__TITLE__</title>
<style>
__FONTS__

  :root {
    --ink: #131009; --panel: #1d1712; --panel-2: #221a13;
    --parchment: #e0d2b5; --parchment-dim: #9c8c6b;
    --brass: #a8834b; --brass-dim: #59461f;
    --red: #9c2b1d; --red-deep: #6a1b11; --green: #5d7a4a;
    --font-display: 'SC Cinzel', Georgia, serif;
    --font-body: 'SC Baskerville', Georgia, serif;
    --font-fell: 'SC Fell', Georgia, serif;
  }
  :root[data-theme="light"] { --ink: #131009; } /* dark-only by owner rule */

  * { box-sizing: border-box; }
  html { background: var(--ink); }
  body {
    margin: 0;
    background:
      url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='140' height='140'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.85' numOctaves='2' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)' opacity='0.05'/%3E%3C/svg%3E"),
      var(--ink);
    color: var(--parchment); font-family: var(--font-body); line-height: 1.55;
  }
  .sheet { max-width: 880px; margin: 0 auto; padding: 40px 22px 90px; }

  .masthead { text-align: center; border-bottom: 3px double var(--brass-dim); padding-bottom: 22px; margin-bottom: 8px; }
  .masthead .over { font-family: var(--font-fell); font-style: italic; color: var(--brass); font-size: 15px; }
  .masthead h1 { font-family: var(--font-display); font-weight: 700; text-wrap: balance; font-size: clamp(24px, 4.4vw, 38px); letter-spacing: 3px; margin: 10px 0 6px; color: var(--parchment); }
  .masthead .sub { color: var(--red); font-family: var(--font-display); letter-spacing: 4px; font-size: 13px; text-transform: uppercase; }
  .masthead .note { color: var(--parchment-dim); font-size: 13.5px; max-width: 68ch; margin: 14px auto 0; }
  .masthead .note em { font-family: var(--font-fell); color: var(--parchment); }

  .cast { display: flex; gap: 12px; justify-content: center; margin-top: 16px; flex-wrap: wrap; }
  .cast .who { border: 1px solid var(--brass-dim); background: var(--panel); padding: 7px 14px; font-size: 12.5px; }
  .cast .who b { font-family: var(--font-display); letter-spacing: 1px; }
  .cast .who.a b { color: var(--brass); } .cast .who.b b { color: var(--green); }

  .progress { position: sticky; top: 0; z-index: 5; background: var(--ink); padding: 10px 0 8px; border-bottom: 1px solid var(--brass-dim); margin-bottom: 26px; }
  .progress .row { display: flex; align-items: baseline; gap: 12px; }
  .progress .label { font-family: var(--font-display); font-size: 12px; letter-spacing: 2.5px; color: var(--brass); text-transform: uppercase; }
  .progress .count { font-variant-numeric: tabular-nums; color: var(--parchment); font-size: 14px; margin-left: auto; }
  .progress .tally { font-family: var(--font-display); letter-spacing: 1px; font-size: 11px; color: var(--parchment-dim); }
  .progress .tally b { font-weight: 400; }
  .progress .tally .p { color: var(--green); } .progress .tally .f { color: var(--red); } .progress .tally .s { color: var(--brass); }
  .bar { height: 5px; background: var(--panel-2); border: 1px solid var(--brass-dim); margin-top: 7px; }
  .bar > i { display: block; height: 100%; width: 0%; background: linear-gradient(90deg, var(--red-deep), var(--red)); transition: width .25s ease; }
  .verdict { display: none; margin-top: 8px; font-family: var(--font-fell); font-style: italic; color: var(--green); font-size: 15px; }
  .verdict.show { display: block; }

  section { margin-bottom: 34px; }
  .art { display: flex; align-items: baseline; gap: 14px; border-bottom: 1px solid var(--brass-dim); padding-bottom: 6px; margin-bottom: 4px; }
  .art .no { font-family: var(--font-display); color: var(--red); font-size: 13px; letter-spacing: 1px; white-space: nowrap; }
  .art h2 { font-family: var(--font-display); font-weight: 700; font-size: 18px; letter-spacing: 1.6px; margin: 0; color: var(--parchment); }
  .art .tag { margin-left: auto; font-size: 11px; letter-spacing: 2px; color: var(--brass); font-family: var(--font-display); white-space: nowrap; }
  .why { font-family: var(--font-fell); font-style: italic; color: var(--parchment-dim); font-size: 14px; margin: 6px 0 14px; }

  .item { background: var(--panel); border: 1px solid #2c2115; border-left: 3px solid var(--brass-dim); padding: 11px 12px; margin-bottom: 8px; }
  .item.pass { border-left-color: var(--green); }
  .item.fail { border-left-color: var(--red); }
  .item.skip { border-left-color: var(--parchment-dim); }
  .item__head { display: flex; align-items: flex-start; gap: 12px; }
  .item__id { font-family: var(--font-display); color: var(--red); font-size: 11px; letter-spacing: 1px; padding-top: 5px; min-width: 34px; }
  .item.skip .item__id { color: var(--parchment-dim); }
  .item__body { flex: 1; min-width: 0; }
  .item .t { font-size: 15.2px; }
  .item .x { color: var(--parchment-dim); font-size: 13.2px; margin-top: 3px; }
  .item .x b { color: var(--brass); font-weight: 400; letter-spacing: 0.6px; }
  .item.pass .t, .item.fail .t, .item.skip .t { color: var(--parchment-dim); }

  .item.gate { border-left-color: var(--red-deep); }
  .item.gate.pass { border-left-color: var(--green); }
  .item.gate.fail { border-left-color: var(--red); }
  .item .gatemark { font-family: var(--font-display); font-size: 9.5px; letter-spacing: 1.5px; color: var(--red); border: 1px solid var(--red-deep); padding: 1px 5px; margin-left: 8px; white-space: nowrap; }

  .who-chip { font-family: var(--font-display); font-size: 9.5px; letter-spacing: 1.5px; padding: 1px 6px; margin-left: 8px; white-space: nowrap; border: 1px solid var(--brass-dim); }
  .who-chip.a { color: #d7b072; } .who-chip.b { color: #9fc07e; } .who-chip.both { color: var(--parchment-dim); }

  .states { display: inline-flex; border: 1px solid var(--brass-dim); flex: 0 0 auto; }
  .states button { font-family: var(--font-display); font-size: 10.5px; letter-spacing: 1.5px; text-transform: uppercase; color: var(--parchment-dim); background: var(--panel-2); border: none; border-left: 1px solid var(--brass-dim); padding: 6px 12px; cursor: pointer; transition: background .12s, color .12s; }
  .states button:first-child { border-left: none; }
  .states button:hover { color: var(--parchment); }
  .states button:focus-visible { outline: 2px solid var(--brass); outline-offset: 2px; }
  .states button[aria-pressed="true"][data-v="pass"] { background: var(--green); color: #10160b; }
  .states button[aria-pressed="true"][data-v="fail"] { background: var(--red); color: var(--parchment); }
  .states button[aria-pressed="true"][data-v="skip"] { background: var(--brass-dim); color: var(--parchment); }

  .note { display: block; width: 100%; margin-top: 10px; resize: vertical; min-height: 32px; font-family: var(--font-body); font-size: 13.5px; color: var(--parchment); background: #241b11; border: 1px solid #33271a; padding: 7px 10px; }
  .note::placeholder { color: var(--brass-dim); font-family: var(--font-fell); font-style: italic; }
  .note:focus-visible { outline: 2px solid var(--brass); outline-offset: 1px; }
  code { font-family: Consolas, monospace; font-size: 0.88em; color: #cdbb92; background: #241b11; padding: 1px 5px; border: 1px solid #33271a; border-radius: 2px; }
  pre.sql { font-family: Consolas, monospace; font-size: 12px; color: #cdbb92; background: #241b11; border: 1px solid #33271a; padding: 8px 10px; margin: 7px 0 0; overflow-x: auto; white-space: pre; }

  .report__actions { display: flex; gap: 10px; flex-wrap: wrap; margin: 12px 0; }
  .ledger-btn { font-family: var(--font-display); letter-spacing: 2px; text-transform: uppercase; font-size: 11px; color: var(--parchment); background: linear-gradient(180deg, var(--red), var(--red-deep)); border: 1px solid var(--red-deep); padding: 9px 18px; cursor: pointer; }
  .ledger-btn:hover { filter: brightness(1.12); }
  .ledger-btn:focus-visible { outline: 2px solid var(--brass); outline-offset: 2px; }
  .ledger-btn.ghost { background: none; color: var(--brass); border-color: var(--brass-dim); }
  .ledger-btn.ghost:hover { color: var(--parchment); border-color: var(--brass); }
  #report-out { width: 100%; min-height: 200px; resize: vertical; margin-top: 4px; font-family: Consolas, monospace; font-size: 12.5px; line-height: 1.6; color: #cdbb92; background: #241b11; border: 1px solid #33271a; padding: 12px; white-space: pre; overflow-x: auto; }
  #report-out:focus-visible { outline: 2px solid var(--brass); outline-offset: 1px; }

  footer { border-top: 3px double var(--brass-dim); margin-top: 44px; padding-top: 14px; display: flex; gap: 16px; flex-wrap: wrap; justify-content: space-between; color: var(--parchment-dim); font-size: 12px; letter-spacing: 1px; }
  footer .motto { font-family: var(--font-display); color: var(--brass); letter-spacing: 3px; }
  button.reset { font-family: var(--font-display); letter-spacing: 2px; font-size: 11px; background: none; border: 1px solid var(--brass-dim); color: var(--parchment-dim); padding: 5px 12px; cursor: pointer; }
  button.reset:hover { color: var(--parchment); border-color: var(--brass); }
  button.reset.armed { color: #e0d2b5; border-color: #9c2b1d; background: #6a1b11; }
  @media (prefers-reduced-motion: reduce) { .bar > i, .states button { transition: none; } }
</style>
<div class="sheet">
  <header class="masthead">
    <div class="over">~ Sovereign County Bank &mdash; Office of the Comptroller ~</div>
    <h1>__H1__</h1>
    <div class="sub">__SUB__</div>
    <p class="note">__NOTE__</p>
    <div class="cast">
      <div class="who a"><b>IN GAME</b> &mdash; your character, at a bank counter</div>
      <div class="who b"><b>CONSOLE</b> &mdash; the server console and a database window</div>
    </div>
  </header>

  <div class="progress">
    <div class="row">
      <span class="label">__PROGLABEL__</span>
      <span class="tally" id="tally"></span>
      <span class="count"><span id="done">0</span> of <span id="total">0</span> recorded</span>
    </div>
    <div class="bar"><i id="fill"></i></div>
    <div class="verdict" id="verdict">__VERDICT__</div>
  </div>

  <div id="articles"></div>

  <section id="report">
    <div class="art"><span class="no">&#9998;</span><h2>Build the Report</h2><span class="tag">for Claude</span></div>
    <p class="why">Gathers every mark and note into one block &mdash; the record to paste back so the gate can be ruled.</p>
    <div class="report__actions">
      <button class="ledger-btn" id="gen" type="button">Build the Report</button>
      <button class="ledger-btn ghost" id="copy" type="button">Copy to clipboard</button>
    </div>
    <textarea id="report-out" readonly placeholder="Your results appear here once you press Build the Report."></textarea>
  </section>

  <footer>
    <span>SOVEREIGN BANK &mdash; OFFICIAL USE ONLY</span>
    <span class="motto">IN SERVICE TO PROSPERITY</span>
    <button class="reset" id="reset" type="button">Clear all marks</button>
  </footer>
</div>

<script>
  const LEDGER = __LEDGER__;
  const KEY = '__KEY__';
  const REPORT_TITLE = '__REPORT_TITLE__';
  const GATE_NOTE = '__GATE_NOTE__';

  let state = {};
  try { state = JSON.parse(localStorage.getItem(KEY)) || {}; } catch (e) { state = {}; }
  const save = () => { try { localStorage.setItem(KEY, JSON.stringify(state)); } catch (e) {} };

  const allItems = LEDGER.flatMap(a => a.items);
  const artsEl = document.getElementById('articles');
  const WHO_LABEL = { a: 'IN GAME', b: 'CONSOLE', both: 'BOTH' };

  LEDGER.forEach(a => {
    const sec = document.createElement('section');
    const head = document.createElement('div');
    head.className = 'art';
    head.innerHTML = '<span class="no">ART. ' + a.art + '</span><h2>' + a.title + '</h2><span class="tag">' + a.tag + '</span>';
    sec.appendChild(head);
    if (a.why) { const w = document.createElement('p'); w.className = 'why'; w.textContent = a.why; sec.appendChild(w); }

    a.items.forEach(it => {
      const st = state[it.id] || {};
      const el = document.createElement('div');
      el.className = 'item' + (it.gate ? ' gate' : '') + (st.v ? ' ' + st.v : '');
      el.dataset.id = it.id;

      const whoChip = it.who ? '<span class="who-chip ' + it.who + '">' + WHO_LABEL[it.who] + '</span>' : '';
      const headRow = document.createElement('div');
      headRow.className = 'item__head';
      headRow.innerHTML =
        '<span class="item__id">' + it.id + '</span>' +
        '<span class="item__body"><span class="t">' + it.t + whoChip +
        (it.gate ? '<span class="gatemark">BLOCKER</span>' : '') +
        '</span><span class="x">' + it.x + '</span></span>';

      const states = document.createElement('div');
      states.className = 'states';
      ['pass', 'fail', 'skip'].forEach(v => {
        const b = document.createElement('button');
        b.type = 'button'; b.dataset.v = v; b.textContent = v;
        b.setAttribute('aria-pressed', String(st.v === v));
        b.addEventListener('click', () => {
          state[it.id] = state[it.id] || {};
          state[it.id].v = (state[it.id].v === v) ? null : v;
          states.querySelectorAll('button').forEach(x => x.setAttribute('aria-pressed', String(x.dataset.v === state[it.id].v)));
          el.classList.remove('pass', 'fail', 'skip');
          if (state[it.id].v) el.classList.add(state[it.id].v);
          save(); paint();
        });
        states.appendChild(b);
      });
      headRow.appendChild(states);
      el.appendChild(headRow);

      const note = document.createElement('textarea');
      note.className = 'note'; note.rows = 1; note.placeholder = 'Notes (optional) — paste the error code on a failure';
      note.value = st.note || '';
      note.addEventListener('input', () => { state[it.id] = state[it.id] || {}; state[it.id].note = note.value; save(); });
      el.appendChild(note);

      sec.appendChild(el);
    });
    artsEl.appendChild(sec);
  });

  const doneEl = document.getElementById('done'), totalEl = document.getElementById('total');
  const fill = document.getElementById('fill'), verdict = document.getElementById('verdict'), tallyEl = document.getElementById('tally');
  totalEl.textContent = allItems.length;

  function counts() {
    let p = 0, f = 0, s = 0;
    allItems.forEach(it => { const v = (state[it.id] || {}).v; if (v === 'pass') p++; else if (v === 'fail') f++; else if (v === 'skip') s++; });
    return { p, f, s, done: p + f + s };
  }
  function paint() {
    const c = counts();
    doneEl.textContent = c.done;
    fill.style.width = (c.done / allItems.length * 100) + '%';
    tallyEl.innerHTML = '<b class="p">' + c.p + ' pass</b> &middot; <b class="f">' + c.f + ' fail</b> &middot; <b class="s">' + c.s + ' skip</b>';
    verdict.classList.toggle('show', c.done === allItems.length);
  }
  paint();

  const MARK = { pass: '[PASS]', fail: '[FAIL]', skip: '[skip]' };
  const stripHTML = html => { const d = document.createElement('div'); d.innerHTML = html; return (d.textContent || '').replace(/\s+/g, ' ').trim(); };

  function buildReport() {
    const lines = [];
    lines.push(REPORT_TITLE);
    lines.push('Date: ' + new Date().toISOString().slice(0, 10));
    lines.push('Tester charid: ______');
    LEDGER.forEach(a => {
      lines.push('');
      lines.push('ART. ' + a.art + ' — ' + stripHTML(a.title));
      a.items.forEach(it => {
        const st = state[it.id] || {};
        const mark = st.v ? MARK[st.v] : '[ -- ]';
        const who = it.who ? '(' + WHO_LABEL[it.who] + ') ' : '';
        lines.push('  ' + mark + ' ' + it.id + (it.gate ? ' (blocker)' : '') + '  ' + who + stripHTML(it.t));
        if (st.note && st.note.trim()) lines.push('         note: ' + st.note.trim());
      });
    });
    const c = counts();
    lines.push('');
    lines.push('Summary: ' + c.p + ' pass · ' + c.f + ' fail · ' + c.s + ' skip · ' + allItems.length + ' total');
    const brokenGates = allItems.filter(it => it.gate && (state[it.id] || {}).v === 'fail');
    if (brokenGates.length) {
      lines.push('BLOCKERS FAILED: ' + brokenGates.map(it => it.id).join(', ') + ' — ' + GATE_NOTE);
    }
    return lines.join('\n');
  }

  document.getElementById('gen').addEventListener('click', () => {
    document.getElementById('report-out').value = buildReport();
  });
  document.getElementById('copy').addEventListener('click', () => {
    const out = document.getElementById('report-out');
    if (!out.value) out.value = buildReport();
    out.select();
    if (navigator.clipboard) navigator.clipboard.writeText(out.value).catch(() => {});
    const b = document.getElementById('copy'), t = b.textContent;
    b.textContent = 'Copied'; setTimeout(() => b.textContent = t, 1200);
  });

  let armTimer = null;
  const resetBtn = document.getElementById('reset');
  resetBtn.addEventListener('click', () => {
    if (!resetBtn.classList.contains('armed')) {
      resetBtn.classList.add('armed');
      resetBtn.textContent = 'Click again to clear';
      clearTimeout(armTimer);
      armTimer = setTimeout(() => { resetBtn.classList.remove('armed'); resetBtn.textContent = 'Clear all marks'; }, 4000);
      return;
    }
    clearTimeout(armTimer);
    resetBtn.classList.remove('armed'); resetBtn.textContent = 'Clear all marks';
    state = {}; save();
    document.querySelectorAll('.item').forEach(el => el.classList.remove('pass', 'fail', 'skip'));
    document.querySelectorAll('.states button').forEach(b => b.setAttribute('aria-pressed', 'false'));
    document.querySelectorAll('.note').forEach(n => n.value = '');
    document.getElementById('report-out').value = '';
    paint();
  });
</script>
'''


def build(fname, title, h1, sub, note, proglabel, verdict, key, report_title, gate_note, ledger):
    html = (SHELL
            .replace('__FONTS__', FONTS)
            .replace('__TITLE__', title)
            .replace('__H1__', h1)
            .replace('__SUB__', sub)
            .replace('__NOTE__', note)
            .replace('__PROGLABEL__', proglabel)
            .replace('__VERDICT__', verdict)
            .replace('__KEY__', key)
            .replace('__REPORT_TITLE__', report_title)
            .replace('__GATE_NOTE__', gate_note)
            .replace('__LEDGER__', json.dumps(ledger, indent=4, ensure_ascii=False)))
    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, fname)
    with io.open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(html)
    n = sum(len(a['items']) for a in ledger)
    print('%-34s %3d items  %6.1f KB' % (fname, n, len(html) / 1024))


# ===========================================================================
# B1 — FOUNDATION & TELLER
# ===========================================================================
B1 = [
 {"art": "I", "title": "Before the Doors Open", "tag": "pre-flight", "why":
  "Nothing below means anything if the resource is loaded wrong or pointed at the wrong jobs.",
  "items": [
   {"id": "P1", "who": "b", "t": "Confirm <code>vorp_core</code>, <code>oxmysql</code> and <code>vorp_inventory</code> all start <b>before</b> <code>sovereign_banking</code> in your cfg.", "x": "<b>Expect:</b> sovereign_banking appears after all three in the start order."},
   {"id": "P2", "who": "b", "gate": True, "t": "Confirm the resource folder is named exactly <code>sovereign_banking</code> &mdash; not <code>sovereign_banking</code>.", "x": "<b>Expect:</b> the folder name matches, or every <code>exports.sovereign_banking:&hellip;</code> call from other scripts will fail to resolve."},
   {"id": "P3", "who": "b", "t": "Open <code>config/config.lua</code> and check <code>Config.Societies</code> job names against your real VORP jobs.", "x": "<b>Expect:</b> today only <code>medical</code> is live; <code>lawman</code> and <code>tax_office</code> are placeholders. A society whose jobs nobody holds simply lies dormant &mdash; that is fine."},
   {"id": "P4", "who": "b", "t": "Add <code>add_ace group.admin banking.admin allow</code> to <code>server.cfg</code> and reload it.", "x": "<b>Expect:</b> no error. This is what lets you open <code>/bankadmin</code> later."},
   {"id": "P5", "who": "b", "gate": True, "t": "Take a database backup.", "x": "<b>Expect:</b> a restorable dump. First boot writes schema, alters an AUTO_INCREMENT, and seeds accounts."},
 ]},
 {"art": "II", "title": "The Fresh Deploy", "tag": "boot &middot; schema &middot; seeding", "why":
  "First contact. The schema installs itself and the county's standing accounts are struck.",
  "items": [
   {"id": "S1", "who": "b", "gate": True, "t": "Start the resource and watch the console.", "x": "<b>Expect:</b> <code>Sovereign Bank v0.6.0 ready</code>, and <b>no red lines</b> mentioning sovereign_banking."},
   {"id": "S2", "who": "b", "t": "In the database: <code>SHOW TABLES LIKE 'sovereign_banking_%';</code>", "x": "<b>Expect:</b> 11 tables &mdash; accounts, access, transactions, loans, savings_accrual, sdb, bills, business_tax, seizures, liens, reserves (plus meta)."},
   {"id": "S3", "who": "b", "gate": True, "t": "Check the standing accounts:<pre class=\"sql\">SELECT id, account_number, owner_id FROM sovereign_banking_accounts\nWHERE owner_type='system';</pre>", "x": "<b>Expect:</b> exactly two rows &mdash; <code>1 / SVB-0000001 / SYS-GOV</code> and <code>2 / SVB-0000002 / SYS-INSURANCE</code>."},
   {"id": "S4", "who": "b", "t": "Same for societies: <code>&hellip; WHERE owner_type='society';</code>", "x": "<b>Expect:</b> <code>lawman</code> at &#8470;10, <code>medical</code> at &#8470;11, <code>tax_office</code> at &#8470;12 &mdash; all inside the reserved 1&ndash;1000 range."},
   {"id": "S5", "who": "b", "t": "<code>SELECT * FROM sovereign_banking_reserves;</code>", "x": "<b>Expect:</b> one row per configured branch, each with <code>balance = cap</code>."},
   {"id": "S6", "who": "b", "gate": True, "t": "Log a character in, then run <code>banking account &lt;charid&gt;</code> in the console.", "x": "<b>Expect:</b> an account row whose number is <code>SVB-0001001</code> or higher. <b>If it is numbered below 1001</b>, the reserved-range ALTER did not apply &mdash; look for a SQL permission error at boot."},
   {"id": "S7", "who": "b", "t": "Restart the resource twice more.", "x": "<b>Expect:</b> no duplicate accounts, no duplicate reserves, no errors. Every seeding step is idempotent by design."},
 ]},
 {"art": "III", "title": "The Money Invariants", "tag": "banking_test &middot; automated", "why":
  "The suite proves the promises the whole bank rests on: money is conserved, nothing double-applies, and no race can overdraw an account.",
  "items": [
   {"id": "M1", "who": "b", "gate": True, "t": "With a player online, run in the <b>server console</b>: <code>banking_test &lt;theirServerId&gt;</code>", "x": "<b>Expect:</b> a run of green PASS lines ending <code>suite done: N passed, 0 failed</code>. It creates throwaway accounts and deletes everything it made."},
   {"id": "M2", "who": "b", "t": "Read the numbering lines in the output.", "x": "<b>Expect:</b> player accounts numbered outside the reserved range; gov holds SVB-0000001; insurance holds SVB-0000002."},
   {"id": "M3", "who": "b", "t": "Read the guardrail lines.", "x": "<b>Expect:</b> overdraw refused with <code>ERR_INSUFFICIENT_FUNDS</code> and <b>no state change</b>; fuzzed amounts (negative, zero, float, huge, string) all <code>ERR_BAD_AMOUNT</code>; unknown currency <code>ERR_BAD_CURRENCY</code>."},
   {"id": "M4", "who": "b", "gate": True, "t": "Read the idempotency lines.", "x": "<b>Expect:</b> replaying a <code>tx_uuid</code> returns the original result and applies <b>once</b> &mdash; for both a credit and a transfer."},
   {"id": "M5", "who": "b", "gate": True, "t": "Read the conservation line.", "x": "<b>Expect:</b> source + destination + insurance sums to the same total before and after a fee-bearing transfer. Nothing is created or lost."},
   {"id": "M6", "who": "b", "gate": True, "t": "Read the concurrency line.", "x": "<b>Expect:</b> ten racing transfers, and only the affordable number succeed. The account never goes below zero."},
   {"id": "M7", "who": "b", "gate": True, "t": "Read the reconciliation line.", "x": "<b>Expect:</b> ledger sum equals stored balance for every account the suite touched."},
   {"id": "M8", "who": "b", "t": "Read the wallet round-trip line (only runs if you passed a server id).", "x": "<b>Expect:</b> credit &rarr; deposit &rarr; withdraw &rarr; debit leaves both the wallet and the account exactly where they started."},
   {"id": "M9", "who": "b", "t": "<i>Optional, destructive &mdash; dev server only.</i> Stop <code>vorp_core</code> mid-deposit to force the wallet leg to fail.", "x": "<b>Expect:</b> the op returns <code>ERR_WALLET_APPLY</code>, the committed bank leg reverses, and a <code>compensation</code> row appears in the ledger. Net change: zero."},
 ]},
 {"art": "IV", "title": "At the Counter", "tag": "branches &middot; peds &middot; NUI", "why":
  "Banking is a place you ride to. The teller has to actually be there, and the coordinates shipped are approximations.",
  "items": [
   {"id": "T1", "who": "a", "t": "Open the map.", "x": "<b>Expect:</b> six bank blips &mdash; Valentine, Rhodes, Saint Denis, Blackwater, Tumbleweed and Armadillo."},
   {"id": "T2", "who": "a", "t": "Ride to a branch and look at the counter.", "x": "<b>Expect:</b> a teller ped standing there, <b>visible and clothed</b>. A T-pose or an invisible ped means the outfit native failed."},
   {"id": "T2b", "who": "a", "t": "Run <code>banking_peds</code> in F8 while standing at the counter.", "x": "<b>Expect:</b> the branch reports <code>ped=yes</code> and <b>off mark under 0.5m</b>. Every branch but Saint Denis is placed from a surveyed mark and should read near zero. <b>Saint Denis is unproven</b> &mdash; the two guesses since checked were 53m and 7m out, so expect the same of it until walked."},
   {"id": "T3", "who": "a", "gate": True, "t": "Stand at the counter and hold <b>[G]</b>.", "x": "<b>Expect:</b> the prompt appears, and holding it opens the bank. <b>If no prompt appears</b>, compare your coords to <code>teller</code> in <code>config/locations.lua</code> &mdash; Valentine's is surveyed, the rest are derived from surveyed clerk marks, and <b>Saint Denis is still an unwalked guess</b>."},
   {"id": "T4", "who": "a", "t": "Look over the dashboard.", "x": "<b>Expect:</b> accounts down the left, the transaction ledger centre, bank actions right, and the dark quick-action bar along the bottom."},
   {"id": "T5", "who": "a", "t": "Read the branch card, lower right.", "x": "<b>Expect:</b> the name, subtitle and opening hours match this branch's entry in <code>config/locations.lua</code>."},
   {"id": "T6", "who": "a", "t": "Read any dated line in the ledger.", "x": "<b>Expect:</b> the year reads <b>1896</b>, not 2026. Dates render at real year minus 130."},
   {"id": "T7", "who": "a", "t": "Walk away from the counter with the bank open.", "x": "<b>Expect:</b> the UI closes on its own."},
   {"id": "T8", "who": "a", "t": "Reopen, open any modal, then press <b>ESC</b> twice.", "x": "<b>Expect:</b> the first press closes the modal, the second closes the bank. Mouse control returns to the game."},
 ]},
 {"art": "V", "title": "Deposits, Withdrawals &amp; the Wire", "tag": "the core loop", "why":
  "The everyday business of the bank &mdash; and the fee that funds the insurance the whole robbery model rests on.",
  "items": [
   {"id": "D1", "who": "a", "gate": True, "t": "Deposit $50.", "x": "<b>Expect:</b> cash in hand falls by $50, the account rises by $50, and a <code>DEPOSIT</code> line appears in the ledger with a running balance."},
   {"id": "D2", "who": "a", "gate": True, "t": "Withdraw the same $50.", "x": "<b>Expect:</b> the exact reverse. Your net position is back where it started, and both movements are in the ledger."},
   {"id": "D3", "who": "a", "t": "Try to deposit more than you are carrying.", "x": "<b>Expect:</b> <em>&ldquo;Insufficient funds.&rdquo;</em> Nothing moves on either side."},
   {"id": "D4", "who": "a", "t": "Open a second account, then transfer $20 between two accounts <b>you own</b>.", "x": "<b>Expect:</b> <b>no fee</b> &mdash; own-account moves are free by default."},
   {"id": "D5", "who": "a", "t": "Transfer $100 to another character's account number (Wire &amp; Pay).", "x": "<b>Expect:</b> a <b>1% wire fee</b> ($1.00) on top, quoted before you send."},
   {"id": "D6", "who": "b", "gate": True, "t": "After D5: <code>SELECT balance_money FROM sovereign_banking_accounts WHERE id=2;</code>", "x": "<b>Expect:</b> the insurance fund grew by <b>exactly the fee</b>. This is the money that pays for deposits being robbery-proof."},
   {"id": "D7", "who": "a", "t": "Page through the statement and change the type filter.", "x": "<b>Expect:</b> paging works both directions, the filter narrows the rows, and the <em>&ldquo;Showing X to Y of N&rdquo;</em> line is accurate."},
   {"id": "D8", "who": "a", "t": "Check the colours in the TYPE column.", "x": "<b>Expect:</b> credits green, debits red, system entries blue &mdash; the period convention of red ink for what leaves."},
 ]},
 {"art": "VI", "title": "Accounts &amp; Shared Access", "tag": "hierarchy &middot; owner is untouchable", "why":
  "Shared accounts are how gangs, families and businesses hold money together &mdash; and the access ladder must not be climbable from below.",
  "items": [
   {"id": "A1", "who": "a", "t": "Open a savings account from the New Account desk.", "x": "<b>Expect:</b> it appears with the savings stamp and a piggy-bank engraving."},
   {"id": "A2", "who": "a", "t": "Keep opening accounts past <code>Config.MaxAccounts</code> (default 4).", "x": "<b>Expect:</b> the button greys out and the export path returns <code>ERR_ACCOUNT_LIMIT</code>."},
   {"id": "A3", "who": "both", "gate": True, "t": "Grant a second character <b>withdraw</b> on one of your accounts.", "x": "<b>Expect:</b> it appears in <i>their</i> account list marked <b>shared</b>, and they can withdraw from it."},
   {"id": "A4", "who": "both", "gate": True, "t": "As that second character, try to grant someone else access.", "x": "<b>Expect:</b> refused &mdash; <code>ERR_ACCESS</code>. Withdraw rights are not management rights."},
   {"id": "A5", "who": "a", "t": "As the owner, grant that character <b>admin</b>. Then as an <i>admin</i> (not owner), try to grant admin to a third party.", "x": "<b>Expect:</b> only the owner may appoint admins. The admin's attempt is refused."},
   {"id": "A6", "who": "a", "gate": True, "t": "Try to revoke the <b>owner</b> row &mdash; as an admin, and as the owner themselves.", "x": "<b>Expect:</b> refused both times. The owner row is untouchable by anyone."},
   {"id": "A7", "who": "a", "t": "Empty an account, then close it. Then try to close a funded one.", "x": "<b>Expect:</b> the empty one closes; the funded one refuses with <code>ERR_NOT_EMPTY</code>."},
   {"id": "A8", "who": "b", "t": "After closing: check the ledger rows for that account id.", "x": "<b>Expect:</b> the account is gone from the list but <b>its history remains</b> in <code>sovereign_banking_transactions</code>. The ledger is append-only."},
 ]},
 {"art": "VII", "title": "Rough Hands", "tag": "server-authority &middot; abuse pokes", "why":
  "The client asks; the server decides. A bank that only survives polite use is not a bank.",
  "items": [
   {"id": "X1", "who": "a", "gate": True, "t": "Open the teller, walk well out of range without closing it, then try to withdraw.", "x": "<b>Expect:</b> refused &mdash; <code>ERR_NOT_AT_BRANCH</code>. The server re-checks your real position on every single request."},
   {"id": "X2", "who": "a", "t": "Spam a teller action twenty times as fast as you can click.", "x": "<b>Expect:</b> <code>ERR_RATE_LIMITED</code> kicks in, and <b>nothing double-applies</b>. Check the ledger for duplicate rows."},
   {"id": "X3", "who": "a", "t": "Type letters, a negative number, and <code>1.5</code> into an amount field and submit each.", "x": "<b>Expect:</b> <code>ERR_BAD_AMOUNT</code> every time. No state change."},
   {"id": "X4", "who": "b", "t": "Confirm inbound money events are not client-triggerable: grep <code>server/api/events.lua</code> for <code>RegisterNetEvent</code>.", "x": "<b>Expect:</b> <b>none</b> on the money handlers &mdash; they are <code>AddEventHandler</code> only, so a hacked client cannot fire them."},
   {"id": "X5", "who": "both", "t": "As a character with no access, try to act on someone else's account id.", "x": "<b>Expect:</b> <code>ERR_ACCESS</code>. Identity comes from the connection, never from what the client sends."},
 ]},
]

build('B1-FOUNDATION-LEDGER.html',
      'B1 Foundation Ledger — Sovereign Bank',
      'B1 FOUNDATION LEDGER',
      'Boot, the money engine &amp; the counter — sovereign_banking v0.6.0',
      "The first gate: the vault under everything else. Nothing in this resource has ever run against a live server &mdash; every line to date is syntax-checked and browser-tested against mock data, so treat all of it as unproven. Work with the <em>server console</em> and a <em>database window</em> open beside the game; each step's chip says where it happens. Mark every line <em>Pass</em>, <em>Fail</em> or <em>Skip</em>, note the <code>ERR_</code> code on any failure, then press <em>Build the Report</em> and paste it back. Marks persist between visits.",
      'B1 Progress',
      'Every line recorded. Press <b>Build the Report</b> and paste it back. If the blockers are green, the counter is safe to open to players and B2 — commerce and credit — begins.',
      'banking-b1-foundation',
      'SOVEREIGN BANK — B1 Foundation Ledger — Results',
      'the counter stays shut to players until these pass.',
      B1)


# ===========================================================================
# B2 — COMMERCE & CREDIT
# ===========================================================================
B2 = [
 {"art": "I", "title": "Bills Issued", "tag": "invoice &middot; fine &middot; tax", "why":
  "The rails the rest of the suite bills on. An invoice is civil; a fine or tax is the government's.",
  "items": [
   {"id": "B1", "who": "b", "t": "From the console or another resource:<pre class=\"sql\">exports.sovereign_banking:IssueInvoice('42', '77', 0, 12500, 'Cattle feed')</pre>", "x": "<b>Expect:</b> returns ok with a bill id, and a row in <code>sovereign_banking_bills</code> with <code>kind='invoice'</code>, status <code>pending</code>."},
   {"id": "B2", "who": "b", "t": "Now a government debt:<pre class=\"sql\">exports.sovereign_banking:IssueFine('77', 0, 5000, 'Disturbing the peace')</pre>", "x": "<b>Expect:</b> a bill with <code>kind='fine'</code>, <code>issuer_type='system'</code>."},
   {"id": "B3", "who": "a", "t": "As the billed character, visit a teller.", "x": "<b>Expect:</b> a red count badge on <b>Pay Bills / Taxes</b> showing how many are open."},
   {"id": "B4", "who": "a", "t": "Open the bills list and read the issuers.", "x": "<b>Expect:</b> the invoice names the issuing <b>character</b>; the fine reads <em>Sovereign County</em>. Due dates render in 1896."},
   {"id": "B5", "who": "b", "t": "Fire the same IssueFine call twice with the same <code>idem</code> key in opts.", "x": "<b>Expect:</b> the second returns the <b>original</b> bill id with <code>replayed=true</code> &mdash; not a second debt. A double-fired citation cannot double-bill."},
 ]},
 {"art": "II", "title": "Settling at the Counter", "tag": "partial payment &middot; routing", "why":
  "Where the money actually goes matters: a private debt pays its issuer, a government debt pays the county.",
  "items": [
   {"id": "C1", "who": "a", "gate": True, "t": "Pay the invoice in full from a bank account.", "x": "<b>Expect:</b> the bill closes, the badge count drops, and the money leaves your account."},
   {"id": "C2", "who": "b", "gate": True, "t": "Check where it landed &mdash; the issuing character's primary account.", "x": "<b>Expect:</b> the <b>issuer</b> was credited the full amount. An invoice is a debt between people, not revenue for the county."},
   {"id": "C3", "who": "a", "t": "Pay <b>part</b> of the fine from cash in hand.", "x": "<b>Expect:</b> the remaining balance drops but the bill <b>stays open</b>. Partial payment is the payment-plan mechanism."},
   {"id": "C4", "who": "b", "gate": True, "t": "Check <code>SVB-0000001</code> (SYS-GOV) after paying the fine.", "x": "<b>Expect:</b> the government fund grew by what you paid. Fines and taxes are county revenue."},
   {"id": "C5", "who": "a", "t": "Try to pay the already-settled invoice again.", "x": "<b>Expect:</b> <code>ERR_BILL_CLOSED</code>."},
   {"id": "C6", "who": "both", "t": "Try to pay a bill that belongs to a different character.", "x": "<b>Expect:</b> <code>ERR_ACCESS</code>. You may only settle your own debts."},
 ]},
 {"art": "III", "title": "The Delinquency Ladder", "tag": "tiers 0&ndash;3 &middot; the hard rule", "why":
  "The bank runs the whole life of an unpaid debt, and lawmen are the last rung — never the first.",
  "items": [
   {"id": "L1", "who": "b", "t": "Backdate a fine and let the sweep run (&le;15 min) or restart the resource:<pre class=\"sql\">UPDATE sovereign_banking_bills SET due_at = NOW() - INTERVAL 5 DAY WHERE id = ?;</pre>", "x": "<b>Expect:</b> status moves <code>pending</code> &rarr; <code>overdue</code>, and a late fee is added to <code>balance_remaining</code>."},
   {"id": "L2", "who": "b", "gate": True, "t": "Let the sweep run a <b>second</b> time on that same overdue bill.", "x": "<b>Expect:</b> the late fee is <b>not</b> applied again. It lands exactly once, at the transition."},
   {"id": "L3", "who": "b", "t": "Backdate further (past overdue + collections days) and sweep again.", "x": "<b>Expect:</b> status moves to <code>in_collections</code> &mdash; the Tax Collector's queue."},
   {"id": "L4", "who": "b", "t": "Backdate a <b>fine</b> 20+ days with a balance over the arrestable threshold, then sweep.", "x": "<b>Expect:</b> status becomes <code>warrant</code> and the resource fires <code>sovereign_banking:server:warrantFiled</code>."},
   {"id": "L5", "who": "b", "gate": True, "t": "Now backdate a <b>private invoice</b> 200 days with a large balance and sweep repeatedly.", "x": "<b>Expect:</b> it reaches <code>in_collections</code> and <b>stops there, forever</b>. It must never become a warrant. <i>This is the hard rule of the whole debt design &mdash; if an invoice ever produces a warrant, stop and report it.</i>"},
   {"id": "L6", "who": "a", "t": "Pay off a bill that reached <code>warrant</code>.", "x": "<b>Expect:</b> <code>billPaid</code> fires with <code>wasWarrant = true</code> so a lawman script can clear its side."},
 ]},
 {"art": "IV", "title": "Society Funds &amp; Payroll", "tag": "job-gated &middot; atomic batch", "why":
  "Organisation money lives in the bank, and wages must reach a hand whether or not they are online.",
  "items": [
   {"id": "Y1", "who": "a", "t": "As a character with a society job (today: medical), visit a teller.", "x": "<b>Expect:</b> the society rail appears, named for the outfit. A jobless character sees a greyed <em>Society Accounts</em> instead."},
   {"id": "Y2", "who": "both", "t": "As a member <b>below</b> <code>bossGrade</code>, open it.", "x": "<b>Expect:</b> the fund balance is visible but there are no deposit, withdraw or payroll controls."},
   {"id": "Y3", "who": "a", "gate": True, "t": "As a boss, deposit $100 into the fund and withdraw $40.", "x": "<b>Expect:</b> both move, and both appear in the society account's ledger."},
   {"id": "Y4", "who": "a", "t": "Look at the roster in the payroll table.", "x": "<b>Expect:</b> every character holding one of that society's configured jobs is listed, with their grade."},
   {"id": "Y5", "who": "a", "gate": True, "t": "Run payroll for two hands with different amounts.", "x": "<b>Expect:</b> the society is debited <b>once</b> for the total, and each hand's <b>bank account</b> is credited their share."},
   {"id": "Y6", "who": "a", "gate": True, "t": "Run a payroll totalling more than the fund holds.", "x": "<b>Expect:</b> refused outright &mdash; <b>nobody</b> is paid. All-or-nothing; no partial run."},
   {"id": "Y7", "who": "both", "gate": True, "t": "Include an <b>offline</b> character in a payroll run.", "x": "<b>Expect:</b> they are still paid &mdash; into their account, waiting at the counter when they next ride in."},
   {"id": "Y8", "who": "b", "t": "<code>banking reconcile &lt;societyAccountId&gt;</code> after all of the above.", "x": "<b>Expect:</b> <code>ok: true</code>, no drift."},
 ]},
 {"art": "V", "title": "The Loan Book", "tag": "fixed-cost &middot; no compounding", "why":
  "Interest is agreed once, at signing. The borrower knows the whole obligation before they take the money.",
  "items": [
   {"id": "N1", "who": "a", "t": "Open Request Loan and type 500 into the principal.", "x": "<b>Expect:</b> the preview reads <em>&ldquo;Borrow $500.00, owe $550.00&rdquo;</em> at the default 10% &mdash; fixed at signing, with no further accrual."},
   {"id": "N2", "who": "a", "t": "Submit the application.", "x": "<b>Expect:</b> it is filed as <code>pending</code>; nothing has been disbursed yet."},
   {"id": "N3", "who": "b", "t": "<code>banking loans</code> in the console.", "x": "<b>Expect:</b> the pending application is listed with borrower, principal and total due."},
   {"id": "N4", "who": "b", "gate": True, "t": "<code>banking loans approve &lt;id&gt;</code>", "x": "<b>Expect:</b> the principal is credited to the chosen account, status becomes <code>active</code>, and <code>due_by</code> is set."},
   {"id": "N5", "who": "a", "t": "Repay part, then the rest, from the teller.", "x": "<b>Expect:</b> the balance counts down and status becomes <code>paid</code> at zero."},
   {"id": "N6", "who": "b", "t": "Check where repayments landed.", "x": "<b>Expect:</b> <b>SYS-GOV</b>. Each completed loan quietly retires its interest from the money supply."},
   {"id": "N7", "who": "a", "t": "Apply for a second loan while one is open.", "x": "<b>Expect:</b> <code>ERR_LOAN_LIMIT</code> (default one active per character)."},
   {"id": "N8", "who": "b", "t": "File a fresh application and <code>banking loans deny &lt;id&gt;</code>.", "x": "<b>Expect:</b> status <code>denied</code>, and <b>nothing</b> was disbursed."},
   {"id": "N9", "who": "b", "t": "Backdate an active loan's <code>due_by</code> into the past and let the sweep run.", "x": "<b>Expect:</b> status <code>defaulted</code> and <code>loanDefaulted</code> fires."},
 ]},
 {"art": "VI", "title": "Savings Interest", "tag": "real-life days &middot; no double-post", "why":
  "Interest accrues on real time whether you are online or not — and the lazy and swept paths must never both pay the same week.",
  "items": [
   {"id": "I1", "who": "b", "t": "Put money in a <b>savings</b> account, then force three weeks to have passed:<pre class=\"sql\">UPDATE sovereign_banking_savings_accrual\nSET last_accrued_at = NOW() - INTERVAL 21 DAY\nWHERE account_id = ?;</pre>", "x": "<b>Expect:</b> the row updates. (If no row exists, visit the teller once to create it.)"},
   {"id": "I2", "who": "a", "gate": True, "t": "Visit a teller and open the account's statement.", "x": "<b>Expect:</b> an <code>INTEREST</code> line has posted, memo reading how many weeks it covered."},
   {"id": "I3", "who": "a", "gate": True, "t": "Check the amount against three weeks of accrual.", "x": "<b>Expect:</b> capped at <code>catchUpCap</code> periods (default 4) &mdash; a long absence earns a modest catch-up, never a windfall."},
   {"id": "I4", "who": "a", "gate": True, "t": "Leave and revisit the teller immediately.", "x": "<b>Expect:</b> <b>no second posting</b>. The period already paid cannot pay again."},
   {"id": "I5", "who": "b", "gate": True, "t": "Backdate again, but this time let the <b>scheduler</b> post it instead of visiting.", "x": "<b>Expect:</b> the same single posting. Both paths derive the same idempotency key from the accrual base, so only one can ever land."},
   {"id": "I6", "who": "a", "t": "Do the same with a <b>checking</b> account.", "x": "<b>Expect:</b> <b>no interest, ever</b>. Only savings accrue."},
   {"id": "I7", "who": "b", "t": "<code>banking reconcile &lt;savingsAccountId&gt;</code>", "x": "<b>Expect:</b> no drift. Interest is a ledgered credit like any other."},
   {"id": "I8", "who": "b", "gate": True, "t": "<b>Regression.</b> After the capped catch-up in I3, wait for two more scheduler ticks (~30 min) without touching the account.", "x": "<b>Expect:</b> <b>no further interest</b> for the backdated period. <i>An audit found the clock advanced only by the paid periods, so the sweep kept paying the rest four at a time every tick &mdash; the cap became a slow drip of the same windfall. Periods beyond the cap are now forfeited.</i>"},
 ]},
 {"art": "VII", "title": "The Assayer", "tag": "gold &middot; spread", "why":
  "A period-plausible exchange counter: the bank sells dear and buys cheap, and the difference is its own.",
  "items": [
   {"id": "G1", "who": "a", "t": "Open Gold Exchange and read the quotes.", "x": "<b>Expect:</b> the buy price is <b>above</b> and the sell price <b>below</b> <code>Config.Gold.pricePerGold</code> &mdash; the spread, in the bank's favour both ways."},
   {"id": "G2", "who": "a", "t": "Buy 2.50 gold.", "x": "<b>Expect:</b> dollars leave and gold arrives, matching the quoted figures exactly."},
   {"id": "G3", "who": "a", "t": "Sell the same 2.50 gold straight back.", "x": "<b>Expect:</b> you are down <b>exactly the spread</b> &mdash; no more, no less."},
   {"id": "G4", "who": "a", "t": "Try to sell gold you do not have.", "x": "<b>Expect:</b> <code>ERR_INSUFFICIENT_FUNDS</code>, and nothing moves on either side."},
 ]},
 {"art": "VIII", "title": "The Vault Drawers", "tag": "HIGH RISK &middot; vorp_inventory", "why":
  "Your vorp_inventory is an escrow-encrypted, modified build that declares stashes in config, while this module registers them at runtime. Its export names could not be verified from source — this is the likeliest failure in the whole resource.",
  "items": [
   {"id": "V1", "who": "a", "t": "Rent a small deposit box.", "x": "<b>Expect:</b> the rent leaves your cash in hand and the box appears in the list with a paid-through date."},
   {"id": "V2", "who": "b", "t": "Check <code>SVB-0000002</code> (insurance) after renting.", "x": "<b>Expect:</b> it grew by the rent. Vault upkeep is bank income."},
   {"id": "V3", "who": "a", "gate": True, "t": "Press <b>Open</b> on the box.", "x": "<b>Expect:</b> the bank UI closes and <b>an actual stash window appears</b>. <i>This is the critical one. If it fails, note the console error &mdash; the fix is in <code>bridge/vorp.lua</code> (RegisterStash / OpenStash), and nothing else in the resource depends on the inventory.</i>"},
   {"id": "V4", "who": "a", "t": "Put an item in, close the stash, and reopen the box.", "x": "<b>Expect:</b> the item is still in there."},
   {"id": "V5", "who": "b", "t": "Restart the resource, then reopen the box in game.", "x": "<b>Expect:</b> contents survive &mdash; every box's stash is re-registered on boot."},
   {"id": "V6", "who": "a", "t": "Rent boxes past <code>maxPerChar</code> (default 2).", "x": "<b>Expect:</b> <code>ERR_SDB_LIMIT</code>."},
   {"id": "V7", "who": "b", "t": "Force the rent overdue:<pre class=\"sql\">UPDATE sovereign_banking_sdb\nSET rent_paid_until = NOW() - INTERVAL 30 DAY\nWHERE id = ?;</pre>", "x": "<b>Expect:</b> the box shows <b>rent due</b> and Open is disabled; forcing it returns <code>ERR_RENT_DUE</code>."},
   {"id": "V8", "who": "a", "t": "Pay the rent.", "x": "<b>Expect:</b> the box unlocks and the paid-through date extends from today, not from the lapsed date."},
   {"id": "V9", "who": "a", "gate": True, "t": "<b>Regression.</b> Have two players rent a box at the same moment, and separately double-click <b>Pay Rent</b>.", "x": "<b>Expect:</b> both rentals succeed, and the double-click takes <b>one</b> payment for one period. <i>An audit found the rental placeholder collided on a UNIQUE key (the second renter was charged and got nothing, and one stranded row could have blocked every rental server-wide), and that rent renewal had no mutex.</i>"},
 ]},
]

build('B2-COMMERCE-LEDGER.html',
      'B2 Commerce & Credit Ledger — Sovereign Bank',
      'B2 COMMERCE &amp; CREDIT LEDGER',
      'Bills, societies, loans, interest, gold &amp; the vault — sovereign_banking v0.6.0',
      "The second gate: the rails the rest of the county bills and pays wages on. Assumes B1 is green. Several steps need time to have passed &mdash; rather than waiting a real week, each gives you the SQL to backdate a timestamp and let the sweep catch it. Article VIII is flagged <em>high risk</em> for a reason worth reading before you start it. Mark each line, note the <code>ERR_</code> code on failure, then <em>Build the Report</em> and paste it back.",
      'B2 Progress',
      'Every line recorded. Press <b>Build the Report</b> and paste it back. If the blockers are green, other scripts may safely issue debt and pay wages through the bank.',
      'banking-b2-commerce',
      'SOVEREIGN BANK — B2 Commerce & Credit Ledger — Results',
      'other scripts should not issue debt or run payroll until these pass.',
      B2)


# ===========================================================================
# B3 — ENFORCEMENT & OPS
# ===========================================================================
B3 = [
 {"art": "I", "title": "Business &amp; the Tax Ledger", "tag": "licence fee &middot; no sales tax", "why":
  "What a shop owes for the right to trade, sized by the building it trades from — owed whether or not it sells a thing.",
  "items": [
   {"id": "Z1", "who": "b", "t": "No purchase flow is wired yet, so register by hand:<pre class=\"sql\">exports.sovereign_banking:RegisterBusiness('valentine_gunsmith', '42', 200000,\n  { name = 'Valentine Gunsmith' })</pre>", "x": "<b>Expect:</b> a business account is created and a Tax Ledger row opens with the building price as its basis."},
   {"id": "Z2", "who": "a", "t": "As the registered owner, visit a teller.", "x": "<b>Expect:</b> a <b>Business &amp; Tax</b> rail, showing the $2,000 basis and a $500 fee per period (25%)."},
   {"id": "Z3", "who": "b", "t": "<code>exports.sovereign_banking:AssessBusinessTax('valentine_gunsmith')</code>", "x": "<b>Expect:</b> owed rises by $500 and a <code>tax_assessed</code> row appears in the ledger."},
   {"id": "Z4", "who": "b", "gate": True, "t": "Immediately assess the same business again.", "x": "<b>Expect:</b> refused &mdash; owed does <b>not</b> double. The period advances by compare-and-set, so the scheduler and a manual call cannot both charge for it."},
   {"id": "Z5", "who": "a", "t": "Remit the tax from the business account.", "x": "<b>Expect:</b> owed drops to zero and SYS-GOV rises by the same amount."},
   {"id": "Z6", "who": "b", "gate": True, "t": "<code>banking reconcile &lt;businessAccountId&gt;</code>", "x": "<b>Expect:</b> <b>no drift.</b> Assessments are deliberately ledgered against no account (they are an obligation, not a movement) precisely so this holds."},
   {"id": "Z7", "who": "b", "t": "Backdate <code>next_due_at</code> in <code>sovereign_banking_business_tax</code> with a balance owed, then let the sweep run.", "x": "<b>Expect:</b> a <code>tax</code> bill opens against the <b>owner</b> and enters the collections pipeline as government debt."},
   {"id": "Z8", "who": "both", "t": "As a character who is not the owner, try to view or remit for that business.", "x": "<b>Expect:</b> the rail does not appear, and the export path returns <code>ERR_ACCESS</code>."},
 ]},
 {"art": "II", "title": "The Collections Queue", "tag": "tier 2 &middot; civil authority", "why":
  "The Tax Collector may compel payment but never arrest. Dormant until a tax_office job exists — skip this article if it does not.",
  "items": [
   {"id": "Q1", "who": "a", "t": "As a character holding the <code>tax_office</code> job, visit a teller.", "x": "<b>Expect:</b> a <b>Collections Queue</b> rail. No other character sees it."},
   {"id": "Q2", "who": "a", "t": "Open the queue.", "x": "<b>Expect:</b> tier-2 debts listed with debtor, amount, days overdue and whether anyone holds them."},
   {"id": "Q3", "who": "a", "t": "Claim an unassigned debt.", "x": "<b>Expect:</b> it now shows as held by you, so two collectors do not work the same debtor."},
   {"id": "Q4", "who": "a", "gate": True, "t": "Collect the full amount in cash from a debtor.", "x": "<b>Expect:</b> the bill closes, the creditor is paid, and your commission lands in the <b>Tax Office</b> fund."},
   {"id": "Q5", "who": "a", "t": "Collect only part of another debt.", "x": "<b>Expect:</b> the balance drops and the bill stays open &mdash; that is the payment plan."},
   {"id": "Q6", "who": "a", "t": "Escalate a <b>fine or tax</b> that is in collections.", "x": "<b>Expect:</b> status becomes <code>warrant</code> and <code>warrantFiled</code> fires for the lawman script."},
   {"id": "Q7", "who": "a", "gate": True, "t": "Look at an <b>invoice</b> row in the queue.", "x": "<b>Expect:</b> it has <b>no Escalate control at all</b>, and reads <em>civil debt &mdash; never a warrant</em>. Calling the export directly returns <code>ERR_CIVIL_DEBT</code>."},
   {"id": "Q8", "who": "b", "gate": True, "t": "<b>Security regression.</b> As a collector, try to collect a debt from an account the <b>debtor does not own</b> &mdash; e.g. another player's account id:<pre class=\"sql\">exports.sovereign_banking:RecordCollection(billId, 100, {\n  collectorCharid = '&lt;collector&gt;', payWith = &lt;someone else's accountId&gt; })</pre>", "x": "<b>Expect:</b> <code>ERR_ACCESS</code> and <b>no money moves</b>. <i>An audit found this unguarded &mdash; a collector could name any account in the bank as the payment source and drain it under color of a real debt. The suite covers it too; this confirms it end to end.</i>"},
   {"id": "Q9", "who": "b", "t": "Check the currency on a settled collection where the bill was denominated in gold.", "x": "<b>Expect:</b> the debt was settled in <b>gold</b>, not dollars. <i>Collections previously hardcoded dollars, letting a gold debt be discharged at a 20:1 discount.</i>"},
 ]},
 {"art": "III", "title": "Lawful Seizure", "tag": "the guardrails", "why":
  "The one place this resource authorises force. Every gate here matters more than any feature in the bank.",
  "items": [
   {"id": "E1", "who": "b", "gate": True, "t": "<code>exports.sovereign_banking:IsSeizureAuthorized(collectorCharid, debtorWithNoDebt)</code>", "x": "<b>Expect:</b> <b>false.</b> No debt, no authority &mdash; this is what your restraint script must check before allowing a rope."},
   {"id": "E2", "who": "b", "gate": True, "t": "Same call, but with a character who is <b>not</b> a Tax Collector against a real debtor.", "x": "<b>Expect:</b> <b>false.</b> The job is required as well as the debt."},
   {"id": "E3", "who": "b", "gate": True, "t": "<code>SeizeAssets</code> against someone with no open tier-2 debt.", "x": "<b>Expect:</b> <code>ERR_SEIZURE_DENIED</code>, and <b>nothing</b> leaves their inventory. There is no generic take-their-things path."},
   {"id": "E4", "who": "b", "gate": True, "t": "Seize against a <b>small</b> debt while the debtor carries far more than they owe.", "x": "<b>Expect:</b> the take is <b>capped to what is owed</b>. A five-dollar debt cannot strip someone bare."},
   {"id": "E5", "who": "b", "t": "Include an item from <code>Config.Collections.seizure.exemptItems</code> in the list.", "x": "<b>Expect:</b> it is never taken, whatever the debt."},
   {"id": "E6", "who": "both", "t": "Seize goods worth <b>more</b> than the debt (with capToDebt off, or via a single high-value item).", "x": "<b>Expect:</b> the surplus is <b>banked back to the debtor's</b> account, not kept."},
   {"id": "E7", "who": "a", "t": "Check the debtor's inventory afterwards.", "x": "<b>Expect:</b> exactly the seized items are gone &mdash; no more, and nothing they were paid for but still hold."},
   {"id": "E8", "who": "b", "t": "<code>SELECT * FROM sovereign_banking_seizures ORDER BY id DESC LIMIT 1;</code>", "x": "<b>Expect:</b> a row naming collector, debtor, the itemised JSON, assessed value, amount applied and surplus returned. Every seizure is disputable after the fact."},
   {"id": "E9", "who": "b", "t": "Seize for less than the full debt.", "x": "<b>Expect:</b> the shortfall leaves the bill <b>open</b> &mdash; it is not written off."},
 ]},
 {"art": "IV", "title": "The Branch Reserve", "tag": "the guarantee", "why":
  "Banked money is government-insured and can never be taken. A robbery empties the till, and only the till.",
  "items": [
   {"id": "H1", "who": "b", "gate": True, "t": "<b>Before anything:</b> snapshot every balance.<pre class=\"sql\">SELECT SUM(balance_money) AS total FROM sovereign_banking_accounts;</pre>", "x": "<b>Expect:</b> a number. Write it down &mdash; H4 depends on it."},
   {"id": "H2", "who": "b", "t": "Rob the till:<pre class=\"sql\">exports.sovereign_banking:ClaimBranchReserve('valentine', 0,\n  { fraction = 0.6, looters = { '42' } })</pre>", "x": "<b>Expect:</b> returns <code>looted</code> and <code>remaining</code>, and the looter's <b>cash in hand</b> grows by the take."},
   {"id": "H3", "who": "b", "t": "<code>SELECT balance FROM sovereign_banking_reserves WHERE branch_id='valentine';</code>", "x": "<b>Expect:</b> down by <b>exactly</b> what was looted."},
   {"id": "H4", "who": "b", "gate": True, "t": "Re-run the H1 query and compare.", "x": "<b>Expect:</b> <b>identical to the cent.</b> Not one account &mdash; player, society or system &mdash; moved. <i>This is the promise the whole insurance fiction rests on. If this number changed, stop and report it.</i>"},
   {"id": "H5", "who": "b", "t": "Find the heist row: <code>SELECT * FROM sovereign_banking_transactions WHERE category='heist' ORDER BY id DESC LIMIT 1;</code>", "x": "<b>Expect:</b> a row with <code>account_id</code> <b>NULL</b> and the branch named in the memo &mdash; the till is not an account, so it stays out of reconciliation."},
   {"id": "H6", "who": "b", "t": "Claim again until the till is empty, then once more.", "x": "<b>Expect:</b> <code>ERR_INSUFFICIENT_FUNDS</code> on the empty till. It cannot go negative."},
   {"id": "H7", "who": "b", "t": "Replay a claim with the same <code>idem</code> key.", "x": "<b>Expect:</b> no second payout &mdash; the original result is returned."},
   {"id": "H8", "who": "b", "t": "Backdate <code>last_refilled_at</code> past <code>replenishRealHrs</code> and let the sweep run.", "x": "<b>Expect:</b> the till refills to its cap. A branch cannot be farmed back-to-back."},
 ]},
 {"art": "V", "title": "The Ledger Office", "tag": "/bankadmin &middot; permission", "why":
  "Force is sometimes necessary — but an admin's hand must leave the same paper trail as anyone else's.",
  "items": [
   {"id": "O1", "who": "a", "gate": True, "t": "As an ACE holder, type <code>/bankadmin</code> anywhere on the map.", "x": "<b>Expect:</b> the Ledger Office opens &mdash; it is an ops tool, so it works away from a branch."},
   {"id": "O2", "who": "both", "gate": True, "t": "As a player <b>without</b> the ACE, type <code>/bankadmin</code>.", "x": "<b>Expect:</b> refused with a notification. Permission is re-checked server-side on every admin call, not just at open."},
   {"id": "O3", "who": "a", "t": "Read the Money Supply column against the database.", "x": "<b>Expect:</b> total banked, account count, public funds, loans outstanding and unpaid debt all match."},
   {"id": "O4", "who": "a", "t": "Search accounts by number, then by owner charid, then by name.", "x": "<b>Expect:</b> all three find the right rows."},
   {"id": "O5", "who": "both", "gate": True, "t": "Freeze an account, then have its owner try to withdraw.", "x": "<b>Expect:</b> refused with <code>ERR_FROZEN</code>. Thawing restores access."},
   {"id": "O6", "who": "a", "gate": True, "t": "Force-adjust an account by +$25 with a reason.", "x": "<b>Expect:</b> the balance moves <b>and</b> an <code>admin_adjust</code> ledger row appears naming <b>you</b> and your reason. Never a silent write."},
   {"id": "O7", "who": "a", "t": "Try to adjust by more than <code>Config.Admin.adjustMax</code>.", "x": "<b>Expect:</b> refused."},
   {"id": "O8", "who": "a", "gate": True, "t": "Press <b>Reconcile</b>.", "x": "<b>Expect:</b> <em>&ldquo;All N accounts reconcile exactly.&rdquo;</em> Any drift reported here means a balance and its ledger disagree &mdash; which should be impossible."},
   {"id": "O9", "who": "a", "t": "Approve and deny pending loans from the panel.", "x": "<b>Expect:</b> same behaviour as the console commands."},
   {"id": "O10", "who": "a", "t": "Compare the branch till meters to <code>sovereign_banking_reserves</code>.", "x": "<b>Expect:</b> they match, including any till you emptied in Article IV."},
 ]},
 {"art": "VI", "title": "The Contract", "tag": "integration &middot; for the suite", "why":
  "The export surface is the product as much as the counter is. This is what every other Sovereign script will lean on.",
  "items": [
   {"id": "K1", "who": "b", "gate": True, "t": "From <b>another resource</b>, call <code>exports.sovereign_banking:AddMoney(charid, 0, 2500, { reason='payroll' })</code>.", "x": "<b>Expect:</b> it pays, and the ledger row's <code>source_resource</code> names <b>that resource</b> &mdash; attribution is automatic."},
   {"id": "K2", "who": "b", "t": "Call <code>RemoveMoney</code> for more than the character has.", "x": "<b>Expect:</b> returns <code>false</code> with a code. It <b>never throws</b> &mdash; callers can branch safely."},
   {"id": "K3", "who": "b", "gate": True, "t": "Call the same AddMoney twice with an identical <code>idem</code> key.", "x": "<b>Expect:</b> paid once. This is what makes a retried job payout safe."},
   {"id": "K4", "who": "b", "t": "Add a listener for <code>sovereign_banking:server:transactionCompleted</code> and move some money.", "x": "<b>Expect:</b> it fires with charid, account, amount, direction and category."},
   {"id": "K5", "who": "b", "t": "Listen for <code>sovereign_banking:server:warrantFiled</code> across a full delinquency run.", "x": "<b>Expect:</b> it fires for fines and taxes only &mdash; never for a private invoice."},
   {"id": "K6", "who": "b", "t": "<i>Only if you enabled it:</i> with <code>Config.Compat.enabled = true</code>, call <code>exports.sovereign_banking:addMoney(source, 0, 12.50)</code>.", "x": "<b>Expect:</b> $12.50 arrives &mdash; the shim takes a <b>source</b> and <b>display units</b>, unlike the native exports."},
 ]},
 {"art": "VII", "title": "The Books Balance", "tag": "closing audit", "why":
  "After everything above has churned money through every path, the ledger and the balances must still agree exactly.",
  "items": [
   {"id": "F1", "who": "b", "gate": True, "t": "<code>banking_admin reconcile 500</code> in the console.", "x": "<b>Expect:</b> <code>drifted: []</code>. Every account's ledger sum equals its stored balance, after a full day of abuse."},
   {"id": "F2", "who": "b", "t": "<code>banking_admin supply 7</code>", "x": "<b>Expect:</b> a sane picture &mdash; faucets and sinks by category, with nothing wildly lopsided you cannot explain."},
   {"id": "F3", "who": "b", "t": "Search the whole console log for <code>CRITICAL</code> and for <code>reconciliation drift</code>.", "x": "<b>Expect:</b> <b>no hits.</b> Either one means something outside the bank wrote to its tables."},
   {"id": "F4", "who": "b", "t": "Restart the server once more and re-run F1.", "x": "<b>Expect:</b> still clean. Nothing was being held only in memory."},
 ]},
]

build('B3-ENFORCEMENT-LEDGER.html',
      'B3 Enforcement & Ops Ledger — Sovereign Bank',
      'B3 ENFORCEMENT &amp; OPS LEDGER',
      'Business tax, collections, seizure, heists &amp; the ledger office — sovereign_banking v0.6.0',
      "The last gate, and the one with the sharpest edges. Article III authorises force and Article IV carries the promise that banked money can never be robbed &mdash; their blockers matter more than any feature in the bank. Articles I and II lie dormant until a <code>tax_office</code> job exists and a store registers a business; skip them if that is still true. Mark each line, note the <code>ERR_</code> code on failure, then <em>Build the Report</em> and paste it back.",
      'B3 Progress',
      'Every line recorded. Press <b>Build the Report</b> and paste it back. If the blockers are green, heists may be enabled and the Tax Collector job may be handed out.',
      'banking-b3-enforcement',
      'SOVEREIGN BANK — B3 Enforcement & Ops Ledger — Results',
      'do not enable heists or hand out the Tax Collector job until these pass.',
      B3)

print('\nDone.')
