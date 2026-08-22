(() => {
  'use strict';

  const tokenKey = 'codexLanGatewayDeviceToken';
  const els = {
    badge: document.getElementById('connectionBadge'),
    pairPanel: document.getElementById('pairPanel'),
    appPanel: document.getElementById('appPanel'),
    pairForm: document.getElementById('pairForm'),
    pairCode: document.getElementById('pairCode'),
    pairButton: document.getElementById('pairButton'),
    pairStatus: document.getElementById('pairStatus'),
    pairError: document.getElementById('pairError'),
    statusText: document.getElementById('statusText'),
    pendingCount: document.getElementById('pendingCount'),
    threadId: document.getElementById('threadId'),
    approvalList: document.getElementById('approvalList'),
    emptyState: document.getElementById('emptyState'),
    appError: document.getElementById('appError'),
    refreshButton: document.getElementById('refreshButton'),
    forgetButton: document.getElementById('forgetButton'),
    template: document.getElementById('approvalTemplate')
  };

  let refreshTimer = null;
  let refreshing = false;

  function getToken() {
    return sessionStorage.getItem(tokenKey) || '';
  }

  function setToken(token) {
    if (token) sessionStorage.setItem(tokenKey, token);
    else sessionStorage.removeItem(tokenKey);
  }

  function authHeaders() {
    const token = getToken();
    return token ? { Authorization: `Bearer ${token}` } : {};
  }

  function consumePairingFragment() {
    const raw = window.location.hash || '';
    if (!raw.startsWith('#')) return '';
    const params = new URLSearchParams(raw.slice(1));
    const code = String(params.get('pair') || '').trim();
    if (!/^\d{6}$/.test(code)) return '';

    // Remove the short-lived pairing secret from the visible URL/history before
    // attempting network pairing. The fragment is never sent in the HTTP request.
    history.replaceState(null, document.title, `${window.location.pathname}${window.location.search}`);
    return code;
  }

  async function api(path, options = {}) {
    const response = await fetch(path, {
      method: options.method || 'GET',
      headers: { ...authHeaders(), ...(options.headers || {}) },
      cache: 'no-store'
    });

    let body = {};
    try { body = await response.json(); } catch (_) {}

    if (!response.ok) {
      const error = new Error(body.error || `HTTP ${response.status}`);
      error.status = response.status;
      error.body = body;
      throw error;
    }
    return body;
  }

  function setPairedUi(paired) {
    els.pairPanel.classList.toggle('hidden', paired);
    els.appPanel.classList.toggle('hidden', !paired);
    els.badge.textContent = paired ? 'Paired' : 'Not paired';
    els.badge.className = `badge ${paired ? 'online' : 'neutral'}`;
  }

  async function loadPairingStatus() {
    try {
      const status = await api('/pairing/status');
      if (status.paired && getToken()) {
        setPairedUi(true);
        scheduleRefresh(0);
        return;
      }

      setPairedUi(false);
      if (status.pairingAvailable) {
        const expires = status.expiresAt ? new Date(status.expiresAt) : null;
        els.pairStatus.textContent = expires && !Number.isNaN(expires.getTime())
          ? `Pairing is available until ${expires.toLocaleTimeString()}.`
          : 'Pairing is available.';
      } else if (status.paired) {
        els.pairStatus.textContent = 'A device is already paired. Restart the gateway or revoke the current device to pair again.';
      } else {
        els.pairStatus.textContent = 'The pairing code has expired. Restart the LAN gateway to create a new code.';
      }
    } catch (error) {
      els.pairStatus.textContent = 'Could not reach the LAN gateway.';
      els.pairError.textContent = error.message;
    }
  }

  async function pair(code) {
    const value = String(code || '').trim();
    if (!/^\d{6}$/.test(value)) {
      els.pairError.textContent = 'Enter the 6-digit code shown on your PC.';
      return false;
    }

    els.pairError.textContent = '';
    els.pairButton.disabled = true;
    try {
      const response = await fetch('/pair', {
        method: 'POST',
        headers: { 'X-Pairing-Code': value },
        cache: 'no-store'
      });
      const body = await response.json().catch(() => ({}));
      if (!response.ok || !body.deviceToken) {
        throw Object.assign(new Error(body.error || `HTTP ${response.status}`), { status: response.status });
      }

      setToken(body.deviceToken);
      els.pairCode.value = '';
      setPairedUi(true);
      await refresh();
      return true;
    } catch (error) {
      if (error.status === 401) els.pairError.textContent = 'That pairing code was not accepted.';
      else if (error.status === 409) els.pairError.textContent = 'That pairing code has already been used.';
      else if (error.status === 410) els.pairError.textContent = 'That pairing code has expired.';
      else if (error.status === 429) els.pairError.textContent = 'Too many failed attempts. Try again later.';
      else els.pairError.textContent = `Pairing failed: ${error.message}`;
      return false;
    } finally {
      els.pairButton.disabled = false;
    }
  }

  function formatTime(value) {
    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? '' : date.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
  }

  function renderApprovals(items) {
    els.approvalList.replaceChildren();
    const approvals = Array.isArray(items) ? items : [];
    els.emptyState.classList.toggle('hidden', approvals.length !== 0);

    for (const approval of approvals) {
      const fragment = els.template.content.cloneNode(true);
      const card = fragment.querySelector('.approval-card');
      const command = fragment.querySelector('.command');
      const cwd = fragment.querySelector('.cwd');
      const reason = fragment.querySelector('.reason');
      const created = fragment.querySelector('.created');
      const allow = fragment.querySelector('.allow');
      const deny = fragment.querySelector('.deny');
      const message = fragment.querySelector('.card-message');

      command.textContent = approval.command || '(command unavailable)';
      cwd.textContent = approval.cwd || '—';
      reason.textContent = approval.reason || 'No reason supplied.';
      created.textContent = formatTime(approval.createdAt);

      const resolve = async (decision) => {
        if (!approval.handle) return;
        allow.disabled = true;
        deny.disabled = true;
        message.textContent = decision === 'accept' ? 'Allowing…' : 'Denying…';
        try {
          await api(`/api/approvals/${encodeURIComponent(approval.handle)}/${decision}`, { method: 'POST' });
          message.textContent = decision === 'accept' ? 'Approved.' : 'Denied.';
          await refresh();
        } catch (error) {
          if (error.status === 409) message.textContent = 'This approval is already resolved or stale.';
          else if (error.status === 401) handleUnauthorized();
          else message.textContent = `Could not resolve approval: ${error.message}`;
          allow.disabled = false;
          deny.disabled = false;
        }
      };

      allow.addEventListener('click', () => resolve('accept'));
      deny.addEventListener('click', () => resolve('decline'));
      card.dataset.handle = approval.handle || '';
      els.approvalList.appendChild(fragment);
    }
  }

  function handleUnauthorized() {
    setToken('');
    if (refreshTimer) clearTimeout(refreshTimer);
    refreshTimer = null;
    setPairedUi(false);
    els.appError.textContent = '';
    els.pairError.textContent = 'This device token is no longer valid. Pair again with a new gateway session.';
    loadPairingStatus();
  }

  function scheduleRefresh(delay = 1500) {
    if (refreshTimer) clearTimeout(refreshTimer);
    refreshTimer = setTimeout(refresh, delay);
  }

  async function refresh() {
    if (refreshing || !getToken()) return;
    refreshing = true;
    els.appError.textContent = '';
    try {
      const [status, approvals] = await Promise.all([
        api('/api/status'),
        api('/api/approvals')
      ]);

      els.statusText.textContent = status.connected ? 'Connected to Codex' : 'Codex disconnected';
      els.pendingCount.textContent = String(status.pendingCount ?? 0);
      els.threadId.textContent = status.threadId || '—';
      els.badge.textContent = status.connected ? 'Connected' : 'Disconnected';
      els.badge.className = `badge ${status.connected ? 'online' : 'neutral'}`;
      renderApprovals(approvals.data || []);
    } catch (error) {
      if (error.status === 401) {
        handleUnauthorized();
        return;
      }
      els.appError.textContent = `Refresh failed: ${error.message}`;
    } finally {
      refreshing = false;
      if (getToken()) scheduleRefresh();
    }
  }

  async function forgetDevice() {
    const token = getToken();
    if (!token) {
      handleUnauthorized();
      return;
    }

    els.forgetButton.disabled = true;
    try {
      await api('/api/device/revoke', { method: 'POST' });
    } catch (_) {
      // Clear the local token even if the gateway is unreachable.
    } finally {
      setToken('');
      els.forgetButton.disabled = false;
      setPairedUi(false);
      els.pairError.textContent = 'This Safari session has been forgotten.';
      loadPairingStatus();
    }
  }

  els.pairForm.addEventListener('submit', event => {
    event.preventDefault();
    pair(els.pairCode.value);
  });
  els.refreshButton.addEventListener('click', refresh);
  els.forgetButton.addEventListener('click', forgetDevice);
  document.addEventListener('visibilitychange', () => {
    if (!document.hidden && getToken()) refresh();
  });

  const fragmentPairingCode = consumePairingFragment();

  // A freshly scanned QR belongs to the gateway instance that generated it.
  // Give it precedence over any token left in Safari from an older gateway
  // process. This both invalidates the old session locally and allows a single
  // scan to establish the new session after a gateway/tray restart.
  if (fragmentPairingCode) {
    setToken('');
    setPairedUi(false);
    els.pairStatus.textContent = 'Pairing with this PC…';
    pair(fragmentPairingCode).then(success => {
      if (!success) loadPairingStatus();
    });
  } else if (getToken()) {
    setPairedUi(true);
    refresh();
  } else {
    setPairedUi(false);
    loadPairingStatus();
  }
})();
