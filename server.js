// ============================================================
// UniFi Reboot Manager
// Single-file Node.js server with embedded web UI
// Zero dependencies — uses only node:http, node:child_process
// Run: node server.js → http://localhost:3000
// ============================================================

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');

process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';

// ---- Load .env file ----
try {
  const envPath = path.join(__dirname, '.env');
  const envFile = fs.readFileSync(envPath, 'utf8');
  for (const line of envFile.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eq = trimmed.indexOf('=');
    if (eq > 0) process.env[trimmed.slice(0, eq)] = trimmed.slice(eq + 1);
  }
} catch (_) { /* .env is optional — use existing env vars */ }

// ---- Configuration ----
const PORT = process.env.PORT || 3000;
const UNIFI = {
  base: (process.env.UNIFI_HOST || 'https://192.168.1.1') + '/proxy/network/integration',
  key: process.env.UNIFI_API_KEY || '',
  site: process.env.UNIFI_SITE_ID || '',
};
const PING_MS = 2000;
const POLL_MS = 5000;
const STUCK_MS = 300000;

// ---- State ----
const devices = new Map();
const clients = new Set();
let monitoring = false;
let pingTimer, pollTimer, stuckTimer;

// ---- UniFi API ----
const apiUrl = (path) => `${UNIFI.base}/v1/sites/${UNIFI.site}${path}`;
const apiHeaders = { 'X-API-Key': UNIFI.key, 'Content-Type': 'application/json' };

async function apiFetch(path) {
  const res = await fetch(apiUrl(path), { headers: apiHeaders });
  if (!res.ok) throw new Error(`API ${res.status}`);
  return res.json();
}

async function apiPost(path, body) {
  const res = await fetch(apiUrl(path), {
    method: 'POST',
    headers: apiHeaders,
    body: JSON.stringify(body),
  });
  return { status: res.status, ok: res.ok };
}

// ---- Ping ----
function ping(ip) {
  return new Promise((resolve) => {
    const proc = spawn('ping', ['-c', '1', '-W', '1000', ip]);
    const timer = setTimeout(() => { proc.kill(); resolve(false); }, 3000);
    proc.on('close', (code) => { clearTimeout(timer); resolve(code === 0); });
    proc.on('error', () => { clearTimeout(timer); resolve(false); });
  });
}

// ---- Device Type ----
function deviceType(d) {
  if (d.model && d.model.includes('Dream Machine')) return 'gateway';
  const f = d.features || [];
  if (f.includes('accessPoint') && f.includes('switching')) return 'hybrid';
  if (f.includes('accessPoint')) return 'ap';
  if (f.includes('switching')) return 'switch';
  return 'unknown';
}

// ---- SSE ----
function broadcast(event) {
  const msg = `data: ${JSON.stringify(event)}\n\n`;
  for (const c of clients) c.write(msg);
}

function log(message, level = 'info') {
  const time = Date.now();
  broadcast({ type: 'log', message, level, time });
  console.log(`[${new Date(time).toLocaleTimeString()}] ${message}`);
}

// ---- Statistics ----
async function fetchStats(id) {
  try {
    return await apiFetch(`/devices/${id}/statistics/latest`);
  } catch { return null; }
}

async function fetchAllStats() {
  const results = await Promise.allSettled(
    [...devices].map(async ([id]) => {
      const stats = await fetchStats(id);
      if (stats) {
        const ds = devices.get(id);
        if (ds) ds.stats = stats;
      }
      return { id, stats };
    })
  );
  broadcast({ type: 'stats-update', stats: Object.fromEntries(
    results.filter(r => r.status === 'fulfilled' && r.value.stats)
      .map(r => [r.value.id, r.value.stats])
  )});
}

// ---- State Machine ----
async function initDevices() {
  const data = await apiFetch('/devices?limit=200');
  for (const d of data.data) {
    const type = deviceType(d);
    devices.set(d.id, {
      state: d.state === 'ONLINE' ? 'ONLINE' : 'OFFLINE',
      device: d,
      type,
      isGateway: type === 'gateway',
      history: [{ state: d.state === 'ONLINE' ? 'ONLINE' : 'OFFLINE', time: Date.now() }],
      stateChangedAt: Date.now(),
      lastPing: null,
      stats: null,
    });
  }
  await fetchAllStats();
}

function setState(id, newState) {
  const ds = devices.get(id);
  if (!ds || ds.state === newState) return;
  ds.state = newState;
  ds.stateChangedAt = Date.now();
  ds.history.push({ state: newState, time: ds.stateChangedAt });
  broadcast({ type: 'state-change', id, state: newState, time: ds.stateChangedAt });
  const lvl = newState === 'ONLINE' ? 'success' : newState === 'REBOOT_FAILED' ? 'error' : 'info';
  log(`${ds.device.name}: ${newState}`, lvl);
}

