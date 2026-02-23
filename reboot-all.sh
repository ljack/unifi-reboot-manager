#!/usr/bin/env bash
set -euo pipefail

# UniFi Integration API - Reboot All Devices
# Reboots devices one-by-one, skipping offline ones and the gateway (Dream Machine SE) until last.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -a; source "$SCRIPT_DIR/.env"; set +a
fi

BASE_URL="${UNIFI_HOST:-https://192.168.1.1}/proxy/network/integration"
API_KEY="${UNIFI_API_KEY:?Set UNIFI_API_KEY in .env or environment}"
SITE_ID="${UNIFI_SITE_ID:?Set UNIFI_SITE_ID in .env or environment}"
WAIT_SECONDS=30  # seconds to wait between reboots

api() {
  curl -sk -H "X-API-Key: $API_KEY" -H "Content-Type: application/json" "$@"
}

echo "=== Fetching device list ==="
DEVICES_JSON=$(api "${BASE_URL}/v1/sites/${SITE_ID}/devices?limit=200")

# Parse devices into arrays, separating gateway from the rest
GATEWAY_ID=""
GATEWAY_NAME=""
declare -a DEVICE_IDS=()
declare -a DEVICE_NAMES=()
declare -a DEVICE_STATES=()

while IFS=$'\t' read -r id name state features; do
  if [[ "$features" == *"gateway"* ]]; then
    GATEWAY_ID="$id"
    GATEWAY_NAME="$name"
    echo "  [GATEWAY] $name ($id) - will reboot LAST"
  else
    DEVICE_IDS+=("$id")
    DEVICE_NAMES+=("$name")
    DEVICE_STATES+=("$state")
    echo "  $name ($state)"
  fi
done < <(echo "$DEVICES_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for d in data['data']:
    features = ','.join(d.get('features', []))
    print(f\"{d['id']}\t{d['name']}\t{d['state']}\t{features}\")
")

echo ""
echo "=== Found ${#DEVICE_IDS[@]} non-gateway devices + $([ -n \"$GATEWAY_ID\" ] && echo '1 gateway' || echo 'no gateway') ==="
echo ""

reboot_device() {
  local device_id="$1"
  local device_name="$2"

  echo -n "  Rebooting '$device_name' ... "
  HTTP_CODE=$(api -w "%{http_code}" -o /dev/null -X POST -d '{"action":"RESTART"}' \
    "${BASE_URL}/v1/sites/${SITE_ID}/devices/${device_id}/actions")

  if [[ "$HTTP_CODE" == "200" ]]; then
    echo "OK (HTTP $HTTP_CODE)"
    return 0
  else
    echo "FAILED (HTTP $HTTP_CODE)"
    return 1
  fi
}

# Reboot non-gateway devices
REBOOTED=0
SKIPPED=0
FAILED=0

for i in "${!DEVICE_IDS[@]}"; do
  id="${DEVICE_IDS[$i]}"
  name="${DEVICE_NAMES[$i]}"
  state="${DEVICE_STATES[$i]}"

  if [[ "$state" != "ONLINE" ]]; then
    echo "  Skipping '$name' (state: $state)"
    ((SKIPPED++))
    continue
  fi

  if reboot_device "$id" "$name"; then
    ((REBOOTED++))
  else
    ((FAILED++))
  fi

  # Wait before next reboot (skip wait after last device)
  if [[ $i -lt $((${#DEVICE_IDS[@]} - 1)) ]]; then
    echo "  Waiting ${WAIT_SECONDS}s ..."
    sleep "$WAIT_SECONDS"
  fi
done

echo ""
echo "=== Non-gateway devices: $REBOOTED rebooted, $SKIPPED skipped (offline), $FAILED failed ==="

# Reboot gateway last
if [[ -n "$GATEWAY_ID" ]]; then
  echo ""
  read -p "Reboot gateway '$GATEWAY_NAME'? This will briefly disconnect you. [y/N] " -n 1 -r
  echo ""
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    reboot_device "$GATEWAY_ID" "$GATEWAY_NAME"
    echo "Gateway reboot initiated. Connection will drop momentarily."
  else
    echo "Skipped gateway reboot."
  fi
fi

echo ""
echo "=== Done ==="
