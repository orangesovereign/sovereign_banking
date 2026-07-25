/* Sovereign Bank teller NUI.
   Protocol (tech spec §10.2): { action, payload } in via window message;
   requests out via fetch → client/nui.lua → server RPC. The UI holds no
   authority: every number it shows came from the server, every action is
   re-validated server-side. */

'use strict';

const RES = (typeof GetParentResourceName === 'function') ? GetParentResourceName() : 'sov_bank';

const S = {
  open: false,
  data: null,       // { accounts, wallet, branch, config }
  view: 'overview',
  accountId: null,  // detail view target
  tab: 'actions',
  stmt: { rows: [], offset: 0, done: false, category: '' },
};

// ------------------------------------------------------------------ helpers

const $ = (sel) => document.querySelector(sel);

async function rpc(name, payload = {}) {
  try {
    const r = await fetch(`https://${RES}/rpc`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name, payload }),
    });
    return await r.json();
  } catch (e) {
    return { ok: false, error: 'ERR_INTERNAL' };
  }
}

function post(name, payload = {}) {
  fetch(`https://${RES}/${name}`, { method: 'POST', body: JSON.stringify(payload) });
}

const ERR_TEXT = {
  ERR_BAD_AMOUNT: 'That is not a valid amount.',
  ERR_BAD_CURRENCY: 'Unknown currency.',
  ERR_CURRENCY_DISABLED: 'This bank does not deal in that currency.',
  ERR_NO_ACCOUNT: 'No such account on our books.',
  ERR_ACCOUNT_CLOSED: 'That account has been closed.',
  ERR_FROZEN: 'That account is frozen.',
  ERR_INSUFFICIENT_FUNDS: 'Insufficient funds.',
  ERR_NO_CREDIT: 'That exceeds the account’s credit.',
  ERR_OFFLINE: 'The account holder must be present.',
  ERR_WALLET_APPLY: 'The cash drawer disagreed — nothing was moved.',
  ERR_SAME_ACCOUNT: 'Cannot transfer an account into itself.',
  ERR_UNKNOWN_CHAR: 'No such person is known to this bank.',
  ERR_NOT_AT_BRANCH: 'You must be at the counter.',
  ERR_ACCESS: 'You are not authorized for that.',
  ERR_BAD_KIND: 'Unknown account type.',
  ERR_BAD_LEVEL: 'Unknown access level.',
  ERR_ACCOUNT_LIMIT: 'You hold as many accounts as the bank allows.',
  ERR_NOT_EMPTY: 'The account must be emptied before it can be closed.',
  ERR_RATE_LIMITED: 'One moment, please.',
  ERR_INTERNAL: 'The clerk fumbled the paperwork. Try again.',
};
const errText = (code) => ERR_TEXT[code] || ERR_TEXT.ERR_INTERNAL;

const CUR = { money: 0, gold: 1, rol: 2 };

function fmt(minor, currency = 'money') {
  const v = (Number(minor) || 0) / 100;
  const s = v.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  if (currency === 'gold') return `${s} Gold`;
  if (currency === 'rol') return `${s} Rol`;
  return `$${s}`;
}

function toMinor(text) {
  const n = parseFloat(String(text).replace(/,/g, '.').replace(/[^0-9.]/g, ''));
  if (!isFinite(n) || n <= 0) return null;
  return Math.round(n * 100);
}

function fmtDate(epoch) {
  if (!epoch) return '—';
  const d = new Date(epoch * 1000);
  return d.toLocaleString('en-US', {
    day: 'numeric', month: 'short', year: 'numeric',
    hour: '2-digit', minute: '2-digit',
  });
}