function onPing(id, alive) {
  const ds = devices.get(id);
  if (!ds) return;
  ds.lastPing = { alive, time: Date.now() };
  switch (ds.state) {
    case 'REBOOT_SENT': if (!alive) setState(id, 'GOING_OFFLINE'); break;
    case 'GOING_OFFLINE': if (!alive) setState(id, 'OFFLINE'); break;
    case 'OFFLINE': if (alive) setState(id, 'COMING_BACK'); break;
  }
  broadcast({ type: 'ping', id, alive, time: Date.now() });
}

function onApiState(id, apiState, deviceData) {
  const ds = devices.get(id);
  if (!ds) return;
  Object.assign(ds.device, deviceData);
  if (apiState === 'ONLINE' && ['COMING_BACK', 'REBOOT_SENT', 'GOING_OFFLINE'].includes(ds.state)) {
    setState(id, 'ONLINE');
  }
  checkComplete();
}

// ---- Monitoring ----
function startMonitoring() {
  if (monitoring) return;
  monitoring = true;
  broadcast({ type: 'monitoring-started' });

  pingTimer = setInterval(async () => {
    await Promise.allSettled(
      [...devices].map(([id, ds]) =>
        ds.device.ipAddress
          ? ping(ds.device.ipAddress).then((alive) => onPing(id, alive))
          : Promise.resolve()
      )
    );
  }, PING_MS);

  pollTimer = setInterval(async () => {
    try {
      const data = await apiFetch('/devices?limit=200');
      for (const d of data.data) onApiState(d.id, d.state, d);
    } catch (err) {
      log(`API poll failed: ${err.message}`, 'warn');
    }
    fetchAllStats().catch(() => {});
  }, POLL_MS);

  stuckTimer = setInterval(() => {
    const now = Date.now();
    for (const [id, ds] of devices) {
      if (['REBOOT_SENT', 'GOING_OFFLINE', 'OFFLINE', 'COMING_BACK'].includes(ds.state) &&
          now - ds.stateChangedAt > STUCK_MS) {
        setState(id, 'STUCK');
      }
    }
  }, 10000);
}

function stopMonitoring() {
  monitoring = false;
  clearInterval(pingTimer);
  clearInterval(pollTimer);
  clearInterval(stuckTimer);
  broadcast({ type: 'monitoring-complete' });
  log('All devices settled — monitoring stopped', 'success');
}

function checkComplete() {
  for (const [, ds] of devices) {
    if (['REBOOT_SENT', 'GOING_OFFLINE', 'OFFLINE', 'COMING_BACK'].includes(ds.state)) return;
  }
  if (monitoring) stopMonitoring();
}

// ---- Reboot Logic ----
async function rebootAll() {
  log('Reboot All initiated');
  broadcast({ type: 'reboot-started' });

  const online = [...devices].filter(([, ds]) => ds.state === 'ONLINE');
  log(`Sending restart to ${online.length} online devices`);

  const results = await Promise.allSettled(
    online.map(async ([id, ds]) => {
      setState(id, 'REBOOT_SENT');
      try {
        const r = await apiPost(`/devices/${id}/actions`, { action: 'RESTART' });
        if (!r.ok) {
          setState(id, 'REBOOT_FAILED');
          log(`${ds.device.name}: failed (HTTP ${r.status})`, 'error');
          return { id, ok: false, status: r.status };
        }
        log(`${ds.device.name}: restart sent`);
        return { id, ok: true };
      } catch (err) {
        setState(id, 'REBOOT_FAILED');
        log(`${ds.device.name}: error — ${err.message}`, 'error');
        return { id, ok: false, error: err.message };
      }
    })
  );

  startMonitoring();
  return results;
}

async function rebootOne(id) {
  const ds = devices.get(id);
  if (!ds) throw new Error('Device not found');

  setState(id, 'REBOOT_SENT');
  log(`Rebooting ${ds.device.name}`);

  try {
    const r = await apiPost(`/devices/${id}/actions`, { action: 'RESTART' });
    if (!r.ok) {
      setState(id, 'REBOOT_FAILED');
      log(`${ds.device.name}: failed (HTTP ${r.status})`, 'error');
      return { ok: false, status: r.status };
    }
    log(`${ds.device.name}: restart sent`);
    startMonitoring();
    return { ok: true };
  } catch (err) {
    setState(id, 'REBOOT_FAILED');
    log(`${ds.device.name}: error — ${err.message}`, 'error');
    return { ok: false, error: err.message };
  }
}

