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
# Never exits non-zero on a delivery problem in --failure or --success mode.
# Those run as failure handlers; a failing failure-handler just produces noise
# in the journal and, if it were wired to OnFailure, a loop. --test is the
# exception: it exists to be checked, so it fails when delivery fails.
set -uo pipefail

cd "$(dirname "$0")/.."

ENV_FILE=".env.bash"
if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a
fi

WEBHOOK="${DISCORD_WEBHOOK_URL:-}"
HOSTNAME_STR="$(uname -n)"

MODE="${1:---test}"
UNIT="${2:-}"
EXTRA="${3:-}"

# --test is a check, so it reports a problem by failing. The other modes run as
# failure handlers and must never exit non-zero: see the header comment.
_exit_quietly() { [[ "$MODE" == "--test" ]] && exit 1; exit 0; }

if [[ -z "$WEBHOOK" ]]; then
  echo "notify-discord: DISCORD_WEBHOOK_URL is not set; nothing sent." >&2
  _exit_quietly
fi

# A webhook URL is https://discord.com/api/webhooks/<id>/<token>, created under
# Server Settings -> Integrations -> Webhooks -> New Webhook -> Copy Webhook
# URL. The link in the Discord app's address bar is a /channels/ URL, which is
# a different thing entirely - and posting to it returns HTTP 200 with the web
# app's HTML, so without this check a wrong URL looks exactly like a delivered
# message. Checked here rather than trusted, because the failure is silent.
if [[ ! "$WEBHOOK" =~ ^https://(canary\.|ptb\.)?discord(app)?\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+$ ]]; then
  echo "notify-discord: DISCORD_WEBHOOK_URL is not a webhook URL." >&2
  echo "  expected  https://discord.com/api/webhooks/<id>/<token>" >&2
  echo "  got       ${WEBHOOK:0:40}..." >&2
  case "$WEBHOOK" in
    */channels/*)
      echo "  That is a channel link from the Discord app's address bar, not a" >&2
      echo "  webhook. Create one under Server Settings -> Integrations ->" >&2
      echo "  Webhooks -> New Webhook -> Copy Webhook URL." >&2 ;;
  esac
  _exit_quietly
fi

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

# A webhook POST returns 204 No Content (200 only with ?wait=true). The URL
# shape was checked above, so a 2xx here really did come from the API.
if [[ "$HTTP" == "204" || "$HTTP" == "200" ]]; then
  echo "notify-discord: sent (${TITLE}) HTTP ${HTTP}"
  exit 0
fi

echo "notify-discord: delivery FAILED, HTTP ${HTTP}" >&2
case "$HTTP" in
  401|403) echo "  The webhook was deleted or its token was rotated." >&2 ;;
  404)     echo "  No such webhook. It was deleted, or the URL is wrong." >&2 ;;
  429)     echo "  Rate limited by Discord." >&2 ;;
  000)     echo "  No HTTP response: DNS, network or TLS failure." >&2 ;;
esac
_exit_quietly
