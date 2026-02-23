# UniFi Reboot Manager — Prompt Development TL;DRs

## Group 1: API Discovery & Authentication
*Previous session, prompts 1-2*

Navigated UniFi controller at 192.168.11.1 via browser automation. Discovered API requires auth, found OpenAPI docs at `/proxy/network/api-docs/integration.json`, mapped endpoint patterns (`/proxy/network/` prefix), enumerated 15 devices. Key gotcha: auth uses `X-API-Key` header, NOT `Authorization: Bearer`.

## Group 2: Bash Script MVP
*Previous session, prompt 3*

Built `reboot-all.sh` — sequential device reboot via Integration API v1. Reboots online devices one-by-one with 30s delays, skips offline, saves gateway for last with interactive confirm. Uses curl + Python JSON parsing.

## Group 3: Testing, Bugs & Root Cause Analysis
*Previous session, prompts 3-8*

Ran the script — 6/15 succeeded, gateway rebooted mid-run killing connectivity for remaining devices. Root cause: Dream Machine SE reports `features: ["switching"]` not `"gateway"`, so gateway detection failed. Also discovered: offline devices return HTTP 422, API behavior varies by device type (some return 405). Fix: detect gateway via `model.includes("Dream Machine")`.

## Group 4: Web UI Architecture Design
*Previous session, prompt 8 → plan mode*

Designed single-file Node.js web app replacing the bash script. Zero dependencies. SSE for real-time updates. Dual monitoring (ping 2s + API poll 5s). Parallel reboot via `Promise.allSettled`. 6-state machine: `ONLINE → REBOOT_SENT → GOING_OFFLINE → OFFLINE → COMING_BACK → ONLINE` + `REBOOT_FAILED` / `STUCK`. Dark theme embedded frontend.

## Group 5: Web UI Implementation
*Current session, prompt 1*

Built `server.js` (~650 lines) + `package.json`. 5 routes: HTML page, device list, reboot-all, single reboot, SSE stream. Backend: state machine, ping spawning, API proxy. Frontend: dark CSS Grid cards with type badges (GW/AP/SW/AP+SW), status badges with pulse animations, overlay detail panel, confirmation dialog, auto-reconnecting SSE, event log. Verified working against live controller with 15 devices.

## Group 6: UI Refinements — Layout & Sorting
*Current session, prompts 2-3*

(a) Changed detail panel from overlay to persistent right sidebar (340px). Cards and sidebar sit side-by-side in flex layout. Click to select (blue border), click again to deselect. (b) Added sort dropdown: Name, IP (numerical), Status, Type, Model. Each with sensible secondary sort.

## Group 7: Statistics Integration
*Current session, prompts 4-5*

Discovered `/devices/{id}/statistics/latest` endpoint returns: `uptimeSec`, `cpuUtilizationPct`, `memoryUtilizationPct`, `loadAverage1/5/15Min`, `uplink.txRateBps/rxRateBps`, `lastHeartbeatAt`, radio `txRetriesPct`. Added stats fetching (init + 5s during monitoring + 10s idle). Cards show uptime/CPU/MEM. Detail panel shows all metrics with color-coded meter bars. Added Uptime/CPU/Memory sort options.