// ---- HTTP Server ----
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');

  try {
    // GET / → HTML
    if (req.method === 'GET' && url.pathname === '/') {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      return res.end(HTML);
    }

    // GET /api/devices
    if (req.method === 'GET' && url.pathname === '/api/devices') {
      const list = [...devices].map(([id, ds]) => ({
        id, ...ds.device,
        internalState: ds.state, type: ds.type,
        isGateway: ds.isGateway, lastPing: ds.lastPing, history: ds.history,
      }));
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify(list));
    }

    // POST /api/reboot-all
    if (req.method === 'POST' && url.pathname === '/api/reboot-all') {
      const results = await rebootAll();
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ ok: true, results }));
    }

    // POST /api/devices/:id/reboot
    const m = url.pathname.match(/^\/api\/devices\/([^/]+)\/reboot$/);
    if (req.method === 'POST' && m) {
      const result = await rebootOne(m[1]);
      res.writeHead(result.ok ? 200 : 422, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify(result));
    }

    // GET /api/events → SSE
    if (req.method === 'GET' && url.pathname === '/api/events') {
      res.writeHead(200, {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'Connection': 'keep-alive',
      });

      const state = {};
      for (const [id, ds] of devices) {
        state[id] = {
          state: ds.state, device: ds.device, type: ds.type,
          isGateway: ds.isGateway, history: ds.history, lastPing: ds.lastPing,
          stats: ds.stats,
        };
      }
      res.write(`data: ${JSON.stringify({ type: 'full-state', devices: state, monitoring })}\n\n`);

      clients.add(res);
      const keepalive = setInterval(() => res.write(': keepalive\n\n'), 30000);
      req.on('close', () => { clients.delete(res); clearInterval(keepalive); });
      return;
    }

    res.writeHead(404);
    res.end('Not Found');
  } catch (err) {
    console.error(err);
    if (!res.headersSent) {
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: err.message }));
    }
  }
});

// ---- Background stats refresh (when not monitoring) ----
setInterval(() => {
  if (!monitoring && clients.size > 0) fetchAllStats().catch(() => {});
}, 10000);

// ---- Startup ----
initDevices()
  .then(() => {
    server.listen(PORT, () => {
      console.log(`UniFi Reboot Manager → http://localhost:${PORT}`);
      console.log(`Loaded ${devices.size} devices`);
    });
  })
  .catch((err) => {
    console.error('Init failed:', err.message);
    server.listen(PORT, () => {
      console.log(`UniFi Reboot Manager → http://localhost:${PORT} (no devices loaded)`);
    });
  });

// ---- Embedded HTML ----
const HTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>UniFi Reboot Manager</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
:root{
  --bg:#0d1117;--surface:#161b22;--surface2:#1c2333;--border:#30363d;
  --text:#e6edf3;--muted:#8b949e;--dim:#6e7681;
  --green:#3fb950;--amber:#d29922;--orange:#db6d28;--red:#f85149;--blue:#58a6ff;--purple:#bc8cff;--cyan:#56d4dd;
}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;background:var(--bg);color:var(--text);min-height:100vh}

/* Header */
header{display:flex;align-items:center;justify-content:space-between;padding:14px 24px;background:var(--surface);border-bottom:1px solid var(--border);position:sticky;top:0;z-index:100}
header h1{font-size:17px;font-weight:600;letter-spacing:-0.3px}
.hdr-right{display:flex;align-items:center;gap:12px}
.progress{font-size:13px;color:var(--muted);font-variant-numeric:tabular-nums}
.sort-select{padding:6px 10px;border:1px solid var(--border);border-radius:6px;background:var(--surface);color:var(--text);font-size:12px;font-family:inherit;cursor:pointer;appearance:none;-webkit-appearance:none;background-image:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='10' height='6'%3E%3Cpath d='M0 0l5 6 5-6z' fill='%238b949e'/%3E%3C/svg%3E");background-repeat:no-repeat;background-position:right 8px center;padding-right:24px}
.sort-select:hover{border-color:var(--dim)}
.sort-select option{background:var(--surface);color:var(--text)}
.sort-label{font-size:12px;color:var(--dim)}

/* Buttons */
.btn{padding:7px 14px;border:1px solid var(--border);border-radius:6px;background:var(--surface);color:var(--text);font-size:13px;cursor:pointer;transition:all .15s;font-family:inherit}
.btn:hover{background:var(--surface2)}
.btn:disabled{opacity:.4;cursor:not-allowed}
.btn-red{background:rgba(248,81,73,.12);border-color:rgba(248,81,73,.35);color:var(--red)}
.btn-red:hover:not(:disabled){background:rgba(248,81,73,.22)}

/* Layout */
.layout{display:flex;height:calc(100vh - 49px)}
main{flex:1;overflow-y:auto;padding:20px 24px 220px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));gap:12px}

