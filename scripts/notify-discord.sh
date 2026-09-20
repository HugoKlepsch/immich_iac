#!/bin/bash
# Send an infrastructure notification to a Discord webhook.
#
#   ./scripts/notify-discord.sh --test
#   ./scripts/notify-discord.sh --failure immich-backup.service
#   ./scripts/notify-discord.sh --success immich-check.service "5% verified"
#
# Invoked by immich-alert@.service via OnFailure= on the units that
# matter, and directly by check-backup.sh for the weekly heartbeat.
#
# Deliberately uses HOST tools (curl, journalctl) rather than running in a
# container like everything else here. If docker is what broke, a
# docker-based alert would fail at exactly the moment it is needed.
#
# Never exits non-zero on a delivery problem. This runs as a failure handler;
# a failing failure-handler just produces noise in the journal and, if it were
# wired to OnFailure, a loop.
set -uo pipefail

cd "$(dirname "$0")/.."

ENV_FILE=".env.bash"
if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a
fi

WEBHOOK="${DISCORD_WEBHOOK_URL:-}"
HOSTNAME_STR="$(uname -n)"

if [[ -z "$WEBHOOK" ]]; then
  echo "notify-discord: DISCORD_WEBHOOK_URL is not set; nothing sent." >&2
  exit 0
fi

MODE="${1:---test}"
UNIT="${2:-}"
EXTRA="${3:-}"

# Discord colours (decimal)
RED=15158332
GREEN=3066993
BLUE=3447003

case "$MODE" in
  --failure)
    TITLE="FAILED: ${UNIT}"
    COLOUR=$RED
    # -o cat drops the syslog prefix; the embed is short on space.
    DETAIL="$(journalctl -u "$UNIT" -n 25 --no-pager -o cat 2>/dev/null | tail -c 3000)"
    [[ -z "$DETAIL" ]] && DETAIL="(no journal output)"
    STATE="$(systemctl show -p Result --value "$UNIT" 2>/dev/null)"
    ;;
  --success)
    TITLE="OK: ${UNIT}"
    COLOUR=$GREEN
    DETAIL="${EXTRA:-completed successfully}"
    STATE="success"
    ;;
  --test)
    TITLE="Test notification"
    COLOUR=$BLUE
    DETAIL="If you can read this, alerting from Immich works."
    STATE="test"
    UNIT="immich"
    ;;
  *)
    echo "Usage: $0 [--test|--failure <unit>|--success <unit> [detail]]" >&2
    exit 0
    ;;
esac

# jq builds the JSON so that journal output containing quotes, backslashes or
# newlines cannot produce a malformed payload.
PAYLOAD="$(jq -nc \
  --arg title "$TITLE" \
  --arg detail "$DETAIL" \
  --arg host "$HOSTNAME_STR" \
  --arg state "${STATE:-unknown}" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson colour "$COLOUR" \
  '{
     username: "immich",
     embeds: [{
       title: $title,
       description: ("```\n" + $detail + "\n```"),
       color: $colour,
       timestamp: $ts,
       fields: [
         {name: "host",   value: $host,  inline: true},
         {name: "result", value: $state, inline: true}
       ]
     }]
   }')"

# Discord rejects embeds over 6000 characters outright. Truncating the detail
# is better than the alert silently not arriving.
if [[ ${#PAYLOAD} -gt 5500 ]]; then
  DETAIL="$(printf '%s' "$DETAIL" | tail -c 1500)"
  PAYLOAD="$(jq -nc \
    --arg title "$TITLE" --arg detail "...(truncated)...
$DETAIL" --arg host "$HOSTNAME_STR" --arg state "${STATE:-unknown}" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson colour "$COLOUR" \
    '{username:"immich",embeds:[{title:$title,description:("```\n"+$detail+"\n```"),color:$colour,timestamp:$ts,fields:[{name:"host",value:$host,inline:true},{name:"result",value:$state,inline:true}]}]}')"
fi

HTTP="$(printf '%s' "$PAYLOAD" | curl -sS -o /dev/null -w '%{http_code}' \
          --max-time 20 --retry 2 --retry-delay 5 \
          -X POST -H 'Content-Type: application/json' -d @- "$WEBHOOK" 2>&1)"

if [[ "$HTTP" == "204" || "$HTTP" == "200" ]]; then
  echo "notify-discord: sent (${TITLE})"
else
  # Do not fail: see the header comment.
  echo "notify-discord: delivery failed, HTTP ${HTTP}" >&2
fi
exit 0