function esc(s) {
  return String(s ?? '').replace(/[&<>"']/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[c]));
}

function toast(msg, kind = 'success') {
  const el = document.createElement('div');
  el.className = `toast ${kind}`;
  el.textContent = msg;
  $('#toasts').appendChild(el);
  setTimeout(() => el.remove(), 3600);
}

function enabledCurrencies() {
  const c = S.data?.config?.currencies || { money: true };
  return ['money', 'gold', 'rol'].filter((k) => c[k]);
}

function currencyChips(sel, current) {
  return `<div class="currency-chips">${enabledCurrencies().map((k) =>
    `<button class="chip ${k === current ? 'active' : ''}" data-cur="${k}" data-sel="${sel}">
      ${k === 'money' ? 'Dollars' : k[0].toUpperCase() + k.slice(1)}</button>`).join('')}</div>`;
}

function getAccount(id) {
  return (S.data?.accounts || []).find((a) => a.id === id) || null;
}

function canWithdraw(a) { return ['owner', 'admin', 'withdraw'].includes(a.access); }
function canDeposit(a) { return ['owner', 'admin', 'withdraw', 'deposit'].includes(a.access); }
function canAdmin(a) { return ['owner', 'admin'].includes(a.access); }

function feeEstimate(minor, own) {
  const fees = S.data?.config?.fees || {};
  const cfg = own ? fees.same : fees.cross;
  if (!cfg) return 0;
  if (cfg.type === 'flat') return Math.floor(cfg.value || 0);
  if (cfg.type === 'percent') return Math.round(minor * (cfg.value || 0));
  return 0;
}

// ------------------------------------------------------------ shell renders

function renderHeader() {
  $('#branch-name').textContent = S.data?.branch?.name || '';
  const w = S.data?.wallet || {};
  $('#wallet-display').innerHTML =
    `<div class="w-label">Cash in hand</div><b>${fmt(w.money || 0)}</b>` +
    (S.data?.config?.currencies?.gold ? `<br><b class="gold">${fmt(w.gold || 0, 'gold')}</b>` : '');
}

function setView(view) {
  S.view = view;
  document.querySelectorAll('.nav-btn').forEach((b) =>
    b.classList.toggle('active', b.dataset.view === view));
  render();
}

function render() {
  renderHeader();
  if (S.view === 'overview') return renderOverview();
  if (S.view === 'account') return renderAccount();
  if (S.view === 'transfer') return renderTransfer();
  if (S.view === 'open') return renderOpen();
}

// -------------------------------------------------------------- view: cards

function renderOverview() {
  const accounts = S.data?.accounts || [];
  $('#view').innerHTML = `
    <h2>Register of Accounts</h2>
    <div class="acct-grid">
      ${accounts.map((a) => `
        <div class="acct-card ${a.kind}" data-open="${a.id}">
          <div>
            <div class="acct-title">${esc(a.name)}
              <span class="badge ${a.kind === 'savings' ? 'savings' : ''}">${esc(a.kind)}</span>
              ${a.isOwner ? '' : '<span class="badge shared">shared</span>'}
            </div>
            <div class="acct-sub">№ ${esc(a.number)} · access: ${esc(a.access)}</div>
          </div>
          <div class="acct-balances">
            <div class="money">${fmt(a.balances.money)}</div>
            ${S.data.config.currencies.gold ? `<div class="gold">${fmt(a.balances.gold, 'gold')}</div>` : ''}
          </div>
        </div>`).join('')}
    </div>
    ${accounts.length === 0 ? '<p class="muted" style="text-align:center;margin-top:18px">No accounts on our books. Enquire at the “New Account” desk.</p>' : ''}
  `;
  document.querySelectorAll('[data-open]').forEach((el) =>
    el.addEventListener('click', () => {
      S.accountId = Number(el.dataset.open);
      S.tab = 'actions';
      S.stmt = { rows: [], offset: 0, done: false, category: '' };
      setView('account');
    }));
}

// ------------------------------------------------------------- view: detail

function renderAccount() {
  const a = getAccount(S.accountId);
  if (!a) return setView('overview');

  const tabs = [['actions', 'Counter'], ['statement', 'Statement']];
  if (canAdmin(a)) tabs.push(['access', 'Access']);
  if (a.isOwner) tabs.push(['manage', 'Manage']);

  $('#view').innerHTML = `
    <button class="backlink" id="back">← All accounts</button>
    <div class="detail-head">
      <div>
        <div class="acct-title">${esc(a.name)}
          <span class="badge ${a.kind === 'savings' ? 'savings' : ''}">${esc(a.kind)}</span></div>
        <div class="acct-sub">№ ${esc(a.number)}</div>
      </div>
      <div class="detail-balance">
        <div class="money">${fmt(a.balances.money)}</div>
        ${S.data.config.currencies.gold ? `<div class="gold">${fmt(a.balances.gold, 'gold')}</div>` : ''}
      </div>
    </div>
    <div class="tabs">
      ${tabs.map(([k, label]) =>
        `<button class="tab-btn ${S.tab === k ? 'active' : ''}" data-tab="${k}">${label}</button>`).join('')}
    </div>
    <div id="tab-body"></div>
  `;
  $('#back').addEventListener('click', () => setView('overview'));
  document.querySelectorAll('[data-tab]').forEach((el) =>
    el.addEventListener('click', () => { S.tab = el.dataset.tab; renderAccount(); }));

  const body = $('#tab-body');
  if (S.tab === 'actions') return renderActions(body, a);
  if (S.tab === 'statement') return renderStatement(body, a);
  if (S.tab === 'access') return renderAccess(body, a);
  if (S.tab === 'manage') return renderManage(body, a);
}

function renderActions(body, a) {
  const cur = S.curSel || 'money';
  body.innerHTML = `
    <div class="form-row">
      <div class="field"><label>Currency</label>${currencyChips('actions', cur)}</div>
      <div class="field"><label>Amount</label>
        <input type="text" id="amt" inputmode="decimal" placeholder="0.00"></div>
      ${canDeposit(a) ? '<button class="btn primary" id="do-dep">Deposit</button>' : ''}
      ${canWithdraw(a) ? '<button class="btn" id="do-wd">Withdraw</button>' : ''}
    </div>
    <p class="hint">Deposits move cash from your hand into the ledger; withdrawals hand it back.
      ${a.kind === 'savings' ? `Savings earn interest of ${((S.data.config.savingsAPR || 0) * 100).toFixed(1)}% (posted by the clerk on a real-week schedule).` : ''}</p>
  `;
  body.querySelectorAll('.chip').forEach((c) =>
    c.addEventListener('click', () => { S.curSel = c.dataset.cur; renderActions(body, a); }));

  const run = async (name) => {
    const amount = toMinor($('#amt').value);
    if (!amount) return toast(errText('ERR_BAD_AMOUNT'), 'error');
    const res = await rpc(name, { accountId: a.id, currency: CUR[S.curSel || 'money'], amount });
    if (!res.ok) return toast(errText(res.error), 'error');
    applySnapshot(res.data);
    toast(`${name === 'deposit' ? 'Deposited' : 'Withdrew'} ${fmt(amount, S.curSel || 'money')}.`);
    renderAccount();
  };
  $('#do-dep')?.addEventListener('click', () => run('deposit'));
  $('#do-wd')?.addEventListener('click', () => run('withdraw'));
}

// ---------------------------------------------------------- view: statement

const STMT_CATEGORIES = ['', 'deposit', 'withdraw', 'transfer', 'fee', 'add', 'remove', 'interest', 'compensation'];

async function loadStatement(a, reset) {
  if (reset) S.stmt = { rows: [], offset: 0, done: false, category: S.stmt.category };
  const res = await rpc('statement', {
    accountId: a.id, limit: 25, offset: S.stmt.offset,
    category: S.stmt.category || null,
  });
  if (!res.ok) { toast(errText(res.error), 'error'); return; }
  const rows = res.data.rows || [];
  S.stmt.rows = S.stmt.rows.concat(rows);
  S.stmt.offset += rows.length;
  if (rows.length < 25) S.stmt.done = true;
}

function renderStatement(body, a) {
  const curName = (c) => c === 1 ? 'gold' : c === 2 ? 'rol' : 'money';
  body.innerHTML = `
    <div class="form-row">
      <div class="field"><label>Entries</label>
        <select id="stmt-cat">
          ${STMT_CATEGORIES.map((c) =>
            `<option value="${c}" ${S.stmt.category === c ? 'selected' : ''}>${c || 'All entries'}</option>`).join('')}
        </select></div>
    </div>
    <table class="ledger">
      <thead><tr><th>Date</th><th>Entry</th><th>Memo</th><th class="num">Amount</th><th class="num">Balance</th></tr></thead>
      <tbody id="stmt-rows">
        ${S.stmt.rows.map((r) => `
          <tr>
            <td>${fmtDate(r.created_at)}</td>
            <td><span class="cat">${esc(r.category)}</span></td>
            <td class="memo-cell">${esc(r.memo || '')}</td>
            <td class="num ${r.direction === 'credit' ? 'amt-credit' : 'amt-debit'}">
              ${r.direction === 'credit' ? '+' : '−'}${fmt(r.amount, curName(r.currency))}</td>
            <td class="num">${r.balance_after != null ? fmt(r.balance_after, curName(r.currency)) : '—'}</td>
          </tr>`).join('')}
      </tbody>
    </table>
    ${S.stmt.rows.length === 0 ? '<p class="muted" style="margin-top:12px">Nothing in the ledger yet.</p>' : ''}
    ${!S.stmt.done ? '<div style="margin-top:14px"><button class="btn slim" id="stmt-more">Further back…</button></div>' : ''}
  `;
  $('#stmt-cat').addEventListener('change', async (e) => {
    S.stmt.category = e.target.value;
    await loadStatement(a, true);
    renderStatement(body, a);
  });
  $('#stmt-more')?.addEventListener('click', async () => {
    await loadStatement(a, false);
    renderStatement(body, a);
  });
  if (S.stmt.rows.length === 0 && !S.stmt.done && S.stmt.offset === 0) {
    loadStatement(a, true).then(() => renderStatement(body, a));
  }
}

// ------------------------------------------------------------- view: access

async function renderAccess(body, a) {
  body.innerHTML = '<p class="muted">Fetching the register…</p>';
  const res = await rpc('accountAccess', { accountId: a.id });
  if (!res.ok) { body.innerHTML = `<p class="muted">${esc(errText(res.error))}</p>`; return; }
  const rows = res.data.rows || [];
  const myLevel = res.data.myLevel;
  const grantable = myLevel === 'owner'
    ? ['read', 'deposit', 'withdraw', 'admin']
    : ['read', 'deposit', 'withdraw'];

  body.innerHTML = `
    <div class="form-row">
      <div class="field"><label>Character ID</label>
        <input type="text" id="acc-char" inputmode="numeric" placeholder="e.g. 42"></div>
      <div class="field"><label>Access</label>
        <select id="acc-level">${grantable.map((l) => `<option value="${l}">${l}</option>`).join('')}</select></div>
      <button class="btn primary" id="acc-grant">Grant</button>
    </div>
    <p class="hint">Access is hierarchical: withdraw includes deposit; admin can manage non-admin access. Only the owner may appoint admins.</p>
    <div style="margin-top:16px">
      ${rows.map((r) => `
        <div class="access-row">
          <div><b>${esc(r.charid)}</b>
            <span class="badge">${esc(r.level)}</span>
            ${r.isOwner ? '<span class="badge shared">holder</span>' : ''}</div>
          ${r.isOwner ? '' : `<button class="btn slim danger" data-revoke="${esc(r.charid)}">Revoke</button>`}
        </div>`).join('')}
    </div>
  `;
  $('#acc-grant').addEventListener('click', async () => {
    const charid = $('#acc-char').value.trim();
    if (!charid) return toast(errText('ERR_UNKNOWN_CHAR'), 'error');
    const r = await rpc('grantAccess', { accountId: a.id, charid, level: $('#acc-level').value });
    if (!r.ok) return toast(errText(r.error), 'error');
    toast('Access recorded.');
    renderAccess(body, a);
  });
  body.querySelectorAll('[data-revoke]').forEach((el) =>
    el.addEventListener('click', async () => {
      const r = await rpc('revokeAccess', { accountId: a.id, charid: el.dataset.revoke });
      if (!r.ok) return toast(errText(r.error), 'error');
      toast('Access struck from the register.');
      renderAccess(body, a);
    }));
}

// ------------------------------------------------------------- view: manage

function renderManage(body, a) {
  const empty = Object.values(a.balances).every((v) => (v || 0) === 0);
  body.innerHTML = `
    <p>Closing an account strikes it from the bank’s books. The ledger history is retained.</p>
    <p class="hint">${empty ? 'This account is empty and may be closed.'
      : 'Withdraw or transfer every balance before closing.'}</p>
    <div style="margin-top:14px">
      <button class="btn danger" id="do-close" ${empty ? '' : 'disabled'}>Close this account</button>
    </div>
  `;
  $('#do-close')?.addEventListener('click', async () => {
    const res = await rpc('closeAccount', { accountId: a.id });
    if (!res.ok) return toast(errText(res.error), 'error');
    applySnapshot(res.data);
    toast('Account closed.');
    setView('overview');
  });
}

// ----------------------------------------------------------- view: transfer

function renderTransfer() {
  const sources = (S.data?.accounts || []).filter(canWithdraw);
  const ownTargets = S.data?.accounts || [];
  const cur = S.curSel || 'money';

  $('#view').innerHTML = `
    <h2>Wire &amp; Pay</h2>
    ${sources.length === 0 ? '<p class="muted">You hold no account you may draw upon.</p>' : `
    <div class="form-row">
      <div class="field"><label>From</label>
        <select id="tr-from">
          ${sources.map((a) => `<option value="${a.id}">${esc(a.name)} — ${esc(a.number)} (${fmt(a.balances.money)})</option>`).join('')}
        </select></div>
      <div class="field"><label>Currency</label>${currencyChips('transfer', cur)}</div>
    </div>
    <div class="form-row">
      <div class="field"><label>To — my account</label>
        <select id="tr-own">
          <option value="">—</option>
          ${ownTargets.map((a) => `<option value="${a.id}">${esc(a.name)} — ${esc(a.number)}</option>`).join('')}
        </select></div>
      <div class="field"><label>or account number</label>
        <input type="text" id="tr-num" placeholder="SVB-0000123"></div>
    </div>
    <div class="form-row">
      <div class="field"><label>Amount</label>
        <input type="text" id="tr-amt" inputmode="decimal" placeholder="0.00"></div>
      <div class="field"><label>Memo</label>
        <input type="text" id="tr-memo" maxlength="120" placeholder="for the cattle" style="min-width:260px"></div>
      <button class="btn primary" id="tr-send">Send by Wire</button>
    </div>
    <p class="hint" id="tr-fee">Transfers between your own accounts are free; wires to another holder carry the bank’s fee, which funds the government insurance on all deposits.</p>
    `}
  `;

  if (sources.length === 0) return;

  document.querySelectorAll('.chip').forEach((c) =>
    c.addEventListener('click', () => { S.curSel = c.dataset.cur; renderTransfer(); }));

  const feeLine = () => {
    const amt = toMinor($('#tr-amt').value) || 0;
    const own = !$('#tr-num').value.trim() && $('#tr-own').value !== '';
    const fee = amt ? feeEstimate(amt, own) : 0;
    $('#tr-fee').textContent = amt
      ? `Estimated fee: ${fmt(fee, S.curSel || 'money')} ${own ? '(own accounts)' : '(wire)'} — the teller will quote the exact figure.`
      : 'Transfers between your own accounts are free; wires to another holder carry the bank’s fee.';
  };
  ['tr-amt', 'tr-num'].forEach((id) => $(`#${id}`).addEventListener('input', feeLine));
  $('#tr-own').addEventListener('change', feeLine);

  $('#tr-send').addEventListener('click', async () => {
    const amount = toMinor($('#tr-amt').value);
    if (!amount) return toast(errText('ERR_BAD_AMOUNT'), 'error');
    const fromId = Number($('#tr-from').value);
    const toNumber = $('#tr-num').value.trim();
    const toId = $('#tr-own').value ? Number($('#tr-own').value) : null;
    if (!toNumber && !toId) return toast(errText('ERR_NO_ACCOUNT'), 'error');

    const res = await rpc('transfer', {
      fromId,
      toId: toNumber ? null : toId,
      toNumber: toNumber || null,
      currency: CUR[S.curSel || 'money'],
      amount,
      memo: $('#tr-memo').value.trim() || null,
    });
    if (!res.ok) return toast(errText(res.error), 'error');
    applySnapshot(res.data);
    const fee = res.data?.result?.fee || 0;
    toast(`Sent ${fmt(amount, S.curSel || 'money')}${fee ? ` (fee ${fmt(fee, S.curSel || 'money')})` : ''}.`);
    renderTransfer();
  });
}

// --------------------------------------------------------- view: open acct

function renderOpen() {
  const n = (S.data?.accounts || []).filter((a) => a.isOwner).length;
  const max = S.data?.config?.maxAccounts || 4;
  $('#view').innerHTML = `
    <h2>Open a New Account</h2>
    <p class="hint" style="text-align:center">You hold ${n} of ${max} accounts the bank permits.</p>
    <div class="form-row" style="margin-top:18px;justify-content:center">
      <div class="field"><label>Name of Account</label>
        <input type="text" id="op-name" maxlength="30" placeholder="Ranch Fund"></div>
      <div class="field"><label>Type</label>
        <select id="op-kind">
          <option value="checking">Checking</option>
          <option value="savings">Savings</option>
        </select></div>
      <button class="btn primary" id="op-go" ${n >= max ? 'disabled' : ''}>Open Account</button>
    </div>
    <p class="hint">Savings accounts earn ${((S.data?.config?.savingsAPR || 0) * 100).toFixed(1)}% interest, posted on a real-week schedule. Checking accounts do not bear interest.</p>
  `;
  $('#op-go').addEventListener('click', async () => {
    const res = await rpc('openAccount', {
      name: $('#op-name').value.trim(),
      kind: $('#op-kind').value,
    });
    if (!res.ok) return toast(errText(res.error), 'error');
    applySnapshot(res.data);
    toast('The clerk inks a fresh page. Account opened.');
    setView('overview');
  });
}

// ----------------------------------------------------------------- plumbing

function applySnapshot(data) {
  if (!data) return;
  if (data.accounts) S.data.accounts = data.accounts;
  if (data.wallet) S.data.wallet = data.wallet;
  renderHeader();
}

window.addEventListener('message', (e) => {
  const { action, data } = e.data || {};
  if (action === 'open') {
    S.data = data;
    S.open = true;
    S.view = 'overview';
    S.accountId = null;
    $('#app').classList.remove('hidden');
    setView('overview');
  } else if (action === 'close') {
    S.open = false;
    $('#app').classList.add('hidden');
  }
});

window.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && S.open) post('close');
});

$('#btn-close').addEventListener('click', () => post('close'));
document.querySelectorAll('.nav-btn').forEach((b) =>
  b.addEventListener('click', () => setView(b.dataset.view)));