/* Card */
.card{background:var(--surface);border:1px solid var(--border);border-radius:8px;padding:14px 16px;cursor:pointer;transition:all .2s;position:relative}
.card:hover{border-color:var(--dim);transform:translateY(-1px);box-shadow:0 4px 12px rgba(0,0,0,.3)}
.card.selected{border-color:var(--blue);box-shadow:0 0 0 1px var(--blue)}
.card-top{display:flex;justify-content:space-between;align-items:center;margin-bottom:10px}
.type-b{font-size:10px;font-weight:700;padding:2px 7px;border-radius:10px;text-transform:uppercase;letter-spacing:.6px}
.type-gateway{background:rgba(188,140,255,.12);color:var(--purple)}
.type-ap{background:rgba(88,166,255,.12);color:var(--blue)}
.type-switch{background:rgba(63,185,80,.12);color:var(--green)}
.type-hybrid{background:rgba(86,212,221,.12);color:var(--cyan)}
.type-unknown{background:rgba(139,148,158,.12);color:var(--muted)}
.st-badge{display:inline-flex;align-items:center;gap:5px;font-size:10px;font-weight:700;padding:2px 8px;border-radius:10px;text-transform:uppercase;letter-spacing:.5px}
.st-dot{width:7px;height:7px;border-radius:50%;flex-shrink:0}

/* State colors */
.s-online .st-badge{background:rgba(63,185,80,.12);color:var(--green)} .s-online .st-dot{background:var(--green)}
.s-reboot-sent .st-badge{background:rgba(210,153,34,.12);color:var(--amber)} .s-reboot-sent .st-dot{background:var(--amber);animation:pulse 1.2s infinite}
.s-going-offline .st-badge{background:rgba(219,109,40,.12);color:var(--orange)} .s-going-offline .st-dot{background:var(--orange);animation:pulse 1s infinite}
.s-offline .st-badge{background:rgba(248,81,73,.12);color:var(--red)} .s-offline .st-dot{background:var(--red)}
.s-coming-back .st-badge{background:rgba(88,166,255,.12);color:var(--blue)} .s-coming-back .st-dot{background:var(--blue);animation:pulse 1.2s infinite}
.s-reboot-failed .st-badge{background:rgba(248,81,73,.12);color:var(--red)} .s-reboot-failed .st-dot{background:var(--red)}
.s-stuck .st-badge{background:rgba(248,81,73,.12);color:var(--red)} .s-stuck .st-dot{background:var(--red)}

@keyframes pulse{0%,100%{opacity:1;transform:scale(1)}50%{opacity:.35;transform:scale(.75)}}
@keyframes flash{0%{box-shadow:0 0 0 2px var(--green)}100%{box-shadow:none}}
.card.flash{animation:flash 1.5s ease-out}

