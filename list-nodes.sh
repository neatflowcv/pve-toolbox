#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  list-nodes.sh [--env-file FILE] [--json]

Examples:
  ./list-nodes.sh
  ./list-nodes.sh --json
  ./list-nodes.sh --env-file ./prod.env

Options:
      --env-file FILE  Env file path. Default: .env
      --json           Print raw node JSON array.
  -h, --help           Show this help.
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

env_file=".env"
json=0

while (($#)); do
  case "$1" in
    --env-file)
      env_file="${2:-}"
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

curl_opts=(--silent --show-error --fail)
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
  curl "${curl_opts[@]}" \
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

nodes_response="$(
  curl "${curl_opts[@]}" \
    --cookie "PVEAuthCookie=${ticket}" \
    "${endpoint}/api2/json/nodes"
)"

if ((json)); then
  jq '.data' <<<"$nodes_response"
else
  jq -r '
    ["NODE", "STATUS", "UPTIME_SECONDS", "CPU_USAGE", "MEM_USAGE"],
    (.data[] | [
      .node,
      .status,
      ((.uptime // 0) | tostring),
      (((.cpu // 0) * 100) | tostring),
      (if (.maxmem // 0) > 0 then ((.mem / .maxmem) * 100 | tostring) else "0" end)
    ])
    | @tsv
  ' <<<"$nodes_response" | column -t -s $'\t'
fi
