#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  fetch-node-rrddata.sh NODE [--env-file FILE] [--timeframe TIMEFRAME] [--cf CF] [--timeout SECONDS] [--json]
  fetch-node-rrddata.sh --node NODE [--env-file FILE] [--timeframe TIMEFRAME] [--cf CF] [--timeout SECONDS] [--json]

Fetch RRD data for a specific Proxmox VE node.

Examples:
  ./fetch-node-rrddata.sh pve1
  ./fetch-node-rrddata.sh --node pve1 --timeframe day
  ./fetch-node-rrddata.sh --node pve1 --timeframe week --cf MAX --json
  ./fetch-node-rrddata.sh --env-file ./prod.env pve1

Options:
      --node NODE           Proxmox VE node name.
      --env-file FILE       Env file path. Default: .env
      --timeframe VALUE     RRD timeframe. Default: hour
                            Common values: hour, day, week, month, year
      --cf VALUE            Consolidation function. Default: AVERAGE
                            Common values: AVERAGE, MAX
      --timeout SECONDS     Max seconds per HTTP request. Default: 15
      --json                Print raw RRD API JSON data array.
  -h, --help                Show this help.
EOF
}

load_env_file() {
  local env_file="$1"

  if [[ ! -f "$env_file" ]]; then
    echo "error: env file not found: $env_file" >&2
    echo "hint: copy .env.sample to .env and fill in the values" >&2
    exit 1
  fi

  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required command not found: $1" >&2
    exit 1
  fi
}

curl_to_stdout() {
  curl "${curl_opts[@]}" "$@"
}

env_file=".env"
node=""
timeframe="hour"
cf="AVERAGE"
timeout=15
json=0

while (($#)); do
  case "$1" in
    --node)
      node="${2:-}"
      shift 2
      ;;
    --env-file)
      env_file="${2:-}"
      shift 2
      ;;
    --timeframe)
      timeframe="${2:-}"
      shift 2
      ;;
    --cf)
      cf="${2:-}"
      shift 2
      ;;
    --timeout)
      timeout="${2:-}"
      shift 2
      ;;
    --json)
      json=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -n "$node" ]]; then
        echo "error: multiple node values provided: ${node}, $1" >&2
        usage >&2
        exit 1
      fi
      node="$1"
      shift
      ;;
  esac
done

if [[ -z "$node" ]]; then
  echo "error: node is required" >&2
  usage >&2
  exit 1
fi

if [[ -z "$timeframe" ]]; then
  echo "error: --timeframe must not be empty" >&2
  exit 1
fi

if [[ -z "$cf" ]]; then
  echo "error: --cf must not be empty" >&2
  exit 1
fi

if ! [[ "$timeout" =~ ^[0-9]+$ ]] || ((timeout < 1)); then
  echo "error: --timeout must be a positive integer" >&2
  exit 1
fi

load_env_file "$env_file"

endpoint="${PVE_ENDPOINT:-}"
user="${PVE_USER_ID:-}"
password="${PVE_PASSWORD:-}"
insecure="${PVE_INSECURE:-false}"

missing=()
[[ -n "$endpoint" ]] || missing+=(PVE_ENDPOINT)
[[ -n "$user" ]] || missing+=(PVE_USER_ID)
[[ -n "$password" ]] || missing+=(PVE_PASSWORD)

if ((${#missing[@]})); then
  printf 'error: missing required env values: %s\n' "${missing[*]}" >&2
  exit 1
fi

endpoint="${endpoint%/}"

require_cmd curl
require_cmd jq
if ((!json)); then
  require_cmd column
fi

curl_opts=(--silent --show-error --fail --compressed --connect-timeout "$timeout" --max-time "$timeout")
case "${insecure,,}" in
  1|true|yes|y|on)
    curl_opts+=(--insecure)
    ;;
  0|false|no|n|off|"")
    ;;
  *)
    echo "error: PVE_INSECURE must be true or false" >&2
    exit 1
    ;;
esac

ticket_response="$(
  curl_to_stdout \
    --request POST \
    --data-urlencode "username=${user}" \
    --data-urlencode "password=${password}" \
    "${endpoint}/api2/json/access/ticket"
)"

ticket="$(jq -r '.data.ticket // empty' <<<"$ticket_response")"
if [[ -z "$ticket" ]]; then
  echo "error: login succeeded but no auth ticket was returned" >&2
  exit 1
fi

rrd_response="$(
  curl_to_stdout \
    --cookie "PVEAuthCookie=${ticket}" \
    --get \
    --data-urlencode "timeframe=${timeframe}" \
    --data-urlencode "cf=${cf}" \
    "${endpoint}/api2/json/nodes/${node}/rrddata"
)"

if ((json)); then
  jq '.data' <<<"$rrd_response"
else
  jq -r '
    def bytes:
      if . == null then ""
      elif . >= 1099511627776 then ((. / 1099511627776 * 100 | round) / 100 | tostring) + "T"
      elif . >= 1073741824 then ((. / 1073741824 * 100 | round) / 100 | tostring) + "G"
      elif . >= 1048576 then ((. / 1048576 * 100 | round) / 100 | tostring) + "M"
      elif . >= 1024 then ((. / 1024 * 100 | round) / 100 | tostring) + "K"
      else tostring + "B"
      end;
    def pct:
      if . == null then ""
      else ((. * 10000 | round) / 100 | tostring) + "%"
      end;
    def number:
      if . == null then ""
      elif type == "number" then ((. * 100 | round) / 100 | tostring)
      else tostring
      end;
    ["TIME", "CPU", "IOWAIT", "LOADAVG", "MEM", "NETIN", "NETOUT", "DISKREAD", "DISKWRITE"],
    (.data[]? | [
      ((.time // "") | tostring),
      (.cpu | pct),
      (.iowait | pct),
      (.loadavg | number),
      (if (.mem != null and .maxmem != null and .maxmem > 0) then ((.mem | bytes) + "/" + (.maxmem | bytes)) elif .mem != null then (.mem | bytes) else "" end),
      (.netin | bytes),
      (.netout | bytes),
      (.diskread | bytes),
      (.diskwrite | bytes)
    ])
    | @tsv
  ' <<<"$rrd_response" | column -t -s $'\t'
fi