.card-name{font-size:14px;font-weight:600;margin-bottom:3px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.card-meta{font-size:12px;color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.card-stats{display:flex;gap:10px;margin-top:8px;font-size:11px;color:var(--dim)}
.card-stats span{display:flex;align-items:center;gap:3px}
.card-stats .val{color:var(--muted)}

/* Detail panel (persistent sidebar) */
.d-panel{width:340px;flex-shrink:0;background:var(--surface);border-left:1px solid var(--border);overflow-y:auto;padding:20px;display:flex;flex-direction:column}
.d-placeholder{display:flex;align-items:center;justify-content:center;height:100%;color:var(--dim);font-size:13px;text-align:center;padding:24px;line-height:1.6}
.d-status{display:inline-flex;align-items:center;gap:8px;padding:4px 12px;border-radius:14px;font-size:11px;font-weight:700;text-transform:uppercase;letter-spacing:.5px;margin-bottom:16px}
.d-name{font-size:18px;font-weight:600;margin-bottom:2px}
.d-model{font-size:13px;color:var(--muted);margin-bottom:20px}
.d-info{display:grid;grid-template-columns:72px 1fr;gap:6px 12px;font-size:13px;margin-bottom:20px}
.d-label{color:var(--dim)}
.d-section{margin-bottom:20px}
.d-section h3{font-size:12px;font-weight:600;color:var(--dim);text-transform:uppercase;letter-spacing:.5px;margin-bottom:10px;padding-bottom:6px;border-bottom:1px solid var(--border)}
.d-metrics{display:grid;grid-template-columns:1fr 1fr;gap:10px}
.d-metric{background:var(--bg);border-radius:6px;padding:10px 12px}
.d-metric-label{font-size:11px;color:var(--dim);margin-bottom:4px}
.d-metric-val{font-size:15px;font-weight:600;font-variant-numeric:tabular-nums}
.d-metric-sub{font-size:11px;color:var(--dim);margin-top:2px}
.d-metric.wide{grid-column:span 2}
.meter{height:4px;background:var(--border);border-radius:2px;margin-top:6px;overflow:hidden}
.meter-fill{height:100%;border-radius:2px;transition:width .3s}
.d-hist h3{font-size:12px;font-weight:600;color:var(--dim);text-transform:uppercase;letter-spacing:.5px;margin-bottom:10px;padding-bottom:6px;border-bottom:1px solid var(--border)}
.h-entry{display:flex;align-items:center;gap:10px;padding:5px 0;font-size:12px;border-top:1px solid var(--border)}
.h-time{color:var(--dim);font-variant-numeric:tabular-nums;min-width:68px}
.h-state{display:flex;align-items:center;gap:6px}
.h-dot{width:6px;height:6px;border-radius:50%}

/* Log panel */
.log{position:fixed;bottom:0;left:0;right:0;background:var(--surface);border-top:1px solid var(--border);z-index:100;max-height:200px;transition:max-height .2s}
.log.collapsed{max-height:36px;overflow:hidden}
.log-hdr{display:flex;align-items:center;justify-content:space-between;padding:8px 24px;cursor:pointer;user-select:none}
.log-hdr h3{font-size:12px;font-weight:600;color:var(--muted);text-transform:uppercase;letter-spacing:.5px}
.log-body{max-height:158px;overflow-y:auto;padding:0 24px 8px;font-family:'SF Mono',Monaco,Consolas,monospace;font-size:11px;line-height:1.7}
.l-entry{display:flex;gap:8px}
.l-time{color:var(--dim);min-width:68px;flex-shrink:0}
.l-msg{flex:1;word-break:break-word}
.l-success{color:var(--green)}.l-warn{color:var(--amber)}.l-error{color:var(--red)}

/* Confirm dialog */
.c-overlay{display:none;position:fixed;inset:0;background:rgba(0,0,0,.55);backdrop-filter:blur(4px);z-index:300;align-items:center;justify-content:center}
.c-overlay.open{display:flex}
.c-dialog{background:var(--surface);border:1px solid var(--border);border-radius:12px;padding:24px;max-width:420px;width:90%}
.c-dialog h2{font-size:16px;margin-bottom:10px}
.c-dialog p{font-size:13px;color:var(--muted);line-height:1.55;margin-bottom:20px}
.c-btns{display:flex;justify-content:flex-end;gap:8px}

::-webkit-scrollbar{width:6px}::-webkit-scrollbar-track{background:transparent}::-webkit-scrollbar-thumb{background:var(--border);border-radius:3px}
</style>
</head>
<body>

<header>
  <h1>UniFi Reboot Manager</h1>
  <div class="hdr-right">
    <span id="progress" class="progress"></span>
    <span class="sort-label">Sort</span>
    <select id="sortSelect" class="sort-select" onchange="onSort()">
      <option value="name">Name</option>
      <option value="ip">IP Address</option>
      <option value="status">Status</option>
      <option value="type">Type</option>
      <option value="model">Model</option>
      <option value="uptime">Uptime</option>
      <option value="cpu">CPU Usage</option>
      <option value="memory">Memory Usage</option>
    </select>
    <button id="rebootBtn" class="btn btn-red" onclick="showConfirm()">Reboot All</button>
  </div>
</header>

<div class="layout">
  <main>
    <div id="grid" class="grid"></div>
  </main>
  <aside id="dPanel" class="d-panel">
    <div id="dContent"><div class="d-placeholder">Select a device to view details</div></div>
  </aside>
</div>

<div class="log" id="logPanel">
  <div class="log-hdr" onclick="toggleLog()">
    <h3>Event Log</h3>
    <button class="btn" style="padding:2px 8px;font-size:11px" onclick="event.stopPropagation();clearLog()">Clear</button>
  </div>
  <div id="logBody" class="log-body"></div>
</div>

<div id="cOverlay" class="c-overlay">
  <div class="c-dialog">
    <h2>Confirm Reboot All</h2>
    <p>This will restart all online devices simultaneously, including the gateway. Network connectivity will be temporarily disrupted.</p>
    <div class="c-btns">
      <button class="btn" onclick="hideConfirm()">Cancel</button>
      <button class="btn btn-red" onclick="doReboot()">Reboot All</button>
    </div>
  </div>
</div>

<script>
let D = {};
let selId = null;
let active = false;
let es = null;
let sortBy = 'name';

const STATE_COLORS = {
  ONLINE:'green',REBOOT_SENT:'amber',GOING_OFFLINE:'orange',
  OFFLINE:'red',COMING_BACK:'blue',REBOOT_FAILED:'red',STUCK:'red'
};

function sc(s){return 's-'+s.toLowerCase().replace(/_/g,'-')}
function tl(t){return{gateway:'GW',ap:'AP','switch':'SW',hybrid:'AP/SW',unknown:'??'}[t]||'??'}
function ft(ts){return new Date(ts).toLocaleTimeString([],{hour:'2-digit',minute:'2-digit',second:'2-digit'})}
function esc(s){const d=document.createElement('div');d.textContent=s;return d.innerHTML}
function fmtUptime(sec){if(!sec&&sec!==0)return'—';const d=Math.floor(sec/86400),h=Math.floor(sec%86400/3600),m=Math.floor(sec%3600/60);if(d>0)return d+'d '+h+'h';if(h>0)return h+'h '+m+'m';return m+'m'}
function fmtBps(bps){if(!bps&&bps!==0)return'—';if(bps>=1e6)return(bps/1e6).toFixed(1)+' Mbps';if(bps>=1e3)return(bps/1e3).toFixed(1)+' kbps';return bps+' bps'}
function fmtPct(v){return v!=null?v.toFixed(1)+'%':'—'}
function fmtLoad(v){return v!=null?v.toFixed(2):'—'}
function meterColor(pct){if(pct>85)return'var(--red)';if(pct>60)return'var(--amber)';return'var(--green)'}
function getStat(d,key){return d.stats?d.stats[key]:null}

function init(){connectSSE()}

function connectSSE(){
  if(es)es.close();
  es=new EventSource('/api/events');
  es.onmessage=e=>{const ev=JSON.parse(e.data);handle(ev)};
  es.onerror=()=>{es.close();addLog('Connection lost, reconnecting...','warn');setTimeout(connectSSE,2000)};
}

function handle(ev){
  switch(ev.type){
    case 'full-state':
      D=ev.devices;active=ev.monitoring||false;
      renderGrid();updateProgress();updateBtn();
      break;
    case 'state-change':
      if(D[ev.id]){
        const prev=D[ev.id].state;
        D[ev.id].state=ev.state;
        D[ev.id].history=D[ev.id].history||[];
        D[ev.id].history.push({state:ev.state,time:ev.time});
        updateCard(ev.id,prev);
        updateProgress();
        if(selId===ev.id)renderDetail(ev.id);
      }
      break;
    case 'ping':
      if(D[ev.id])D[ev.id].lastPing={alive:ev.alive,time:ev.time};
      break;
    case 'stats-update':
      if(ev.stats){for(const[id,s]of Object.entries(ev.stats)){if(D[id])D[id].stats=s}}
      updateCards();
      if(selId&&D[selId])renderDetail(selId);
      break;
    case 'log':
      addLog(ev.message,ev.level,ev.time);
      break;
    case 'reboot-started':case 'monitoring-started':
      active=true;updateBtn();break;
    case 'monitoring-complete':
      active=false;updateBtn();break;
  }
}

function ipToNum(ip){if(!ip)return 0;const p=ip.split('.');return((+p[0])<<24)+((+p[1])<<16)+((+p[2])<<8)+(+p[3])}
const STATE_ORDER={ONLINE:0,REBOOT_SENT:1,GOING_OFFLINE:2,COMING_BACK:3,OFFLINE:4,REBOOT_FAILED:5,STUCK:6};
const TYPE_ORDER={gateway:0,ap:1,hybrid:2,'switch':3,unknown:4};

function sortDevices(entries){
  return entries.sort((a,b)=>{
    const da=a[1],db=b[1];
    switch(sortBy){
      case 'ip': return ipToNum(da.device.ipAddress)-ipToNum(db.device.ipAddress);
      case 'status': return (STATE_ORDER[da.state]??9)-(STATE_ORDER[db.state]??9)||(da.device.name||'').localeCompare(db.device.name||'',undefined,{numeric:true});
      case 'type': return (TYPE_ORDER[da.type]??9)-(TYPE_ORDER[db.type]??9)||(da.device.name||'').localeCompare(db.device.name||'',undefined,{numeric:true});
      case 'model': return (da.device.model||'').localeCompare(db.device.model||'',undefined,{numeric:true})||(da.device.name||'').localeCompare(db.device.name||'',undefined,{numeric:true});
      case 'uptime': return (getStat(db,'uptimeSec')||0)-(getStat(da,'uptimeSec')||0);
      case 'cpu': return (getStat(db,'cpuUtilizationPct')||0)-(getStat(da,'cpuUtilizationPct')||0);
      case 'memory': return (getStat(db,'memoryUtilizationPct')||0)-(getStat(da,'memoryUtilizationPct')||0);
      default: {
        if(da.isGateway&&!db.isGateway)return -1;
        if(!da.isGateway&&db.isGateway)return 1;
        return(da.device.name||'').localeCompare(db.device.name||'',undefined,{numeric:true});
      }
    }
  });
}

function onSort(){sortBy=document.getElementById('sortSelect').value;renderGrid()}

function renderGrid(){
  const g=document.getElementById('grid');
  const sorted=sortDevices(Object.entries(D));
  g.innerHTML=sorted.map(([id,d])=>{
    const dev=d.device;
    return '<div class="card '+sc(d.state)+'" data-id="'+id+'" onclick="showDetail(\\''+id+'\\')">'
      +'<div class="card-top">'
      +'<span class="type-b type-'+d.type+'">'+tl(d.type)+'</span>'
      +'<span class="st-badge"><span class="st-dot"></span>'+d.state.replace(/_/g,' ')+'</span>'
      +'</div>'
      +'<div class="card-name">'+esc(dev.name||'Unknown')+'</div>'
      +'<div class="card-meta">'+esc(dev.model||'')+(dev.ipAddress?' &middot; '+dev.ipAddress:'')+'</div>'
      +cardStats(d)
      +'</div>';
  }).join('');
  // Restore selected highlight
  if(selId){const sel=g.querySelector('[data-id="'+selId+'"]');if(sel)sel.classList.add('selected')}
}

function cardStats(d){
  const s=d.stats;if(!s)return'';
  return '<div class="card-stats">'
    +'<span>'+fmtUptime(s.uptimeSec)+'</span>'
    +'<span>CPU <span class="val">'+fmtPct(s.cpuUtilizationPct)+'</span></span>'
    +'<span>MEM <span class="val">'+fmtPct(s.memoryUtilizationPct)+'</span></span>'
    +'</div>';
}

function updateCards(){
  document.querySelectorAll('.card').forEach(el=>{
    const id=el.dataset.id;const d=D[id];if(!d)return;
    const statsEl=el.querySelector('.card-stats');
    const newStats=cardStats(d);
    if(statsEl){statsEl.outerHTML=newStats}
    else if(newStats){el.insertAdjacentHTML('beforeend',newStats)}
  });
}

function updateCard(id,prevState){
  const el=document.querySelector('[data-id="'+id+'"]');
  if(!el)return renderGrid();
  const d=D[id];
  // Remove old state class, add new (preserve selected)
  el.className='card '+sc(d.state)+(selId===id?' selected':'');
  el.querySelector('.st-badge').innerHTML='<span class="st-dot"></span>'+d.state.replace(/_/g,' ');
  // Flash on return to ONLINE
  if(d.state==='ONLINE'&&prevState&&prevState!=='ONLINE'){
    el.classList.add('flash');
    setTimeout(()=>el.classList.remove('flash'),1500);
  }
}

function updateProgress(){
  const all=Object.values(D);
  const total=all.length;
  const online=all.filter(d=>d.state==='ONLINE').length;
  const rebooting=all.filter(d=>['REBOOT_SENT','GOING_OFFLINE','OFFLINE','COMING_BACK'].includes(d.state)).length;
  const el=document.getElementById('progress');
  el.textContent=online+'/'+total+' online';
  el.style.color=rebooting>0?'var(--amber)':online===total?'var(--green)':'var(--muted)';
}

function updateBtn(){
  const b=document.getElementById('rebootBtn');
  b.disabled=active;
  b.textContent=active?'Rebooting...':'Reboot All';
}

function showDetail(id){
  // Toggle if clicking same card
  if(selId===id){selId=null;clearSelection();return}
  selId=id;
  renderDetail(id);
  // Highlight selected card
  document.querySelectorAll('.card.selected').forEach(c=>c.classList.remove('selected'));
  const card=document.querySelector('[data-id="'+id+'"]');
  if(card)card.classList.add('selected');
}

function clearSelection(){
  document.querySelectorAll('.card.selected').forEach(c=>c.classList.remove('selected'));
  document.getElementById('dContent').innerHTML='<div class="d-placeholder">Select a device to view details</div>';
}

function stateColor(s){
  const c=STATE_COLORS[s]||'muted';
  return{green:'var(--green)',amber:'var(--amber)',orange:'var(--orange)',red:'var(--red)',blue:'var(--blue)',muted:'var(--muted)'}[c];
}

function renderDetail(id){
  const d=D[id];if(!d)return;
  const dev=d.device;const s=d.stats;
  const inReboot=['REBOOT_SENT','GOING_OFFLINE','OFFLINE','COMING_BACK'].includes(d.state);
  const col=stateColor(d.state);
  const bgCol=col.replace(')',',0.12)').replace('var(','rgba(').replace('--green','63,185,80').replace('--amber','210,153,34').replace('--orange','219,109,40').replace('--red','248,81,73').replace('--blue','88,166,255');

  let html='<div class="d-status '+sc(d.state)+'" style="background:'+bgCol+';color:'+col+'">'
    +'<span class="st-dot" style="background:'+col+'"></span>'+d.state.replace(/_/g,' ')+'</div>'
    +'<div class="d-name">'+esc(dev.name||'Unknown')+'</div>'
    +'<div class="d-model">'+esc(dev.model||'')+'</div>';

  // Device info
  html+='<div class="d-section"><h3>Device</h3><div class="d-info">'
    +'<span class="d-label">IP</span><span>'+(dev.ipAddress||'—')+'</span>'
    +'<span class="d-label">MAC</span><span>'+(dev.macAddress||'—')+'</span>'
    +'<span class="d-label">Firmware</span><span>'+(dev.firmwareVersion||'—')+'</span>'
    +'<span class="d-label">Features</span><span>'+((dev.features||[]).join(', ')||'—')+'</span>'
    +'</div></div>';

  // Statistics
  if(s){
    const cpu=s.cpuUtilizationPct;const mem=s.memoryUtilizationPct;
    html+='<div class="d-section"><h3>Statistics</h3><div class="d-metrics">';

    // Uptime
    html+='<div class="d-metric"><div class="d-metric-label">Uptime</div>'
      +'<div class="d-metric-val">'+fmtUptime(s.uptimeSec)+'</div></div>';

    // Heartbeat
    if(s.lastHeartbeatAt){
      html+='<div class="d-metric"><div class="d-metric-label">Last Heartbeat</div>'
        +'<div class="d-metric-val">'+ft(new Date(s.lastHeartbeatAt).getTime())+'</div></div>';
    }

    // CPU
    if(cpu!=null){
      html+='<div class="d-metric"><div class="d-metric-label">CPU</div>'
        +'<div class="d-metric-val">'+fmtPct(cpu)+'</div>'
        +'<div class="meter"><div class="meter-fill" style="width:'+cpu+'%;background:'+meterColor(cpu)+'"></div></div></div>';
    }

    // Memory
    if(mem!=null){
      html+='<div class="d-metric"><div class="d-metric-label">Memory</div>'
        +'<div class="d-metric-val">'+fmtPct(mem)+'</div>'
        +'<div class="meter"><div class="meter-fill" style="width:'+mem+'%;background:'+meterColor(mem)+'"></div></div></div>';
    }

    // Load averages
    if(s.loadAverage1Min!=null){
      html+='<div class="d-metric wide"><div class="d-metric-label">Load Average</div>'
        +'<div class="d-metric-val">'+fmtLoad(s.loadAverage1Min)
        +' <span style="color:var(--dim);font-size:12px;font-weight:400">/ '+fmtLoad(s.loadAverage5Min)+' / '+fmtLoad(s.loadAverage15Min)+'</span></div>'
        +'<div class="d-metric-sub">1 min / 5 min / 15 min</div></div>';
    }

    // Uplink
    if(s.uplink){
      html+='<div class="d-metric"><div class="d-metric-label">Uplink TX</div>'
        +'<div class="d-metric-val">'+fmtBps(s.uplink.txRateBps)+'</div></div>'
        +'<div class="d-metric"><div class="d-metric-label">Uplink RX</div>'
        +'<div class="d-metric-val">'+fmtBps(s.uplink.rxRateBps)+'</div></div>';
    }

    // Radio stats (APs)
    if(s.interfaces&&s.interfaces.radios&&s.interfaces.radios.length>0){
      html+='<div class="d-metric wide"><div class="d-metric-label">Radio TX Retries</div><div class="d-metric-val">'
        +s.interfaces.radios.map(r=>r.frequencyGHz+'GHz: '+fmtPct(r.txRetriesPct)).join(' &middot; ')
        +'</div></div>';
    }

    html+='</div></div>';
  }

  // Reboot button
  html+='<button class="btn btn-red" style="width:100%;margin-bottom:20px" onclick="rebootOne(\\''+id+'\\')"'
    +(inReboot?' disabled':'')+'>Reboot This Device</button>';

  // Status history
  html+='<div class="d-hist"><h3>Status History</h3>'
    +(d.history||[]).slice().reverse().map(h=>{
      const c2=stateColor(h.state);
      return '<div class="h-entry"><span class="h-time">'+ft(h.time)+'</span>'
        +'<span class="h-state"><span class="h-dot" style="background:'+c2+'"></span>'
        +h.state.replace(/_/g,' ')+'</span></div>';
    }).join('')
    +'</div>';

  document.getElementById('dContent').innerHTML=html;
}

function showConfirm(){document.getElementById('cOverlay').classList.add('open')}
function hideConfirm(){document.getElementById('cOverlay').classList.remove('open')}

async function doReboot(){
  hideConfirm();active=true;updateBtn();
  try{await fetch('/api/reboot-all',{method:'POST'})}
  catch(e){addLog('Reboot request failed: '+e.message,'error')}
}

async function rebootOne(id){
  try{await fetch('/api/devices/'+id+'/reboot',{method:'POST'})}
  catch(e){addLog('Reboot request failed: '+e.message,'error')}
}

function addLog(msg,level,time){
  level=level||'info';time=time||Date.now();
  const el=document.getElementById('logBody');
  const d=document.createElement('div');
  d.className='l-entry';
  d.innerHTML='<span class="l-time">'+ft(time)+'</span><span class="l-msg l-'+level+'">'+esc(msg)+'</span>';
  el.appendChild(d);
  el.scrollTop=el.scrollHeight;
  // Cap at 200 entries
  while(el.children.length>200)el.removeChild(el.firstChild);
}

function clearLog(){document.getElementById('logBody').innerHTML=''}
function toggleLog(){document.getElementById('logPanel').classList.toggle('collapsed')}

init();
</script>
</body>
</html>`;
