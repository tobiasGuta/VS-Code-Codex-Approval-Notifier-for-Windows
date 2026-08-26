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

  function getToken() { return localStorage.getItem(tokenKey) || ''; }
  function setToken(token) { if (token) localStorage.setItem(tokenKey, token); else localStorage.removeItem(tokenKey); }
  function authHeaders() { const token = getToken(); return token ? { Authorization: `Bearer ${token}` } : {}; }

  function consumePairingFragment() {
    const raw = window.location.hash || '';
    if (!raw.startsWith('#')) return '';
    const params = new URLSearchParams(raw.slice(1));
    const code = String(params.get('pair') || '').trim();
    if (!/^\d{6}$/.test(code)) return '';
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
    try { body = await response.json(); } catch (_) { }
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
      if (status.paired && getToken()) { setPairedUi(true); scheduleRefresh(0); return; }
      setPairedUi(false);
      if (status.pairingAvailable) {
        const expires = status.expiresAt ? new Date(status.expiresAt) : null;
        els.pairStatus.textContent = expires && !Number.isNaN(expires.getTime())
          ? `Pairing is available until ${expires.toLocaleTimeString()}.` : 'Pairing is available.';
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
    if (!/^\d{6}$/.test(value)) { els.pairError.textContent = 'Enter the 6-digit code shown on your PC.'; return false; }
    els.pairError.textContent = '';
    els.pairButton.disabled = true;
    try {
      const response = await fetch('/pair', { method: 'POST', headers: { 'X-Pairing-Code': value }, cache: 'no-store' });
      const body = await response.json().catch(() => ({}));
      if (!response.ok || !body.deviceToken) throw Object.assign(new Error(body.error || `HTTP ${response.status}`), { status: response.status });
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
    } finally { els.pairButton.disabled = false; }
  }

  function formatTime(value) {
    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? '' : date.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
  }

  function renderFileChanges(container, changes) {
    container.replaceChildren();
    const list = Array.isArray(changes) ? changes : [];
    for (const change of list) {
      const item = document.createElement('div');
      item.className = 'file-change-item';

      const head = document.createElement('div');
      head.className = 'change-head';
      const path = document.createElement('code');
      path.className = 'change-path';
      path.textContent = change.path || '(path unavailable)';
      const type = document.createElement('span');
      type.className = 'change-type';
      type.textContent = change.changeType || 'unknown';
      head.append(path, type);
      item.appendChild(head);

      if (change.movePath) {
        const move = document.createElement('p');
        move.className = 'move-path';
        move.textContent = `Move to: ${change.movePath}`;
        item.appendChild(move);
      }

      if (change.diff) {
        const diff = document.createElement('pre');
        diff.className = 'change-diff';
        const code = document.createElement('code');
        code.textContent = change.diff;
        diff.appendChild(code);
        item.appendChild(diff);
      }
      container.appendChild(item);
    }
  }

  function renderApprovals(items) {
    els.approvalList.replaceChildren();
    const approvals = Array.isArray(items) ? items : [];
    els.emptyState.classList.toggle('hidden', approvals.length !== 0);

    for (const approval of approvals) {
      const fragment = els.template.content.cloneNode(true);
      const card = fragment.querySelector('.approval-card');
      const kindBadge = fragment.querySelector('.approval-kind');
      const commandDetails = fragment.querySelector('.command-details');
      const fileDetails = fragment.querySelector('.file-details');
      const fileWarning = fragment.querySelector('.file-warning');
      const fileChanges = fragment.querySelector('.file-changes');
      const command = fragment.querySelector('.command');
      const cwd = fragment.querySelector('.cwd');
      const reason = fragment.querySelector('.reason');
      const created = fragment.querySelector('.created');
      const allow = fragment.querySelector('.allow');
      const deny = fragment.querySelector('.deny');
      const message = fragment.querySelector('.card-message');
      const isFileChange = approval.kind === 'fileChange';

      if (isFileChange) {
        card.classList.add('file-change');
        kindBadge.textContent = 'FILE CHANGE';
        kindBadge.classList.add('file-kind');
        commandDetails.classList.add('hidden');
        fileDetails.classList.remove('hidden');
        renderFileChanges(fileChanges, approval.changes);
        const allowAvailable = approval.allowOnceAvailable === true;
        allow.disabled = !allowAvailable;
        fileWarning.classList.toggle('hidden', allowAvailable);
        if (!allowAvailable) allow.title = 'Review the file change in VS Code or deny this request.';
      } else {
        kindBadge.textContent = 'COMMAND';
        command.textContent = approval.command || '(command unavailable)';
        cwd.textContent = approval.cwd || '—';
      }

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
          if (error.status === 409 && error.body && error.body.error === 'allow_unavailable') {
            message.textContent = 'File details are unavailable or changed. Review in VS Code or deny.';
          } else if (error.status === 409) {
            message.textContent = 'This approval is already resolved or stale.';
          } else if (error.status === 401) {
            handleUnauthorized();
            return;
          } else {
            message.textContent = `Could not resolve approval: ${error.message}`;
          }
          allow.disabled = isFileChange ? approval.allowOnceAvailable !== true : false;
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
      const [status, approvals] = await Promise.all([api('/api/status'), api('/api/approvals')]);
      els.statusText.textContent = status.connected ? 'Connected to Codex' : 'Codex disconnected';
      els.pendingCount.textContent = String(status.pendingCount ?? 0);
      els.threadId.textContent = status.threadId || '—';
      els.badge.textContent = status.connected ? 'Connected' : 'Disconnected';
      els.badge.className = `badge ${status.connected ? 'online' : 'neutral'}`;
      renderApprovals(approvals.data || []);
    } catch (error) {
      if (error.status === 401) { handleUnauthorized(); return; }
      els.appError.textContent = `Refresh failed: ${error.message}`;
    } finally {
      refreshing = false;
      if (getToken()) scheduleRefresh();
    }
  }

  async function forgetDevice() {
    const token = getToken();
    if (!token) { handleUnauthorized(); return; }
    els.forgetButton.disabled = true;
    try { await api('/api/device/revoke', { method: 'POST' }); }
    catch (_) { }
    finally {
      setToken('');
      els.forgetButton.disabled = false;
      setPairedUi(false);
      els.pairError.textContent = 'This device has been unpaired.';
      loadPairingStatus();
    }
  }

  els.pairForm.addEventListener('submit', event => { event.preventDefault(); pair(els.pairCode.value); });
  els.refreshButton.addEventListener('click', refresh);
  els.forgetButton.addEventListener('click', forgetDevice);
  document.addEventListener('visibilitychange', () => { if (!document.hidden && getToken()) refresh(); });

  const fragmentPairingCode = consumePairingFragment();
  if (fragmentPairingCode) {
    setToken('');
    setPairedUi(false);
    els.pairStatus.textContent = 'Pairing with this PC…';
    pair(fragmentPairingCode).then(success => { if (!success) loadPairingStatus(); });
  } else if (getToken()) {
    setPairedUi(true);
    refresh();
  } else {
    setPairedUi(false);
    loadPairingStatus();
  }
})();
