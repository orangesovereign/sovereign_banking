/* Sovereign Bank teller NUI — engraved-print dashboard.
   Protocol: { action, payload } in via window message; requests out via
   fetch → client/nui.lua → server RPC. The UI holds no authority: every
   number came from the server, every action is re-validated server-side. */

'use strict';

const RES = (typeof GetParentResourceName === 'function') ? GetParentResourceName() : 'sov_bank';
const PAGE_SIZE = 8;

const S = {
  open: false,
  mode: 'teller',    // 'teller' | 'admin'
  data: null,        // { accounts, wallet, branch, config }
  sel: null,         // selected account id
  page: 0,
  filter: '',
  rows: [],
  total: 0,
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
  ERR_NO_SOCIETY: 'You hold no position with any society.',
  ERR_NOT_BOSS: 'Only the head of the outfit may do that.',
  ERR_NO_BILL: 'No such bill on our books.',
  ERR_BILL_CLOSED: 'That bill is already settled.',
  ERR_PAYROLL_EMPTY: 'No hands were marked for pay.',
  ERR_LOANS_DISABLED: 'The bank is not lending at present.',
  ERR_LOAN_LIMIT: 'You already carry as much debt as the bank allows.',
  ERR_NO_LOAN: 'No such loan on our books.',
  ERR_LOAN_CLOSED: 'That loan is not open.',
  ERR_SDB_LIMIT: 'You rent as many boxes as the vault allows.',
  ERR_NO_SDB: 'No such box in our vault.',
  ERR_RENT_DUE: 'Rent is owed on that box — settle it to regain entry.',
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

/* Era dating: the server clock maps into the 1890s (year − 130). */
function fmtLedgerDate(epoch) {
  if (!epoch) return '—';
  const d = new Date(epoch * 1000);
  const md = d.toLocaleString('en-US', { month: 'short', day: 'numeric' });
  const t = d.toLocaleString('en-US', { hour: '2-digit', minute: '2-digit' });
  return `${md}, ${d.getFullYear() - 130} - ${t}`;
}

function fmtEraDate(epoch) {
  if (!epoch) return '—';
  const d = new Date(epoch * 1000);
  return `${d.toLocaleString('en-US', { month: 'short', day: 'numeric' })}, ${d.getFullYear() - 130}`;
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

function getAccount(id) {
  return (S.data?.accounts || []).find((a) => a.id === id) || null;
}

const canWithdraw = (a) => a && ['owner', 'admin', 'withdraw'].includes(a.access);
const canDeposit = (a) => a && ['owner', 'admin', 'withdraw', 'deposit'].includes(a.access);
const canAdmin = (a) => a && ['owner', 'admin'].includes(a.access);

function feeEstimate(minor, own) {
  const fees = S.data?.config?.fees || {};
  const cfg = own ? fees.same : fees.cross;
  if (!cfg) return 0;
  if (cfg.type === 'flat') return Math.floor(cfg.value || 0);
  if (cfg.type === 'percent') return Math.round(minor * (cfg.value || 0));
  return 0;
}

// ---------------------------------------------------------- engraved icons

const I = {
  bank: (cls = '') => `<svg class="${cls}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 9.2 L12 3.4 L21 9.2 Z"/><path d="M5 9.2 V17.6 M8.5 9.2 V17.6 M12 9.2 V17.6 M15.5 9.2 V17.6 M19 9.2 V17.6"/><path d="M3.4 17.6 H20.6 M2.6 19.8 H21.4"/><circle cx="12" cy="6.6" r="0.9"/></svg>`,
  piggy: (cls = '') => `<svg class="${cls}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round"><ellipse cx="11.3" cy="13.2" rx="7.6" ry="5.6"/><path d="M18.6 11.3 c1.5 0.2 2.4 1 2.4 2 c0 0.9 -0.7 1.6 -1.9 1.9"/><path d="M6.8 18.2 v2 M14.8 18.2 v2"/><path d="M8.7 7.9 c0.8 -1.2 2.4 -1.5 3.6 -0.9"/><path d="M9.4 6.6 h4.4"/><circle cx="7.6" cy="12" r="0.5" fill="currentColor"/><path d="M3.7 12.4 c-0.9 0.2 -1.3 0.9 -1.1 1.8"/></svg>`,
  coin: (cls = '') => `<svg class="${cls}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.2"><circle cx="12" cy="12" r="8.4"/><circle cx="12" cy="12" r="6.2" stroke-dasharray="2 1.6"/><text x="12" y="15.4" text-anchor="middle" font-family="Georgia, serif" font-size="9" fill="currentColor" stroke="none">R</text></svg>`,
  bag: (cls = '') => `<svg class="${cls}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round"><path d="M9.6 6.4 L8.2 3.6 h7.6 L14.4 6.4"/><path d="M9.6 6.4 h4.8 c3.2 1.9 5 4.8 5 8 c0 3.7 -3.2 5.9 -7.4 5.9 c-4.2 0 -7.4 -2.2 -7.4 -5.9 c0 -3.2 1.8 -6.1 5 -8 Z"/><path d="M12 10.2 v6.4 M10 11.6 c0 -0.9 0.9 -1.4 2 -1.4 c1.1 0 2 0.5 2 1.4 c0 2 -4 1.6 -4 3.6 c0 0.9 0.9 1.4 2 1.4 c1.1 0 2 -0.5 2 -1.4"/></svg>`,
  cash: (cls = '') => `<svg class="${cls}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="8.4" width="18" height="9.6" rx="0.8"/><ellipse cx="12" cy="13.2" rx="3" ry="2.3"/><path d="M5.2 6.4 h13.6 M7 4.6 h10"/><circle cx="6" cy="13.2" r="0.5" fill="currentColor"/><circle cx="18" cy="13.2" r="0.5" fill="currentColor"/></svg>`,
  transfer: (cls = '') => `<svg class="${cls}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"><path d="M4.4 8.6 H19 M19 8.6 l-3.2 -3.2 M19 8.6 l-3.2 3.2" transform="translate(0,-1)"/><path d="M19.6 16.4 H5 M5 16.4 l3.2 -3.2 M5 16.4 l3.2 3.2" transform="translate(0,1)"/></svg>`,
  bill: (cls = '') => `<svg class="${cls}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round"><path d="M6 3.4 h9 l4 4 V20.6 H6 Z"/><path d="M15 3.4 v4 h4"/><path d="M8.6 10 h7 M8.6 12.8 h7 M8.6 15.6 h4.4"/><circle cx="15.6" cy="17.6" r="1.5"/></svg>`,
  papers: (cls = '') => `<svg class="${cls}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="6" width="11.6" height="14.4"/><path d="M8 6 V3.6 H19.6 V18 H16"/><path d="M6.6 9.4 h6.4 M6.6 12.2 h6.4 M6.6 15 h6.4 M6.6 17.8 h4"/></svg>`,
  safe: (cls = '') => `<svg class="${cls}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round"><rect x="3.6" y="3.6" width="16.8" height="16.8" rx="0.8"/><rect x="6" y="6" width="12" height="12"/><circle cx="12" cy="12" r="2.8"/><path d="M12 9.2 v-1.4 M12 16.2 v-1.4 M9.2 12 h-1.4 M16.2 12 h-1.4"/><path d="M5 20.4 v1.6 M19 20.4 v1.6"/></svg>`,
  people: (cls = '') => `<svg class="${cls}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round"><circle cx="9" cy="8.6" r="2.9"/><path d="M3.6 19.4 c0 -3.4 2.4 -5.4 5.4 -5.4 c3 0 5.4 2 5.4 5.4"/><circle cx="16.6" cy="9.4" r="2.3"/><path d="M15.4 14.3 c2.9 0 5 1.9 5 5.1"/></svg>`,
  columns: (cls = '') => `<svg class="${cls}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 8 L12 3.6 L20 8 M4.8 8 H19.2"/><path d="M6.4 10 V16.4 M10.2 10 V16.4 M13.8 10 V16.4 M17.6 10 V16.4"/><path d="M4.6 18.4 H19.4 M3.8 20.4 H20.2"/></svg>`,
  key: (cls = '') => `<svg class="${cls}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round"><circle cx="8" cy="12" r="4.2"/><circle cx="8" cy="12" r="1.4"/><path d="M12.2 12 H20.6 M17.6 12 v3 M20.6 12 v2.2"/></svg>`,
  plus: (cls = '') => `<svg class="${cls}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="4" width="16" height="16"/><path d="M12 8.6 v6.8 M8.6 12 h6.8"/></svg>`,
  chev: (cls = '') => `<svg class="${cls}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M9 5.5 L15.5 12 L9 18.5"/></svg>`,
  goldbars: (cls = '') => `<svg class="${cls}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 13.6 h5.6 l1.6 4.6 H2.4 Z"/><path d="M13.4 13.6 h5.6 l1.6 4.6 h-8.8 Z"/><path d="M8.8 7.4 h5.6 l1.6 4.6 H7.2 Z"/><path d="M10.2 9.6 h3.2" stroke-width="0.8"/><path d="M5.6 15.8 h2.6 M15 15.8 h2.6" stroke-width="0.8"/></svg>`,
  branchArt: (cls = '') => `<svg class="${cls}" viewBox="0 0 150 96" fill="none" stroke="currentColor" stroke-width="1.1" stroke-linecap="round" stroke-linejoin="round">
    <path d="M75 8 L34 30 H116 Z"/><path d="M75 13 L44 28.6 H106 Z" stroke-width="0.8"/><circle cx="75" cy="23.5" r="2.6" stroke-width="0.8"/>
    <path d="M37 30 V34 H113 V30"/>
    <path d="M43 34 V70 M51 34 V70 M62 34 V70 M70 34 V70 M80 34 V70 M88 34 V70 M99 34 V70 M107 34 V70"/>
    <path d="M46.8 36.6 h56.4 M46.8 38.8 h56.4" stroke-width="0.7"/>
    <rect x="67" y="46" width="16" height="24" stroke-width="0.9"/><path d="M67 50 h16" stroke-width="0.7"/>
    <path d="M40 70 H110 M36 74 H114 M32 78 H118 M28 82 H122"/>
    <rect x="12" y="42" width="16" height="36" stroke-width="0.9"/><path d="M15.5 48 h9 v10 h-9 Z M15.5 63 h9 v10 h-9 Z" stroke-width="0.7"/>
    <rect x="122" y="42" width="16" height="36" stroke-width="0.9"/><path d="M125.5 48 h9 v10 h-9 Z M125.5 63 h9 v10 h-9 Z" stroke-width="0.7"/>
    <path d="M12 42 L20 36 L28 42 M122 42 L130 36 L138 42" stroke-width="0.9"/>
    <path d="M8 86 H142" stroke-width="1.3"/>
  </svg>`,
};

const KIND_ICON = { checking: I.bank, savings: I.piggy, society: I.people, business: I.papers };

// ------------------------------------------------------------------ header

function renderCash() {
  const w = S.data?.wallet || {};
  const goldOn = !!S.data?.config?.currencies?.gold;
  $('#cash-card').innerHTML = `
    <div class="cash-card">
      <span>Cash in Hand</span>
      <span style="text-align:right">
        <b>${fmt(w.money || 0)}</b>
        ${goldOn && (w.gold || 0) > 0 ? `<span class="gold-line"> · ${fmt(w.gold, 'gold')}</span>` : ''}
      </span>
    </div>`;
}

function renderAccounts() {
  const accounts = S.data?.accounts || [];
  if (!accounts.find((a) => a.id === S.sel)) S.sel = accounts[0]?.id ?? null;
  const goldOn = !!S.data?.config?.currencies?.gold;

  $('#acct-cards').innerHTML = accounts.map((a) => `
    <div class="acct-card ${a.id === S.sel ? 'selected' : ''}" data-id="${a.id}">
      <span class="acct-icon">${(KIND_ICON[a.kind] || I.bank)()}</span>
      <span class="acct-meta">
        <div class="acct-name">${esc(a.name)}${a.isOwner ? '' : '<span class="badge-mini">shared</span>'}</div>
        <div class="acct-number">№ ${esc(a.number)}</div>
      </span>
      <span class="acct-bal">${fmt(a.balances.money)}
        ${goldOn && (a.balances.gold || 0) > 0 ? `<span class="gold-line">${fmt(a.balances.gold, 'gold')}</span>` : ''}
      </span>
    </div>`).join('');

  document.querySelectorAll('.acct-card').forEach((el) =>
    el.addEventListener('click', () => selectAccount(Number(el.dataset.id))));

  const worth = (S.data?.wallet?.money || 0) +
    accounts.reduce((sum, a) => sum + (a.balances.money || 0), 0);
  $('#networth').textContent = fmt(worth);

  // account dropdown mirrors the cards
  $('#sel-account').innerHTML = accounts.map((a) =>
    `<option value="${a.id}" ${a.id === S.sel ? 'selected' : ''}>${esc(a.name.toUpperCase())} (${esc(a.number.replace('SVB-', ''))})</option>`).join('');
}

// ------------------------------------------------------------------ ledger

const FILTERS = [
  ['', 'All Transactions'], ['deposit', 'Deposits'], ['withdraw', 'Withdrawals'],
  ['transfer', 'Transfers'], ['fee', 'Fees'], ['interest', 'Interest'],
  ['add', 'Credits'], ['remove', 'Payments'],
];

function typeOf(row) {
  const cat = String(row.category || '').toLowerCase();
  if (cat === 'compensation' || cat === 'admin_adjust' || cat === 'adjust') {
    return [cat === 'compensation' ? 'REVERSAL' : 'ADJUSTMENT', 't-sys'];
  }
  if (cat === 'transfer') {
    return row.direction === 'credit' ? ['TRANSFER IN', 't-pos'] : ['TRANSFER OUT', 't-neg'];
  }
  const label = cat === 'add' ? 'CREDIT' : cat === 'remove' ? 'PAYMENT' : cat.toUpperCase().replace(/_/g, ' ');
  return [label || 'ENTRY', row.direction === 'credit' ? 't-pos' : 't-neg'];
}

async function loadLedger() {
  if (!S.sel) { S.rows = []; S.total = 0; renderLedger(); return; }
  const res = await rpc('statement', {
    accountId: S.sel, limit: PAGE_SIZE, offset: S.page * PAGE_SIZE,
    category: S.filter || null,
  });
  if (!res.ok) { toast(errText(res.error), 'error'); return; }
  S.rows = res.data.rows || [];
  S.total = res.data.total ?? S.rows.length;
  renderLedger();
}

function renderLedger() {
  const curName = (c) => (c === 1 ? 'gold' : c === 2 ? 'rol' : 'money');
  $('#ledger-rows').innerHTML = S.rows.length ? S.rows.map((r) => {
    const [label, cls] = typeOf(r);
    const sign = r.direction === 'credit' ? '+' : '-';
    return `<tr>
      <td>${fmtLedgerDate(r.created_at)}</td>
      <td>${esc(r.memo || label)}</td>
      <td><span class="t-type ${cls}">${esc(label)}</span></td>
      <td class="num ${r.direction === 'credit' ? 'amt-pos' : 'amt-neg'}">${sign}${fmt(r.amount, curName(r.currency))}</td>
      <td class="num">${r.balance_after != null ? fmt(r.balance_after, curName(r.currency)) : '—'}</td>
    </tr>`;
  }).join('')
    : `<tr><td colspan="5" class="ledger-empty">Nothing in the ledger yet.</td></tr>`;

  const from = S.total === 0 ? 0 : S.page * PAGE_SIZE + 1;
  const to = Math.min(S.total, (S.page + 1) * PAGE_SIZE);
  $('#ledger-count').textContent = `Showing ${from} to ${to} of ${S.total} transactions`;
  $('#pg-newer').disabled = S.page === 0;
  $('#pg-older').disabled = to >= S.total;
}

function selectAccount(id) {
  S.sel = id;
  S.page = 0;
  renderAccounts();
  loadLedger();
}

// ----------------------------------------------------------- right sidebar

function renderActions() {
  const openBills = S.data?.openBills || 0;
  const cfg = S.data?.config || {};
  const rows = [
    { icon: I.transfer, label: 'Transfer Funds', run: () => modalTransfer() },
    cfg.loans?.enabled
      ? { icon: I.columns, label: 'Request Loan', run: () => modalLoans() }
      : { icon: I.columns, label: 'Request Loan', soon: true },
    cfg.sdb
      ? { icon: I.safe, label: 'Safety Deposit Boxes', run: () => modalSDB() }
      : { icon: I.safe, label: 'Safety Deposit Boxes', soon: true },
    { icon: I.bill, label: 'Pay Bills / Taxes', run: () => modalBills(), badge: openBills },
    cfg.gold ? { icon: I.goldbars, label: 'Gold Exchange', run: () => modalGold() } : null,
    ...(S.data?.society
      ? [{ icon: I.people, label: S.data.society.name, run: () => modalSociety() }]
      : [{ icon: I.people, label: 'Society Accounts', soon: true }]),
    { icon: I.plus, label: 'Open New Account', run: () => modalOpenAccount() },
    { icon: I.key, label: 'Account Access', run: () => modalAccess() },
  ].filter(Boolean);
  $('#actions').innerHTML = rows.map((r, i) => `
    <button class="action-row ${r.soon ? 'soon' : ''}" data-i="${i}">
      <span class="a-icon">${r.icon()}</span>
      <span class="a-label">${esc(r.label)}</span>
      ${r.badge ? `<span class="a-badge">${r.badge}</span>` : ''}
      <span class="a-chev">${I.chev()}</span>
    </button>`).join('');
  document.querySelectorAll('.action-row').forEach((el) =>
    el.addEventListener('click', () => {
      const r = rows[Number(el.dataset.i)];
      if (r.soon) return toast('The clerk apologizes — that service is not yet offered at this counter.', 'error');
      r.run();
    }));
}

function renderBranch() {
  const b = S.data?.branch || {};
  const hours = Array.isArray(b.hours) ? b.hours : [];
  let hoursHtml = '';
  for (let i = 0; i + 1 < hours.length; i += 2) {
    hoursHtml += `<div class="bh-day">${esc(hours[i])}</div><div class="bh-time">${esc(hours[i + 1])}</div>`;
  }
  $('#branch-info').innerHTML = `
    ${I.branchArt('branch-art')}
    <div class="branch-name">${esc((b.name || '').replace(/^Bank of\s+/i, ''))}</div>
    <div class="branch-sub">${esc(b.subtitle || 'Branch')}</div>
    <div class="branch-hours">${hoursHtml}</div>`;
}

// ---------------------------------------------------------------- quickbar

function renderQuickActions() {
  const cfg = S.data?.config || {};
  const rows = [
    { icon: I.bag, label: 'Deposit', run: () => modalMove('deposit') },
    { icon: I.cash, label: 'Withdraw', run: () => modalMove('withdraw') },
    { icon: I.transfer, label: 'Transfer', run: () => modalTransfer() },
    { icon: I.bill, label: 'Pay Bill / Tax', run: () => modalBills() },
    cfg.loans?.enabled
      ? { icon: I.papers, label: 'View Loans', run: () => modalLoans() }
      : { icon: I.papers, label: 'View Loans', soon: true },
    cfg.sdb
      ? { icon: I.safe, label: 'SDB Access', run: () => modalSDB() }
      : { icon: I.safe, label: 'SDB Access', soon: true },
  ];
  $('#quick-actions').innerHTML = rows.map((r, i) => `
    <button class="qa-btn ${r.soon ? 'soon' : ''}" data-i="${i}">
      ${r.icon()}<span>${r.label}</span>
    </button>`).join('');
  document.querySelectorAll('.qa-btn').forEach((el) =>
    el.addEventListener('click', () => {
      const r = rows[Number(el.dataset.i)];
      if (r.soon) return toast('The clerk apologizes — that service is not yet offered at this counter.', 'error');
      r.run();
    }));
}

// ------------------------------------------------------------------ modals

function openModal(title, bodyHtml) {
  const root = $('#modal-root');
  root.classList.remove('hidden');
  root.innerHTML = `
    <div class="overlay"></div>
    <div class="modal">
      <div class="modal-head"><span>${title}</span><button class="m-close">✕</button></div>
      <div class="modal-body">${bodyHtml}</div>
    </div>`;
  root.querySelector('.m-close').addEventListener('click', closeModal);
  root.querySelector('.overlay').addEventListener('click', closeModal);
}

function closeModal() {
  const root = $('#modal-root');
  root.classList.add('hidden');
  root.innerHTML = '';
}

const modalIsOpen = () => !$('#modal-root').classList.contains('hidden');

function currencyChipsHtml(current) {
  return `<div class="currency-chips">${enabledCurrencies().map((k) =>
    `<button type="button" class="chip ${k === current ? 'active' : ''}" data-cur="${k}">
      ${k === 'money' ? 'Dollars' : k[0].toUpperCase() + k.slice(1)}</button>`).join('')}</div>`;
}

function wireChips(container, onPick) {
  container.querySelectorAll('.chip').forEach((c) =>
    c.addEventListener('click', () => {
      container.querySelectorAll('.chip').forEach((x) => x.classList.remove('active'));
      c.classList.add('active');
      onPick(c.dataset.cur);
    }));
}

function applySnapshot(data) {
  if (!data) return;
  if (data.accounts) S.data.accounts = data.accounts;
  if (data.wallet) S.data.wallet = data.wallet;
  if (data.openBills != null) S.data.openBills = data.openBills;
  renderCash();
  renderAccounts();
  renderActions();
}

/* Deposit / Withdraw against the selected account. */
function modalMove(kind) {
  const a = getAccount(S.sel);
  if (!a) return toast(errText('ERR_NO_ACCOUNT'), 'error');
  const allowed = kind === 'deposit' ? canDeposit(a) : canWithdraw(a);
  if (!allowed) return toast(errText('ERR_ACCESS'), 'error');

  let cur = 'money';
  const title = kind === 'deposit' ? 'Deposit — Cash to Ledger' : 'Withdraw — Ledger to Cash';
  openModal(title, `
    <p class="hint" style="margin-bottom:12px">
      ${esc(a.name)} · № ${esc(a.number)} — balance ${fmt(a.balances.money)}</p>
    <div class="form-row">
      <div class="field"><label>Currency</label>${currencyChipsHtml(cur)}</div>
      <div class="field"><label>Amount</label>
        <input type="text" id="mv-amt" inputmode="decimal" placeholder="0.00"></div>
      <button class="btn primary" id="mv-go">${kind === 'deposit' ? 'Deposit' : 'Withdraw'}</button>
    </div>`);

  wireChips($('#modal-root'), (k) => { cur = k; });
  $('#mv-amt').focus();
  $('#mv-go').addEventListener('click', async () => {
    const amount = toMinor($('#mv-amt').value);
    if (!amount) return toast(errText('ERR_BAD_AMOUNT'), 'error');
    const res = await rpc(kind, { accountId: a.id, currency: CUR[cur], amount });
    if (!res.ok) return toast(errText(res.error), 'error');
    applySnapshot(res.data);
    closeModal();
    toast(`${kind === 'deposit' ? 'Deposited' : 'Withdrew'} ${fmt(amount, cur)}.`);
    S.page = 0;
    loadLedger();
  });
}

function modalTransfer() {
  const sources = (S.data?.accounts || []).filter(canWithdraw);
  if (!sources.length) return toast(errText('ERR_ACCESS'), 'error');
  const own = S.data.accounts;
  let cur = 'money';

  openModal('Transfer Funds', `
    <div class="form-row">
      <div class="field"><label>From</label>
        <select id="tr-from">${sources.map((a) =>
          `<option value="${a.id}" ${a.id === S.sel ? 'selected' : ''}>${esc(a.name)} — ${esc(a.number)} (${fmt(a.balances.money)})</option>`).join('')}</select></div>
      <div class="field"><label>Currency</label>${currencyChipsHtml(cur)}</div>
    </div>
    <div class="form-row">
      <div class="field"><label>To — my account</label>
        <select id="tr-own"><option value="">—</option>${own.map((a) =>
          `<option value="${a.id}">${esc(a.name)} — ${esc(a.number)}</option>`).join('')}</select></div>
      <div class="field"><label>or account number</label>
        <input type="text" id="tr-num" placeholder="SVB-0000123"></div>
    </div>
    <div class="form-row">
      <div class="field"><label>Amount</label>
        <input type="text" id="tr-amt" inputmode="decimal" placeholder="0.00"></div>
      <div class="field" style="flex:1"><label>Memo</label>
        <input type="text" id="tr-memo" maxlength="120" placeholder="for the cattle" style="width:100%"></div>
    </div>
    <div class="form-row">
      <button class="btn primary" id="tr-send">Send by Wire</button>
    </div>
    <p class="hint" id="tr-fee">Transfers between your own accounts are free; wires to another
      holder carry the bank’s fee, which funds the government insurance on all deposits.</p>`);

  wireChips($('#modal-root'), (k) => { cur = k; });

  const feeLine = () => {
    const amt = toMinor($('#tr-amt').value) || 0;
    const isOwn = !$('#tr-num').value.trim() && $('#tr-own').value !== '';
    const fee = amt ? feeEstimate(amt, isOwn) : 0;
    if (amt) {
      $('#tr-fee').textContent =
        `Estimated fee: ${fmt(fee, cur)} ${isOwn ? '(own accounts)' : '(wire)'} — the teller will quote the exact figure.`;
    }
  };
  ['tr-amt', 'tr-num'].forEach((id) => $(`#${id}`).addEventListener('input', feeLine));
  $('#tr-own').addEventListener('change', feeLine);

  $('#tr-send').addEventListener('click', async () => {
    const amount = toMinor($('#tr-amt').value);
    if (!amount) return toast(errText('ERR_BAD_AMOUNT'), 'error');
    const toNumber = $('#tr-num').value.trim();
    const toId = $('#tr-own').value ? Number($('#tr-own').value) : null;
    if (!toNumber && !toId) return toast(errText('ERR_NO_ACCOUNT'), 'error');
    const res = await rpc('transfer', {
      fromId: Number($('#tr-from').value),
      toId: toNumber ? null : toId,
      toNumber: toNumber || null,
      currency: CUR[cur],
      amount,
      memo: $('#tr-memo').value.trim() || null,
    });
    if (!res.ok) return toast(errText(res.error), 'error');
    applySnapshot(res.data);
    closeModal();
    const fee = res.data?.result?.fee || 0;
    toast(`Sent ${fmt(amount, cur)}${fee ? ` (fee ${fmt(fee, cur)})` : ''}.`);
    S.page = 0;
    loadLedger();
  });
}

function modalOpenAccount() {
  const n = (S.data?.accounts || []).filter((a) => a.isOwner).length;
  const max = S.data?.config?.maxAccounts || 4;
  openModal('Open a New Account', `
    <p class="hint">You hold ${n} of ${max} accounts the bank permits.</p>
    <div class="form-row" style="margin-top:12px">
      <div class="field"><label>Name of Account</label>
        <input type="text" id="op-name" maxlength="30" placeholder="Ranch Fund"></div>
      <div class="field"><label>Type</label>
        <select id="op-kind">
          <option value="checking">Checking</option>
          <option value="savings">Savings</option>
        </select></div>
      <button class="btn primary" id="op-go" ${n >= max ? 'disabled' : ''}>Open</button>
    </div>
    <p class="hint">Savings accounts earn ${((S.data?.config?.savingsAPR || 0) * 100).toFixed(1)}%
      interest, posted on a real-week schedule. Checking accounts do not bear interest.</p>`);
  $('#op-go').addEventListener('click', async () => {
    const res = await rpc('openAccount', { name: $('#op-name').value.trim(), kind: $('#op-kind').value });
    if (!res.ok) return toast(errText(res.error), 'error');
    applySnapshot(res.data);
    if (res.data.created) S.sel = res.data.created;
    closeModal();
    toast('The clerk inks a fresh page. Account opened.');
    renderAccounts();
    S.page = 0;
    loadLedger();
  });
}

async function modalAccess() {
  const a = getAccount(S.sel);
  if (!a) return toast(errText('ERR_NO_ACCOUNT'), 'error');
  if (!canAdmin(a)) return toast(errText('ERR_ACCESS'), 'error');

  openModal(`Account Access — ${esc(a.name)}`, '<p class="hint">Fetching the register…</p>');
  const res = await rpc('accountAccess', { accountId: a.id });
  if (!res.ok) { closeModal(); return toast(errText(res.error), 'error'); }
  if (!modalIsOpen()) return;

  const rows = res.data.rows || [];
  const myLevel = res.data.myLevel;
  const grantable = myLevel === 'owner'
    ? ['read', 'deposit', 'withdraw', 'admin'] : ['read', 'deposit', 'withdraw'];
  const empty = Object.values(a.balances).every((v) => (v || 0) === 0);

  $('#modal-root .modal-body').innerHTML = `
    <div class="form-row">
      <div class="field"><label>Character ID</label>
        <input type="text" id="acc-char" inputmode="numeric" placeholder="e.g. 42"></div>
      <div class="field"><label>Access</label>
        <select id="acc-level">${grantable.map((l) => `<option value="${l}">${l}</option>`).join('')}</select></div>
      <button class="btn primary" id="acc-grant">Grant</button>
    </div>
    <p class="hint">Access is hierarchical: withdraw includes deposit; admin manages non-admin
      access. Only the owner may appoint admins.</p>
    <div style="margin:14px 0 18px">
      ${rows.map((r) => `
        <div class="access-row">
          <span><b>${esc(r.charid)}</b>
            <span class="badge ${r.isOwner ? 'owner' : ''}">${r.isOwner ? 'holder' : esc(r.level)}</span></span>
          ${r.isOwner ? '' : `<button class="btn slim danger" data-revoke="${esc(r.charid)}">Revoke</button>`}
        </div>`).join('')}
    </div>
    ${a.isOwner ? `
      <div style="border-top:1px solid var(--line-soft);padding-top:14px">
        <button class="btn danger" id="acc-close" ${empty ? '' : 'disabled'}>Close this Account</button>
        <p class="hint">${empty ? 'This account is empty and may be closed. The ledger history is retained.'
          : 'Withdraw or transfer every balance before closing.'}</p>
      </div>` : ''}`;

  $('#acc-grant').addEventListener('click', async () => {
    const charid = $('#acc-char').value.trim();
    if (!charid) return toast(errText('ERR_UNKNOWN_CHAR'), 'error');
    const r = await rpc('grantAccess', { accountId: a.id, charid, level: $('#acc-level').value });
    if (!r.ok) return toast(errText(r.error), 'error');
    toast('Access recorded.');
    modalAccess();
  });
  document.querySelectorAll('[data-revoke]').forEach((el) =>
    el.addEventListener('click', async () => {
      const r = await rpc('revokeAccess', { accountId: a.id, charid: el.dataset.revoke });
      if (!r.ok) return toast(errText(r.error), 'error');
      toast('Access struck from the register.');
      modalAccess();
    }));
  $('#acc-close')?.addEventListener('click', async () => {
    const r = await rpc('closeAccount', { accountId: a.id });
    if (!r.ok) return toast(errText(r.error), 'error');
    applySnapshot(r.data);
    closeModal();
    toast('Account closed.');
    S.sel = null;
    renderAccounts();
    S.page = 0;
    loadLedger();
  });
}

/* Bills — open invoices, fines and taxes, settled at the counter. */
const BILL_STAMP = { invoice: '', fine: 'neg', tax: 'gold' };

async function modalBills() {
  openModal('Bills, Fines & Taxes', '<p class="hint">The clerk thumbs through the register…</p>');
  const res = await rpc('bills');
  if (!res.ok) { closeModal(); return toast(errText(res.error), 'error'); }
  if (!modalIsOpen()) return;
  renderBillsBody(res.data.rows || []);
}

function renderBillsBody(rows) {
  const paySources = [
    { v: 'wallet', label: `Cash in hand (${fmt(S.data?.wallet?.money || 0)})` },
    ...(S.data?.accounts || []).filter(canWithdraw).map((a) =>
      ({ v: a.id, label: `${a.name} — ${a.number} (${fmt(a.balances.money)})` })),
  ];
  $('#modal-root .modal-body').innerHTML = rows.length ? `
    ${rows.map((b) => `
      <div class="bill-row" data-bill="${b.id}">
        <div class="bill-main">
          <span class="badge bill-stamp ${BILL_STAMP[b.kind] || ''}">${esc(b.kind)}</span>
          <span class="bill-meta">
            <b>${esc(b.issuer)}</b>${b.memo ? ` — ${esc(b.memo)}` : ''}
            <span class="bill-sub">${esc(b.status).replace('_', ' ')} ·
              due ${fmtLedgerDate(b.dueAt)}</span>
          </span>
          <span class="bill-amt">${fmt(b.remaining, b.currency === 1 ? 'gold' : 'money')}</span>
        </div>
        <div class="bill-pay">
          <select class="bp-src">${paySources.map((s) =>
            `<option value="${s.v}">${esc(s.label)}</option>`).join('')}</select>
          <input type="text" class="bp-amt" inputmode="decimal"
            value="${((b.remaining || 0) / 100).toFixed(2)}" title="Amount to pay">
          <button class="btn slim primary bp-go">Pay</button>
        </div>
      </div>`).join('')}
    <p class="hint">Partial payments are accepted; the remainder stays on the books.
      Unpaid government debt finds its way to the law.</p>`
    : '<p class="hint" style="text-align:center;padding:20px 0">Nothing owed. The clerk seems almost disappointed.</p>';

  document.querySelectorAll('.bill-row .bp-go').forEach((btn) =>
    btn.addEventListener('click', async () => {
      const row = btn.closest('.bill-row');
      const amount = toMinor(row.querySelector('.bp-amt').value);
      if (!amount) return toast(errText('ERR_BAD_AMOUNT'), 'error');
      const src = row.querySelector('.bp-src').value;
      const res = await rpc('payBill', {
        billId: Number(row.dataset.bill),
        payWith: src === 'wallet' ? 'wallet' : Number(src),
        amount,
      });
      if (!res.ok) return toast(errText(res.error), 'error');
      applySnapshot(res.data);
      toast(res.data.result.closed
        ? 'Debt settled. The clerk stamps the bill PAID.'
        : `Paid ${fmt(res.data.result.applied)} — ${fmt(res.data.result.remaining)} remains.`);
      renderBillsBody(res.data.bills || []);
      S.page = 0;
      loadLedger();
    }));
}

/* Society desk — fund overview for members, full controls for the boss. */
async function modalSociety() {
  const socMeta = S.data?.society;
  if (!socMeta) return toast(errText('ERR_NO_SOCIETY'), 'error');
  openModal(esc(socMeta.name), '<p class="hint">The clerk fetches the society ledger…</p>');
  const res = await rpc('society');
  if (!res.ok) { closeModal(); return toast(errText(res.error), 'error'); }
  if (!modalIsOpen()) return;
  renderSocietyBody(res.data);
}

function renderSocietyBody(d) {
  const bossBlock = d.isBoss ? `
    <div class="form-row" style="margin-top:16px">
      <div class="field"><label>Amount</label>
        <input type="text" id="soc-amt" inputmode="decimal" placeholder="0.00"></div>
      <button class="btn" id="soc-dep">Deposit</button>
      <button class="btn" id="soc-wd">Withdraw</button>
    </div>
    <div class="col-head" style="margin-top:14px">Payroll</div>
    ${(d.roster || []).length ? `
      <table class="payroll">
        <thead><tr><th></th><th>Hand</th><th>Grade</th><th class="num">Wage</th></tr></thead>
        <tbody>
          ${d.roster.map((m, i) => `
            <tr>
              <td><input type="checkbox" class="pr-on" data-i="${i}" checked></td>
              <td>${esc(m.name)}<span class="bill-sub" style="display:inline;margin-left:8px">#${esc(m.charid)}</span></td>
              <td>${esc(String(m.grade))}</td>
              <td class="num"><input type="text" class="pr-amt" data-i="${i}"
                inputmode="decimal" placeholder="0.00" style="min-width:80px;width:80px;text-align:right"></td>
            </tr>`).join('')}
        </tbody>
      </table>
      <div class="form-row" style="margin-top:12px">
        <button class="btn primary" id="pr-run">Run Payroll</button>
        <span class="hint" id="pr-total" style="align-self:center">Total: $0.00</span>
      </div>
      <p class="hint">Wages are paid into each hand's bank account — present or not,
        their money will be waiting at the counter.</p>`
      : '<p class="hint">No hands on the books for this outfit.</p>'}
    ${(d.recent || []).length ? `
      <div class="col-head" style="margin-top:14px">Recent Entries</div>
      ${d.recent.map((r) => `
        <div class="access-row">
          <span>${fmtLedgerDate(r.created_at)} — ${esc(r.memo || r.category)}</span>
          <b class="${r.direction === 'credit' ? 'amt-pos' : 'amt-neg'}">
            ${r.direction === 'credit' ? '+' : '-'}${fmt(r.amount)}</b>
        </div>`).join('')}` : ''}`
    : '<p class="hint">Only the head of the outfit may move these funds.</p>';

  $('#modal-root .modal-body').innerHTML = `
    <div class="detail-head" style="margin-bottom:6px">
      <div>
        <div class="acct-name" style="font-size:13px">${esc(d.name)}</div>
        <div class="acct-number">№ ${esc(d.account.number)}</div>
      </div>
      <div class="detail-balance"><div class="money">${fmt(d.account.balance)}</div></div>
    </div>
    ${bossBlock}`;

  if (!d.isBoss) return;

  const refresh = async () => {
    const r = await rpc('society');
    if (r.ok && modalIsOpen()) renderSocietyBody(r.data);
  };

  $('#soc-dep')?.addEventListener('click', async () => {
    const amount = toMinor($('#soc-amt').value);
    if (!amount) return toast(errText('ERR_BAD_AMOUNT'), 'error');
    const res = await rpc('societyDeposit', { amount });
    if (!res.ok) return toast(errText(res.error), 'error');
    applySnapshot(res.data);
    toast(`Deposited ${fmt(amount)} to the fund.`);
    refresh();
  });
  $('#soc-wd')?.addEventListener('click', async () => {
    const amount = toMinor($('#soc-amt').value);
    if (!amount) return toast(errText('ERR_BAD_AMOUNT'), 'error');
    const res = await rpc('societyWithdraw', { amount });
    if (!res.ok) return toast(errText(res.error), 'error');
    applySnapshot(res.data);
    toast(`Withdrew ${fmt(amount)} from the fund.`);
    refresh();
  });

  const totalLine = () => {
    let total = 0;
    document.querySelectorAll('.pr-on:checked').forEach((cb) => {
      total += toMinor(document.querySelector(`.pr-amt[data-i="${cb.dataset.i}"]`)?.value) || 0;
    });
    $('#pr-total').textContent = `Total: ${fmt(total)}`;
    return total;
  };
  document.querySelectorAll('.pr-amt, .pr-on').forEach((el) => {
    el.addEventListener('input', totalLine);
    el.addEventListener('change', totalLine);
  });

  $('#pr-run')?.addEventListener('click', async () => {
    const entries = [];
    document.querySelectorAll('.pr-on:checked').forEach((cb) => {
      const i = Number(cb.dataset.i);
      const amount = toMinor(document.querySelector(`.pr-amt[data-i="${i}"]`)?.value);
      if (amount) entries.push({ charid: d.roster[i].charid, amount });
    });
    if (!entries.length) return toast(errText('ERR_PAYROLL_EMPTY'), 'error');
    const res = await rpc('societyPayroll', { entries });
    if (!res.ok) return toast(errText(res.error), 'error');
    applySnapshot(res.data);
    toast(`Payroll run — ${fmt(res.data.result.total)} to ${res.data.result.paid.length} hands.`);
    S.page = 0;
    loadLedger();
    refresh();
  });
}

/* Loans — fixed-cost: the whole obligation is known before signing. */
const LOAN_STAMP = { pending: 'gold', active: '', defaulted: 'neg', paid: '', denied: 'neg' };

function paySourcesHtml() {
  return [
    { v: 'wallet', label: `Cash in hand (${fmt(S.data?.wallet?.money || 0)})` },
    ...(S.data?.accounts || []).filter(canWithdraw).map((a) =>
      ({ v: a.id, label: `${a.name} — ${a.number} (${fmt(a.balances.money)})` })),
  ].map((s) => `<option value="${s.v}">${esc(s.label)}</option>`).join('');
}

async function modalLoans() {
  const cfg = S.data?.config?.loans;
  if (!cfg?.enabled) return toast(errText('ERR_LOANS_DISABLED'), 'error');
  openModal('Loans', '<p class="hint">The clerk opens the loan book…</p>');
  const res = await rpc('loans');
  if (!res.ok) { closeModal(); return toast(errText(res.error), 'error'); }
  if (!modalIsOpen()) return;
  renderLoansBody(res.data.rows || []);
}

function renderLoansBody(rows) {
  const cfg = S.data.config.loans;
  const ownAccounts = (S.data.accounts || []).filter((a) => a.isOwner);
  const hasOpen = rows.some((l) => l.status === 'pending' || l.status === 'active');

  $('#modal-root .modal-body').innerHTML = `
    ${rows.length ? rows.map((l) => `
      <div class="bill-row" data-loan="${l.id}">
        <div class="bill-main">
          <span class="badge bill-stamp ${LOAN_STAMP[l.status] || ''}">${esc(l.status)}</span>
          <span class="bill-meta">
            <b>Loan №${l.id}</b> — borrowed ${fmt(l.principal)}, owes ${fmt(l.totalDue)}
            <span class="bill-sub">${l.dueBy ? `due ${fmtEraDate(l.dueBy)} · ` : ''}filed ${fmtEraDate(l.createdAt)}</span>
          </span>
          <span class="bill-amt">${fmt(l.remaining)}</span>
        </div>
        ${(l.status === 'active' || l.status === 'defaulted') ? `
          <div class="bill-pay">
            <select class="lp-src">${paySourcesHtml()}</select>
            <input type="text" class="lp-amt" inputmode="decimal"
              value="${((l.remaining || 0) / 100).toFixed(2)}" title="Amount to repay">
            <button class="btn slim primary lp-go">Repay</button>
          </div>` : ''}
      </div>`).join('')
      : '<p class="hint" style="text-align:center;padding:8px 0">No loans on your page of the book.</p>'}

    ${hasOpen ? '' : `
      <div class="col-head" style="margin-top:16px">Apply for a Loan</div>
      <div class="form-row" style="margin-top:10px">
        <div class="field"><label>Principal (max ${fmt(cfg.maxPrincipal)})</label>
          <input type="text" id="ln-amt" inputmode="decimal" placeholder="0.00"></div>
        <div class="field"><label>Paid into</label>
          <select id="ln-acct">${ownAccounts.map((a) =>
            `<option value="${a.id}">${esc(a.name)} — ${esc(a.number)}</option>`).join('')}</select></div>
        <button class="btn primary" id="ln-go">Apply</button>
      </div>
      <p class="hint" id="ln-preview">The bank charges ${(cfg.rate * 100).toFixed(0)}% at origination —
        no further interest accrues.${cfg.termDays > 0 ? ` Repayment is due within ${cfg.termDays} real days.` : ''}</p>`}`;

  document.querySelectorAll('.lp-go').forEach((btn) =>
    btn.addEventListener('click', async () => {
      const row = btn.closest('.bill-row');
      const amount = toMinor(row.querySelector('.lp-amt').value);
      if (!amount) return toast(errText('ERR_BAD_AMOUNT'), 'error');
      const src = row.querySelector('.lp-src').value;
      const res = await rpc('repayLoan', {
        loanId: Number(row.dataset.loan),
        payWith: src === 'wallet' ? 'wallet' : Number(src),
        amount,
      });
      if (!res.ok) return toast(errText(res.error), 'error');
      applySnapshot(res.data);
      toast(res.data.result.closed
        ? 'Loan settled in full. The clerk closes the entry with a flourish.'
        : `Repaid ${fmt(res.data.result.applied)} — ${fmt(res.data.result.remaining)} remains.`);
      renderLoansBody(res.data.loans || []);
      S.page = 0;
      loadLedger();
    }));

  const amtEl = $('#ln-amt');
  if (amtEl) {
    amtEl.addEventListener('input', () => {
      const p = toMinor(amtEl.value);
      if (p) {
        const total = p + Math.round(p * cfg.rate);
        $('#ln-preview').textContent =
          `Borrow ${fmt(p)}, owe ${fmt(total)} — the bank's ${(cfg.rate * 100).toFixed(0)}% is fixed at signing.`
          + (cfg.termDays > 0 ? ` Due within ${cfg.termDays} real days of approval.` : '');
      }
    });
    $('#ln-go').addEventListener('click', async () => {
      const amount = toMinor(amtEl.value);
      if (!amount) return toast(errText('ERR_BAD_AMOUNT'), 'error');
      const res = await rpc('applyLoan', { amount, accountId: Number($('#ln-acct').value) });
      if (!res.ok) return toast(errText(res.error), 'error');
      applySnapshot(res.data);
      toast(res.data.result.status === 'active'
        ? `Approved on the spot — ${fmt(amount)} credited.`
        : 'Application filed. The bank will consider it.');
      renderLoansBody(res.data.loans || []);
      S.page = 0;
      loadLedger();
    });
  }
}

/* Safety deposit boxes — rented drawers in the branch vault. */
async function modalSDB() {
  const cfg = S.data?.config?.sdb;
  if (!cfg) return toast('The clerk apologizes — the vault is not letting boxes at present.', 'error');
  openModal('Safety Deposit Boxes', '<p class="hint">The clerk fetches the vault register…</p>');
  const res = await rpc('sdbList');
  if (!res.ok) { closeModal(); return toast(errText(res.error), 'error'); }
  if (!modalIsOpen()) return;
  renderSdbBody(res.data.rows || []);
}

function renderSdbBody(rows) {
  const cfg = S.data.config.sdb;
  const sizes = Object.keys(cfg.sizes || {});
  const canRentMore = rows.length < (cfg.maxPerChar || 2);

  $('#modal-root .modal-body').innerHTML = `
    ${rows.length ? rows.map((b) => `
      <div class="bill-row" data-box="${b.id}">
        <div class="bill-main">
          <span class="badge bill-stamp ${b.locked ? 'neg' : ''}">${b.locked ? 'rent due' : esc(b.size)}</span>
          <span class="bill-meta">
            <b>Box №${b.id}</b>
            <span class="bill-sub">rent paid through ${fmtEraDate(b.paidUntil)}</span>
          </span>
          <span style="display:flex;gap:8px">
            <button class="btn slim sdb-rent">Pay Rent (${fmt((cfg.rent || {})[b.size] || 0)})</button>
            <button class="btn slim primary sdb-open" ${b.locked ? 'disabled' : ''}>Open</button>
          </span>
        </div>
      </div>`).join('')
      : '<p class="hint" style="text-align:center;padding:8px 0">You rent no boxes with us.</p>'}

    ${canRentMore ? `
      <div class="col-head" style="margin-top:16px">Rent a Box</div>
      <div class="form-row" style="margin-top:10px">
        <div class="field"><label>Size</label>
          <select id="sdb-size">${sizes.map((s) =>
            `<option value="${s}">${s[0].toUpperCase() + s.slice(1)} — ${cfg.sizes[s].slots} slots,
             ${fmt((cfg.rent || {})[s] || 0)} / ${cfg.periodDays} days</option>`).join('')}</select></div>
        <button class="btn primary" id="sdb-new">Rent</button>
      </div>
      <p class="hint">Rent is paid from your cash in hand. A box left behind on
        rent locks until it is settled.</p>`
      : `<p class="hint" style="margin-top:12px">The vault allows at most ${cfg.maxPerChar} boxes per customer.</p>`}`;

  document.querySelectorAll('.sdb-open').forEach((btn) =>
    btn.addEventListener('click', async () => {
      const boxId = Number(btn.closest('.bill-row').dataset.box);
      const res = await rpc('sdbOpen', { boxId });
      if (!res.ok) return toast(errText(res.error), 'error');
      // The vault drawer opens as the teller UI closes.
      post('close');
    }));
  document.querySelectorAll('.sdb-rent').forEach((btn) =>
    btn.addEventListener('click', async () => {
      const boxId = Number(btn.closest('.bill-row').dataset.box);
      const res = await rpc('sdbPayRent', { boxId });
      if (!res.ok) return toast(errText(res.error), 'error');
      applySnapshot(res.data);
      toast('Rent recorded. The vault keeps your secrets a while longer.');
      renderSdbBody(res.data.boxes || []);
    }));
  $('#sdb-new')?.addEventListener('click', async () => {
    const res = await rpc('sdbRent', { size: $('#sdb-size').value });
    if (!res.ok) return toast(errText(res.error), 'error');
    applySnapshot(res.data);
    toast('Box rented. The clerk hands over a small brass key.');
    renderSdbBody(res.data.boxes || []);
  });
}

/* Gold exchange — the assayer's counter. */
function modalGold() {
  const q = S.data?.config?.gold;
  if (!q) return toast('The assayer is away from the counter.', 'error');

  openModal('Gold Exchange', `
    <p class="hint" style="margin-bottom:4px">The bank <b>sells</b> gold at ${fmt(q.buy)}
      and <b>buys</b> at ${fmt(q.sell)}, per 1.00 gold.</p>
    <div class="form-row" style="margin-top:12px">
      <div class="field"><label>Gold amount</label>
        <input type="text" id="gx-amt" inputmode="decimal" placeholder="0.00"></div>
      <button class="btn primary" id="gx-buy">Buy Gold</button>
      <button class="btn" id="gx-sell">Sell Gold</button>
    </div>
    <p class="hint" id="gx-line">Enter an amount to see the assayer's figures.</p>`);

  const line = () => {
    const g = toMinor($('#gx-amt').value);
    if (!g) return;
    const q2 = S.data.config.gold;
    $('#gx-line').textContent =
      `${(g / 100).toFixed(2)} gold: costs ${fmt(Math.round(g * q2.buy / 100))} to buy · ` +
      `fetches ${fmt(Math.round(g * q2.sell / 100))} sold.`;
  };
  $('#gx-amt').addEventListener('input', line);

  const go = async (direction) => {
    const gold = toMinor($('#gx-amt').value);
    if (!gold) return toast(errText('ERR_BAD_AMOUNT'), 'error');
    const res = await rpc('goldExchange', { direction, gold });
    if (!res.ok) return toast(errText(res.error), 'error');
    if (res.data.quote) S.data.config.gold = res.data.quote;
    applySnapshot(res.data);
    const r = res.data.result;
    toast(direction === 'buy'
      ? `Bought ${(r.gold / 100).toFixed(2)} gold for ${fmt(r.money)}.`
      : `Sold ${(r.gold / 100).toFixed(2)} gold for ${fmt(r.money)}.`);
    line();
  };
  $('#gx-buy').addEventListener('click', () => go('buy'));
  $('#gx-sell').addEventListener('click', () => go('sell'));
}

// ------------------------------------------------------------- admin panel

const A = { data: null, accounts: [] };

function renderAdminSupply() {
  const s = A.data?.supply;
  if (!s) return;
  const flows = (s.flows || []).slice(0, 8);
  const peak = Math.max(1, ...flows.map((f) => Math.max(+f.credited || 0, +f.debited || 0)));

  $('#admin-supply').innerHTML = `
    <div class="stat-block">
      <div class="stat-row"><span class="s-label">Total banked</span>
        <span class="s-value">${fmt(s.banked.money)}</span></div>
      ${s.banked.gold ? `<div class="stat-row"><span class="s-label">Gold on deposit</span>
        <span class="s-value">${fmt(s.banked.gold, 'gold')}</span></div>` : ''}
      <div class="stat-row"><span class="s-label">Open accounts</span>
        <span class="s-value">${s.banked.accounts}</span></div>
      <div class="stat-row"><span class="s-label">Loans outstanding</span>
        <span class="s-value">${fmt(s.loans.outstanding)}</span></div>
      <div class="stat-row"><span class="s-label">Unpaid debt</span>
        <span class="s-value">${fmt(s.debt.owed)}</span></div>
    </div>

    <div class="stat-head">Public Funds</div>
    ${(s.system || []).map((sys) => `
      <div class="stat-row"><span class="s-label">${esc(sys.key.replace('SYS-', ''))}</span>
        <span class="s-value">${fmt(sys.money)}</span></div>`).join('')}

    <div class="stat-head">Holdings by Type</div>
    ${(s.byOwner || []).map((o) => `
      <div class="stat-row"><span class="s-label">${esc(o.owner_type)} (${o.n})</span>
        <span class="s-value">${fmt(o.money)}</span></div>`).join('')}

    <div class="stat-head">Faucets &amp; Sinks · ${s.windowDays} days</div>
    ${flows.map((f) => `
      <div style="padding:7px 2px;border-bottom:1px solid var(--line-soft)">
        <div class="stat-row" style="border:none;padding:0">
          <span class="s-label">${esc(f.category)}</span>
          <span class="s-value" style="font-size:12px">
            <span class="amt-pos">+${fmt(f.credited)}</span>
            <span class="amt-neg">−${fmt(f.debited)}</span></span>
        </div>
        <div class="flow-bar">
          <span class="in" style="width:${(+f.credited / peak) * 50}%"></span>
          <span class="out" style="width:${(+f.debited / peak) * 50}%"></span>
        </div>
      </div>`).join('')}`;
}

function renderAdminAccounts() {
  const rows = A.accounts;
  $('#admin-accounts').innerHTML = rows.length ? `
    <table class="admin-accts">
      <thead><tr><th>Number</th><th>Name</th><th>Owner</th><th>Status</th>
        <th class="num">Balance</th><th></th></tr></thead>
      <tbody>
        ${rows.map((a) => `
          <tr data-acct="${a.id}">
            <td>${esc(a.number)}</td>
            <td>${esc(a.name)}<div class="bill-sub">${esc(a.kind)}</div></td>
            <td>${esc(a.ownerType)}<div class="bill-sub">${esc(a.ownerId)}</div></td>
            <td class="st-${esc(a.status)}">${esc(a.status)}</td>
            <td class="num">${fmt(a.balances.money)}
              ${a.balances.gold ? `<div class="bill-sub">${fmt(a.balances.gold, 'gold')}</div>` : ''}</td>
            <td style="white-space:nowrap;text-align:right">
              ${a.status !== 'closed' ? `
                <button class="btn slim adm-freeze">${a.status === 'frozen' ? 'Thaw' : 'Freeze'}</button>
                <button class="btn slim adm-adjust">Adjust</button>` : ''}
            </td>
          </tr>`).join('')}
      </tbody>
    </table>`
    : '<p class="hint" style="text-align:center;padding:24px 0">No accounts match that search.</p>';

  document.querySelectorAll('.adm-freeze').forEach((btn) =>
    btn.addEventListener('click', async () => {
      const id = Number(btn.closest('tr').dataset.acct);
      const acct = rows.find((a) => a.id === id);
      const res = await rpc('adminSetStatus', {
        accountId: id, status: acct.status === 'frozen' ? 'active' : 'frozen',
      });
      if (!res.ok) return toast(errText(res.error), 'error');
      acct.status = res.data.result.status;
      toast(`Account ${acct.number} is now ${acct.status}.`);
      renderAdminAccounts();
    }));

  document.querySelectorAll('.adm-adjust').forEach((btn) =>
    btn.addEventListener('click', () => {
      const id = Number(btn.closest('tr').dataset.acct);
      modalAdjust(rows.find((a) => a.id === id));
    }));
}

function modalAdjust(acct) {
  if (!acct) return;
  openModal(`Adjust ${esc(acct.number)}`, `
    <p class="hint">${esc(acct.name)} — currently ${fmt(acct.balances.money)}.
      Adjustments are written to the ledger as <b>admin_adjust</b> naming you.</p>
    <div class="form-row" style="margin-top:14px">
      <div class="field"><label>Amount</label>
        <input type="text" id="adj-amt" inputmode="decimal" placeholder="0.00"></div>
      <div class="field"><label>Currency</label>
        <select id="adj-cur"><option value="0">Dollars</option><option value="1">Gold</option></select></div>
      <button class="btn primary" id="adj-add">Credit</button>
      <button class="btn danger" id="adj-sub">Debit</button>
    </div>
    <div class="form-row">
      <div class="field" style="flex:1"><label>Reason (recorded)</label>
        <input type="text" id="adj-why" maxlength="80" placeholder="restitution for lost wages" style="width:100%"></div>
    </div>`);

  const go = async (sign) => {
    const amount = toMinor($('#adj-amt').value);
    if (!amount) return toast(errText('ERR_BAD_AMOUNT'), 'error');
    const res = await rpc('adminAdjust', {
      accountId: acct.id,
      currency: Number($('#adj-cur').value),
      delta: sign * amount,
      reason: $('#adj-why').value.trim() || null,
    });
    if (!res.ok) return toast(errText(res.error), 'error');
    closeModal();
    toast(`Ledger adjusted by ${sign < 0 ? '−' : '+'}${fmt(amount)}.`);
    adminSearch($('#adm-search').value);
  };
  $('#adj-add').addEventListener('click', () => go(1));
  $('#adj-sub').addEventListener('click', () => go(-1));
}

function renderAdminLoans() {
  const rows = A.data?.pendingLoans || [];
  $('#admin-loans').innerHTML = rows.length ? rows.map((l) => `
    <div class="access-row" data-loan="${l.id}" style="align-items:flex-start">
      <span>
        <b>${esc(l.name || l.charid)}</b>
        <div class="bill-sub">asks ${fmt(l.principal)} · owes ${fmt(l.totalDue)}</div>
      </span>
      <span style="white-space:nowrap">
        <button class="btn slim primary adm-loan-ok">Approve</button>
        <button class="btn slim danger adm-loan-no">Deny</button>
      </span>
    </div>`).join('')
    : '<p class="hint">No applications awaiting a decision.</p>';

  const decide = async (btn, decision) => {
    const loanId = Number(btn.closest('[data-loan]').dataset.loan);
    const res = await rpc('adminLoanDecision', { loanId, decision });
    if (!res.ok) return toast(errText(res.error), 'error');
    A.data.pendingLoans = res.data.pendingLoans || [];
    toast(decision === 'approve' ? 'Approved and disbursed.' : 'Application denied.');
    renderAdminLoans();
  };
  document.querySelectorAll('.adm-loan-ok').forEach((b) =>
    b.addEventListener('click', () => decide(b, 'approve')));
  document.querySelectorAll('.adm-loan-no').forEach((b) =>
    b.addEventListener('click', () => decide(b, 'deny')));
}

function renderAdminReserves() {
  const rows = A.data?.supply?.reserves || [];
  $('#admin-reserves').innerHTML = rows.length ? rows.map((r) => {
    const pct = Math.max(0, Math.min(100, (+r.balance / Math.max(1, +r.cap)) * 100));
    return `<div class="reserve-row" style="flex-direction:column;align-items:stretch">
      <div style="display:flex;justify-content:space-between">
        <span>${esc(r.branch_id)}</span>
        <b>${fmt(r.balance)} <span class="bill-sub" style="display:inline">/ ${fmt(r.cap)}</span></b>
      </div>
      <div class="reserve-meter"><span style="width:${pct}%"></span></div>
    </div>`;
  }).join('')
    : '<p class="hint">No branch tills on record.</p>';
}

async function adminSearch(term) {
  const res = await rpc('adminSearch', { term: term || '' });
  if (!res.ok) return toast(errText(res.error), 'error');
  A.accounts = res.data.rows || [];
  renderAdminAccounts();
}

function renderAdminQuick() {
  const rows = [
    { icon: I.papers, label: 'Reconcile', run: async () => {
      toast('Auditing the books…');
      const res = await rpc('adminReconcile', { limit: 200 });
      if (!res.ok) return toast(errText(res.error), 'error');
      const d = res.data.drifted || [];
      toast(d.length
        ? `${d.length} of ${res.data.checked} accounts show drift — see the server console.`
        : `All ${res.data.checked} accounts reconcile exactly.`,
        d.length ? 'error' : 'success');
    } },
    { icon: I.columns, label: 'Refresh', run: async () => {
      const res = await rpc('adminData');
      if (!res.ok) return toast(errText(res.error), 'error');
      A.data = res.data;
      renderAdminSupply();
      renderAdminLoans();
      renderAdminReserves();
      toast('Figures brought up to date.');
    } },
  ];
  $('#admin-quick').innerHTML = rows.map((r, i) => `
    <button class="qa-btn" data-i="${i}">${r.icon()}<span>${r.label}</span></button>`).join('');
  document.querySelectorAll('#admin-quick .qa-btn').forEach((el) =>
    el.addEventListener('click', () => rows[Number(el.dataset.i)].run()));
}

function renderAdmin() {
  $('#admin-actor').textContent = `Clerk ${A.data?.actor || '—'}`;
  renderAdminSupply();
  renderAdminLoans();
  renderAdminReserves();
  renderAdminQuick();
  adminSearch('');
}

// ----------------------------------------------------------------- plumbing

function renderAll() {
  renderCash();
  renderAccounts();
  renderActions();
  renderBranch();
  renderQuickActions();
  $('#sel-filter').innerHTML = FILTERS.map(([v, label]) =>
    `<option value="${v}" ${S.filter === v ? 'selected' : ''}>${label.toUpperCase()}</option>`).join('');
  loadLedger();
}

$('#sel-account').addEventListener('change', (e) => selectAccount(Number(e.target.value)));
$('#sel-filter').addEventListener('change', (e) => {
  S.filter = e.target.value;
  S.page = 0;
  loadLedger();
});
$('#pg-newer').addEventListener('click', () => { if (S.page > 0) { S.page--; loadLedger(); } });
$('#pg-older').addEventListener('click', () => {
  if ((S.page + 1) * PAGE_SIZE < S.total) { S.page++; loadLedger(); }
});

window.addEventListener('message', (e) => {
  const { action, data } = e.data || {};
  if (action === 'open') {
    S.data = data;
    S.open = true;
    S.mode = 'teller';
    S.page = 0;
    S.filter = '';
    $('#teller-panel').classList.remove('hidden');
    $('#admin-panel').classList.add('hidden');
    $('#app').classList.remove('hidden');
    renderAll();
  } else if (action === 'openAdmin') {
    A.data = data;
    A.accounts = [];
    S.open = true;
    S.mode = 'admin';
    $('#teller-panel').classList.add('hidden');
    $('#admin-panel').classList.remove('hidden');
    $('#app').classList.remove('hidden');
    renderAdmin();
  } else if (action === 'close') {
    S.open = false;
    closeModal();
    $('#app').classList.add('hidden');
  }
});

$('#admin-close').addEventListener('click', () => post('close'));
$('#adm-search-go').addEventListener('click', () => adminSearch($('#adm-search').value));
$('#adm-search').addEventListener('keydown', (e) => {
  if (e.key === 'Enter') adminSearch(e.target.value);
});

window.addEventListener('keydown', (e) => {
  if (e.key !== 'Escape' || !S.open) return;
  if (modalIsOpen()) closeModal();
  else post('close');
});

$('#btn-close').addEventListener('click', () => post('close'));
