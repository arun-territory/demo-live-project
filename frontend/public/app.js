const API_BASE = '/api';
let token = sessionStorage.getItem('token') || null;

const $ = (id) => document.getElementById(id);
const log = (msg) => {
  const ts = new Date().toLocaleTimeString();
  $('log').textContent = `[${ts}] ${msg}\n` + $('log').textContent;
};

function setAuthStatus() {
  const el = $('auth-status');
  if (token) {
    el.textContent = 'signed in';
    el.classList.add('signed-in');
  } else {
    el.textContent = 'not signed in';
    el.classList.remove('signed-in');
  }
}
setAuthStatus();

async function call(path, opts = {}) {
  const headers = { 'content-type': 'application/json', ...(opts.headers || {}) };
  if (token) headers.authorization = `Bearer ${token}`;
  const res = await fetch(API_BASE + path, { ...opts, headers });
  const text = await res.text();
  let data;
  try { data = JSON.parse(text); } catch { data = text; }
  if (!res.ok) throw Object.assign(new Error(`HTTP ${res.status}`), { data });
  return data;
}

$('login-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  try {
    const res = await fetch('/api/auth/login', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ email: $('email').value }),
    });
    const data = await res.json();
    if (!res.ok || !data.token) {
      throw new Error(data.error || `HTTP ${res.status}`);
    }
    token = data.token;
    sessionStorage.setItem('token', token);
    setAuthStatus();
    log(`signed in as ${$('email').value}, token expires in ${data.expires_in_seconds}s`);
  } catch (err) {
    log(`login failed: ${err.message}`);
  }
});

function requireToken() {
  if (!token) {
    log('not signed in — click "Get token" in step 1 first');
    return false;
  }
  return true;
}

$('create-account-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  if (!requireToken()) return;
  try {
    const data = await call('/accounts', {
      method: 'POST',
      body: JSON.stringify({
        owner_name: $('owner_name').value,
        email: $('account_email').value,
      }),
    });
    log(`created account #${data.id} (${data.email})`);
    refreshAccounts();
  } catch (err) {
    log(`create failed: ${JSON.stringify(err.data || err.message)}`);
  }
});

async function refreshAccounts() {
  if (!requireToken()) return;
  try {
    const accounts = await call('/accounts');
    const tbody = $('accounts-table').querySelector('tbody');
    tbody.innerHTML = '';
    for (const a of accounts) {
      const tr = document.createElement('tr');
      tr.innerHTML = `<td>${a.id}</td><td>${a.owner_name}</td><td>${a.email}</td><td>${a.balance_cents}</td>`;
      tbody.appendChild(tr);
    }
  } catch (err) {
    log(`refresh failed: ${JSON.stringify(err.data || err.message)}`);
  }
}
$('refresh-accounts').addEventListener('click', refreshAccounts);

$('transfer-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  if (!requireToken()) return;
  try {
    const data = await call('/transactions/transfer', {
      method: 'POST',
      body: JSON.stringify({
        from_account_id: Number($('from_id').value),
        to_account_id: Number($('to_id').value),
        amount_cents: Number($('amount').value),
      }),
    });
    log(`transfer ok: ${JSON.stringify(data)}`);
    refreshAccounts();
  } catch (err) {
    log(`transfer failed: ${JSON.stringify(err.data || err.message)}`);
  }
});

$('deposit-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  if (!requireToken()) return;
  try {
    const data = await call('/transactions/deposit', {
      method: 'POST',
      body: JSON.stringify({
        account_id: Number($('dep_id').value),
        amount_cents: Number($('dep_amount').value),
      }),
    });
    log(`deposit ok: ${JSON.stringify(data)}`);
    refreshAccounts();
  } catch (err) {
    log(`deposit failed: ${JSON.stringify(err.data || err.message)}`);
  }
});
