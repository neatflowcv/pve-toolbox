#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  fetch-system-logs.sh [--env-file FILE] [--output-dir DIR] [--since TIME] [--until TIME] [--timeout SECONDS] [--json]

Fetch journal system logs from every Proxmox VE node.

Options:
      --env-file FILE    Env file path. Default: .env
      --output-dir DIR   Output directory. Default: ./system-logs-TIMESTAMP
      --since TIME       Start time. Default: "1 hour ago"
                         Examples: "2026-07-03 10:00:00", "1 hour ago", 1783042800
      --until TIME       End time. Default: "now"
                         Examples: "2026-07-03 11:00:00", "now", 1783046400
      --timeout SECONDS  Max seconds per HTTP request. Default: 15
      --json             Write raw journal API JSON files instead of text log files.
  -h, --help             Show this help.
EOF
}

load_env_file() {
  local env_file="$1"

  if [[ ! -f "$env_file" ]]; then
    echo "error: env file not found: $env_file" >&2
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

to_epoch_seconds() {
  local value="$1"
  local label="$2"

  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$value"
    return
  fi

  if ! date -d "$value" +%s 2>/dev/null; then
    echo "error: invalid --${label} time: ${value}" >&2
    echo "hint: use epoch seconds or a date string accepted by GNU date, for example: \"2026-07-03 10:00:00\"" >&2
    exit 1
  fi
}

curl_to_file() {
  local output_file="$1"
  shift

  curl "${curl_opts[@]}" \
    --output "$output_file" \
    --write-out '%{http_code}' \
    "$@" || true
}

response_error() {
  local file="$1"

  jq -r '.message? // .errors? // .data? // . // empty' "$file" 2>/dev/null \
    | tr '\n\t' '  ' \
    | cut -c1-240
}

write_journal_log() {
  local response_file="$1"
  local log_file="$2"

  jq -r '
    .data[]? |
    if type == "object" then
      [
        (.__REALTIME_TIMESTAMP // .realtime // .time // .t // ""),
        (.PRIORITY // .priority // .n // .pri // ""),
        (._SYSTEMD_UNIT // .SYSLOG_IDENTIFIER // .identifier // .service // .tag // ""),
        (.MESSAGE // .msg // .message // "")
      ] | @tsv
    else
      tostring
    end
  ' "$response_file" >"$log_file"
}

env_file=".env"
output_dir=""
since=""
until=""
timeout=15
json=0

while (($#)); do
  case "$1" in
    --env-file)
      env_file="${2:-}"
      shift 2
      ;;
    --output-dir)
      output_dir="${2:-}"
      shift 2
      ;;
    --since)
      since="${2:-}"
      shift 2
      ;;
    --until)
      until="${2:-}"
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
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if ! [[ "$timeout" =~ ^[0-9]+$ ]] || ((timeout < 1)); then
  echo "error: --timeout must be a positive integer" >&2
  exit 1
fi

if [[ -z "$since" && -z "$until" ]]; then
  since="1 hour ago"
  until="now"
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
if [[ -z "$output_dir" ]]; then
  output_dir="./system-logs-$(date +%Y%m%d-%H%M%S)"
fi

require_cmd curl
require_cmd jq
require_cmd date

curl_opts=(--silent --show-error --compressed --connect-timeout "$timeout" --max-time "$timeout")
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

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$output_dir"

since_param=""
until_param=""
if [[ -n "$since" ]]; then
  since_param="$(to_epoch_seconds "$since" "since")"
fi
if [[ -n "$until" ]]; then
  until_param="$(to_epoch_seconds "$until" "until")"
fi

ticket_file="${tmp_dir}/ticket.json"
ticket_code="$(
  curl_to_file "$ticket_file" \
    --request POST \
    --data-urlencode "username=${user}" \
    --data-urlencode "password=${password}" \
    "${endpoint}/api2/json/access/ticket"
)"

if [[ "$ticket_code" != "200" ]]; then
  error="$(response_error "$ticket_file")"
  [[ -n "$error" ]] || error="request failed"
  echo "error: login failed: HTTP ${ticket_code}: ${error}" >&2
  exit 1
fi

ticket="$(jq -r '.data.ticket // empty' "$ticket_file")"
if [[ -z "$ticket" ]]; then
  echo "error: login succeeded but no auth ticket was returned" >&2
  exit 1
fi

nodes_file="${tmp_dir}/nodes.json"
nodes_code="$(
  curl_to_file "$nodes_file" \
    --cookie "PVEAuthCookie=${ticket}" \
    "${endpoint}/api2/json/nodes"
)"

if [[ "$nodes_code" != "200" ]]; then
  error="$(response_error "$nodes_file")"
  [[ -n "$error" ]] || error="request failed"
  echo "error: node list failed: HTTP ${nodes_code}: ${error}" >&2
  exit 1
fi

mapfile -t nodes < <(jq -r '.data[].node' "$nodes_file")
if ((${#nodes[@]} == 0)); then
  echo "error: no nodes returned by Proxmox API" >&2
  exit 1
fi

echo "output_dir=${output_dir}"
echo "nodes=${nodes[*]}"
echo "time_range=since:${since:-<none>} until:${until:-<none>}"
echo "journal_api_time_range=since:${since_param:-<none>} until:${until_param:-<none>}"

failed_nodes=0
for node in "${nodes[@]}"; do
  response_file="${tmp_dir}/${node}-journal.json"
  log_file="${output_dir}/${node}-journal.log"
  json_file="${output_dir}/${node}-journal.json"
  journal_params=()

  if [[ -n "$since_param" ]]; then
    journal_params+=(--data-urlencode "since=${since_param}")
  fi
  if [[ -n "$until_param" ]]; then
    journal_params+=(--data-urlencode "until=${until_param}")
  fi

  code="$(
    curl_to_file "$response_file" \
      --cookie "PVEAuthCookie=${ticket}" \
      --get \
      "${journal_params[@]}" \
      "${endpoint}/api2/json/nodes/${node}/journal"
  )"

  if [[ "$code" == "200" ]] && jq -e '.data | type == "array"' "$response_file" >/dev/null 2>&1; then
    if ((json)); then
      if jq '.' "$response_file" >"$json_file"; then
        rows="$(jq '.data | length' "$json_file")"
        printf '%s OK rows=%s file=%s\n' "$node" "$rows" "$json_file"
        continue
      fi
    elif write_journal_log "$response_file" "$log_file"; then
      rows="$(wc -l <"$log_file")"
      printf '%s OK rows=%s file=%s\n' "$node" "$rows" "$log_file"
      continue
    fi
  fi

  rm -f "$log_file"
  rm -f "$json_file"
  error="$(response_error "$response_file")"
  [[ -n "$error" ]] || error="request failed or unexpected response"
  printf '%s FAIL HTTP %s %s\n' "$node" "$code" "$error" >&2
  failed_nodes=$((failed_nodes + 1))
done

if ((failed_nodes)); then
  echo "error: failed to fetch logs for ${failed_nodes} node(s)" >&2
  exit 1
fi
