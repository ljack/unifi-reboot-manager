# UniFi Reboot Manager

Zero-dependency Node.js web app for rebooting UniFi network devices with real-time monitoring.

Single file (`server.js`) — no frameworks, no build step, no `node_modules`. Uses the UniFi Integration API v1.

## Setup

Requires Node.js 18+ (for native `fetch`).

```bash
cp .env.example .env
# Edit .env with your UniFi controller details
```

```
UNIFI_HOST=https://192.168.1.1
UNIFI_API_KEY=your_api_key_here
UNIFI_SITE_ID=your_site_id_here
```

To find your API key and site ID, see the [UniFi Integration API docs](https://developer.ui.com/).

```bash
node server.js
# → http://localhost:3000
```

## Features

- **Parallel reboot** — reboots all devices simultaneously via `Promise.allSettled`
- **Real-time monitoring** — dual tracking with ICMP ping (2s) and API polling (5s)
- **Device state machine** — tracks each device through `ONLINE → REBOOT_SENT → GOING_OFFLINE → OFFLINE → COMING_BACK → ONLINE`
- **Live statistics** — uptime, CPU, memory, load average, uplink speeds, radio TX retries
- **SSE streaming** — instant UI updates, auto-reconnect on disconnect
- **Single device reboot** — reboot individual devices from the detail sidebar
- **Sorting** — by name, IP, status, type, model, uptime, CPU, or memory

## UI

Dark theme with responsive CSS Grid layout:

- **Card grid** — each device shows type badge (GW/AP/SW), status with pulse animations, name, model, IP, and live stats
- **Detail sidebar** — persistent 340px panel with full device info, statistics with color-coded meter bars, and status history
- **Log panel** — collapsible event log at the bottom
- **Confirmation dialog** — "Reboot All" requires explicit confirmation

## Architecture

```
server.js (single file, ~850 lines)
├── HTTP server (node:http) — 5 routes
├── UniFi API proxy — device list, statistics, reboot actions
├── Ping monitor — spawns ping per device (node:child_process)
├── State machine — 7 states with timeout detection
├── SSE broadcaster — real-time events to all connected clients
└── Embedded frontend — HTML/CSS/JS as template literal
```

### Routes

| Route | Method | Purpose |
|-------|--------|---------|
| `/` | GET | Embedded web UI |
| `/api/devices` | GET | Device list with state and statistics |
| `/api/reboot-all` | POST | Reboot all devices, start monitoring |
| `/api/devices/:id/reboot` | POST | Reboot single device |
| `/api/events` | GET | SSE stream |

### SSE Events

| Event | Payload |
|-------|---------|
| `full-state` | All devices with state + stats (sent on connect) |
| `state-change` | Single device state transition |
| `stats-update` | Refreshed statistics for all devices |
| `ping` | Per-device ping result |
| `log` | Timestamped message with level |

## API Gotchas

A few things discovered while building this:

- The Dream Machine SE reports `features: ["switching"]` — gateway detection uses `model.includes("Dream Machine")` instead
- Hybrid devices (e.g. U6 In-Wall) report `["switching", "accessPoint"]`
- Rebooting an offline device returns HTTP 422
- macOS `ping` uses milliseconds for timeout (`-W 1000`), not seconds

## Also Included

- `reboot-all.sh` — the original sequential bash script that reboots devices one-by-one with delays
- `promptdev/` — prompt engineering documentation showing how this project was built with AI assistance

## License

MIT
