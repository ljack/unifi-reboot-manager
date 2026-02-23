# UniFi Reboot Manager — Web UI

Build a zero-dependency Node.js web app (server.js + package.json) that manages
reboots of all UniFi network devices with real-time monitoring.

## UniFi API Details
- Controller: configured via `UNIFI_HOST` in `.env`
- Auth: `X-API-Key` header (NOT Bearer token) — key in `UNIFI_API_KEY` env var
- Site ID: configured via `UNIFI_SITE_ID` in `.env`
- Self-signed cert: `NODE_TLS_REJECT_UNAUTHORIZED=0`
- Base: `/proxy/network/integration/v1/sites/{siteId}`

### Endpoints used
- `GET /devices?limit=200` — list all devices (15 total)
- `GET /devices/{id}/statistics/latest` — uptime, CPU, memory, load, uplink, radio stats
- `POST /devices/{id}/actions` + `{"action":"RESTART"}` — reboot (returns 422 for offline devices)

### API Gotchas
- Gateway (Dream Machine SE) reports `features: ["switching"]` — detect via `model.includes("Dream Machine")` instead
- Hybrid devices (U6 IW) report both `["switching","accessPoint"]` features
- Statistics endpoint returns: uptimeSec, cpuUtilizationPct, memoryUtilizationPct,
  loadAverage1/5/15Min, uplink.txRateBps/rxRateBps, lastHeartbeatAt,
  interfaces.radios[].frequencyGHz/txRetriesPct
- Ping on macOS: `ping -c 1 -W 1000` (milliseconds)

## Architecture — Two files, zero dependencies
Uses only `node:http` and `node:child_process`. Native `fetch` for API calls.

### server.js — 5 routes
| Route | Purpose |
|-------|---------|
| GET / | Serve embedded HTML (template literal) |
| GET /api/devices | Proxy device list + internal state + stats |
| POST /api/reboot-all | Parallel reboot via Promise.allSettled, start monitoring |
| POST /api/devices/:id/reboot | Single device reboot |
| GET /api/events | SSE stream — full state on connect, live updates, 30s keepalive |

### Device State Machine
```
ONLINE → REBOOT_SENT → GOING_OFFLINE → OFFLINE → COMING_BACK → ONLINE
Also: REBOOT_FAILED (HTTP 422), STUCK (5 min timeout)
```

### Monitoring (dual)
- **Ping loop** (2s): spawn `ping -c 1 -W 1000` per device, detect offline/online transitions
- **API poll** (5s): fetch device list + statistics for all devices, confirm state via API
- **Stuck check** (10s): mark devices stuck after 5 minutes in transitioning state
- **Idle stats** (10s): refresh stats when clients connected but not monitoring
- Auto-stop monitoring when all devices reach terminal state

### SSE Events
- `full-state`: all device state + stats (sent on connect)
- `state-change`: single device state transition
- `stats-update`: refreshed statistics for all devices
- `ping`: per-device ping result
- `log`: timestamped log message with level
- `monitoring-started` / `monitoring-complete`
- `reboot-started`

## Frontend (embedded in server.js)
Dark theme (GitHub dark palette), responsive CSS Grid.

### Layout
- Sticky header: title, online count, sort dropdown, "Reboot All" button
- Flex body: scrollable card grid (left) + persistent 340px detail sidebar (right)
- Fixed log panel at bottom (collapsible)
- Confirmation modal with backdrop blur

### Device Cards
- Type badge (GW purple, AP blue, SW green, AP/SW cyan)
- Status badge with colored dot (pulse animation for transitioning states)
- Device name, model + IP
- Stats row: uptime, CPU%, MEM%
- Blue border highlight when selected
- Green flash animation when returning to ONLINE

### Sort Options (dropdown in header)
Name (default, gateway first), IP Address (numerical), Status, Type, Model,
Uptime, CPU Usage, Memory Usage — each with sensible secondary sort

### Detail Sidebar (persistent, right side)
- Status pill, device name, model
- Device section: IP, MAC, firmware, features
- Statistics section (metric tiles in 2-col grid):
  - Uptime, Last Heartbeat
  - CPU + color-coded meter bar (green <60%, amber <85%, red >=85%)
  - Memory + color-coded meter bar
  - Load Average (1/5/15 min)
  - Uplink TX/RX (formatted bps/kbps/Mbps)
  - Radio TX Retries per band (APs only)
- "Reboot This Device" button (disabled during active reboot)
- Status History timeline

### SSE Client
- Auto-reconnect on error (2s delay)
- Full state sync on reconnect
- Live card updates without full re-render
- Stats update in-place on cards

## Setup
Copy `.env.example` to `.env` and fill in your UniFi controller details:
```
UNIFI_HOST=https://192.168.1.1
UNIFI_API_KEY=your_api_key_here
UNIFI_SITE_ID=your_site_id_here
```

## Run
`node server.js` → http://localhost:3000
