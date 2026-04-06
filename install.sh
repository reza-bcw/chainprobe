#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/net_observer"
ENV_FILE="${APP_DIR}/.env"

mkdir -p "${APP_DIR}"

detect_instance() {
  local hn
  hn="$(hostname -s 2>/dev/null || hostname)"
  hn="${hn%%.*}"
  printf '%s' "$hn"
}

detect_region_from_hostname() {
  local hn
  hn="$(hostname -s 2>/dev/null || hostname)"
  hn="$(printf '%s' "$hn" | tr '[:upper:]' '[:lower:]')"

  case "$hn" in
    *san* ) echo "San" ;;
    *fra*|*frank* ) echo "Frank" ;;
    *nyc* ) echo "NYC" ;;
    *ash* ) echo "ASH" ;;
    *ams*|*amsterdam* ) echo "Amsterdam" ;;
    *lim*|*limburg* ) echo "Limburg" ;;
    *wash* ) echo "Washington" ;;
    *cal*|*california* ) echo "California" ;;
    *queensland*|*qld* ) echo "Queensland" ;;
    * )
      return 1
      ;;
  esac
}

detect_region_from_public_ip() {
  local city=""
  local region=""

  if command -v curl >/dev/null 2>&1; then
    city="$(curl -fsSL --max-time 5 https://ipinfo.io/city 2>/dev/null || true)"
    region="$(curl -fsSL --max-time 5 https://ipinfo.io/region 2>/dev/null || true)"
  fi

  city="$(printf '%s' "$city" | tr -d '\r' | xargs || true)"
  region="$(printf '%s' "$region" | tr -d '\r' | xargs || true)"

  case "$(printf '%s %s' "$city" "$region" | tr '[:upper:]' '[:lower:]')" in
    *san* ) echo "San" ;;
    *frank*|*hesse* ) echo "Frank" ;;
    *new\ york*|*nyc* ) echo "NYC" ;;
    *ashburn*|*virginia* ) echo "ASH" ;;
    *amsterdam* ) echo "Amsterdam" ;;
    *limburg* ) echo "Limburg" ;;
    *washington* ) echo "Washington" ;;
    *california* ) echo "California" ;;
    *queensland* ) echo "Queensland" ;;
    * )
      return 1
      ;;
  esac
}

detect_region() {
  detect_region_from_hostname && return 0
  detect_region_from_public_ip && return 0
  echo "Unknown"
}

INSTANCE_NAME="$(detect_instance)"
REGION="$(detect_region)"

read -r -p "Node provider: " PROVIDER
while [ -z "${PROVIDER}" ]; do
  read -r -p "Node provider: " PROVIDER
done

INTERVAL_SECONDS="${INTERVAL_SECONDS:-30}"
LISTEN_PORT="${LISTEN_PORT:-9400}"
MTR_COUNT="${MTR_COUNT:-5}"
MTR_MAX_HOPS="${MTR_MAX_HOPS:-30}"
MTR_TIMEOUT_SECONDS="${MTR_TIMEOUT_SECONDS:-15}"

PUBLIC_TARGETS="8.8.8.8|California|google,1.1.1.1|Queensland|cloudflare"
CROSS_REGION_TARGETS="34.86.142.37|Washington|google"
CRITICAL_TARGETS="185.209.179.155|NYC|latitude,103.219.171.153|Frankfurt|latitude,64.34.85.31|Frankfurt2|latitude,57.129.83.10|Limburg|ovh,67.213.127.51|Amsterdam|latitude,185.26.9.113|ASH|latitude"

cat > "${ENV_FILE}" <<EOF
PROVIDER=${PROVIDER}
REGION=${REGION}
INSTANCE_NAME=${INSTANCE_NAME}

PUBLIC_TARGETS=${PUBLIC_TARGETS}
CROSS_REGION_TARGETS=${CROSS_REGION_TARGETS}
CRITICAL_TARGETS=${CRITICAL_TARGETS}

INTERVAL_SECONDS=${INTERVAL_SECONDS}
LISTEN_PORT=${LISTEN_PORT}
MTR_COUNT=${MTR_COUNT}
MTR_MAX_HOPS=${MTR_MAX_HOPS}
MTR_TIMEOUT_SECONDS=${MTR_TIMEOUT_SECONDS}
EOF

echo
echo "Written: ${ENV_FILE}"
echo "Detected instance: ${INSTANCE_NAME}"
echo "Detected region: ${REGION}"
echo "Provider: ${PROVIDER}"
echo
cat "${ENV_FILE}"
