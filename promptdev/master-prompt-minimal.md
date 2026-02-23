Build a single-file Node.js web app (server.js) — zero deps — that reboots
UniFi network devices and monitors recovery in real-time.

**API:** https://{controller}/proxy/network/integration/v1/sites/{siteId}
Auth: `X-API-Key: {apiKey}` (via .env file) | TLS: NODE_TLS_REJECT_UNAUTHORIZED=0

**Endpoints:** GET /devices?limit=200 | GET /devices/{id}/statistics/latest (uptimeSec, cpu/memPct, load, uplink bps, radio retries) | POST /devices/{id}/actions {"action":"RESTART"} (422 if offline)

**Gotcha:** Gateway = Dream Machine PRO SE — detect via model field, NOT features (reports only "switching"). macOS ping: -W 1000 (ms).

**Backend:** node:http server, 5 routes (HTML, devices, reboot-all, single reboot, SSE). State machine: ONLINE→REBOOT_SENT→GOING_OFFLINE→OFFLINE→COMING_BACK→ONLINE + REBOOT_FAILED/STUCK. Parallel reboot via Promise.allSettled. Dual monitoring: ping 2s + API/stats poll 5s. SSE broadcasts state changes, stats, pings, logs.

**Frontend (embedded):** Dark theme, CSS Grid cards in flex layout with persistent 340px detail sidebar. Cards show type badge (GW/AP/SW), status badge with pulse animations, name, model, IP, uptime/CPU/MEM stats. Sidebar shows full device info + all statistics with meter bars + status history. Sort by: name, IP, status, type, model, uptime, CPU, memory. Reboot All with confirm dialog. SSE auto-reconnect. Log panel at bottom.

Run: node server.js → localhost:3000
