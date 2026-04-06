#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/chainprobe"
NET_OBSERVER_DIR="/opt/net_observer"
CONFIG_FILE="${APP_DIR}/config.toml"
ENV_FILE="${NET_OBSERVER_DIR}/.env"

mkdir -p "${APP_DIR}" "${NET_OBSERVER_DIR}"

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

detect_snarkos_service() {
  local path=""

  path="$(systemctl show -p FragmentPath snarkos --value 2>/dev/null || true)"
  if [ -n "$path" ] && [ -f "$path" ]; then
    echo "$path"
    return 0
  fi

  if [ -f /etc/systemd/system/snarkos.service ]; then
    echo "/etc/systemd/system/snarkos.service"
    return 0
  fi

  if [ -f /lib/systemd/system/snarkos.service ]; then
    echo "/lib/systemd/system/snarkos.service"
    return 0
  fi

  return 1
}

detect_snarkos_execstart() {
  local raw=""
  raw="$(systemctl show -p ExecStart snarkos --value 2>/dev/null || true)"
  printf '%s' "$raw"
}

detect_snarkos_binary() {
  local raw bin

  if command -v snarkos >/dev/null 2>&1; then
    command -v snarkos
    return 0
  fi

  raw="$(detect_snarkos_execstart)"
  bin="$(printf '%s' "$raw" | sed -E 's/^\{?([^ ;]+).*/\1/' | xargs || true)"

  if [ -n "$bin" ]; then
    printf '%s' "$bin"
    return 0
  fi

  return 1
}

detect_snarkos_network() {
  local raw network
  raw="$(detect_snarkos_execstart)"

  network="$(printf '%s' "$raw" | sed -nE 's/.*--network[= ]([^,; }]+).*/\1/p' | head -n1)"
  if [ -n "$network" ]; then
    printf '%s' "$network"
    return 0
  fi

  case "$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')" in
    *mainnet* ) echo "mainnet" ;;
    *testnet* ) echo "testnet" ;;
    *canary* ) echo "canary" ;;
    *beta* ) echo "beta" ;;
    *devnet* ) echo "devnet" ;;
    * ) echo "unknown" ;;
  esac
}

INSTANCE_NAME="$(detect_instance)"
REGION="$(detect_region)"
SNARKOS_SERVICE="$(detect_snarkos_service || true)"
SNARKOS_BINARY="$(detect_snarkos_binary || true)"
SNARKOS_NETWORK="$(detect_snarkos_network)"

read -r -p "Node provider [NirvanaLab]: " PROVIDER
PROVIDER="${PROVIDER:-NirvanaLab}"

INTERVAL_SECONDS="${INTERVAL_SECONDS:-30}"
LISTEN_PORT="${LISTEN_PORT:-9400}"
MTR_COUNT="${MTR_COUNT:-5}"
MTR_MAX_HOPS="${MTR_MAX_HOPS:-30}"
MTR_TIMEOUT_SECONDS="${MTR_TIMEOUT_SECONDS:-15}"
METRICS_PORT="${METRICS_PORT:-3000}"

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

cat > "${CONFIG_FILE}" <<EOF
protocol = "other"
metrics_port = ${METRICS_PORT}

[binaries]
"snarkos" = "${SNARKOS_SERVICE:-$SNARKOS_BINARY}"

[net_observer]
enabled = true
provider = "${PROVIDER}"
region = "${REGION}"
instance = "${INSTANCE_NAME}"
interval_seconds = ${INTERVAL_SECONDS}
mtr_count = ${MTR_COUNT}
mtr_max_hops = ${MTR_MAX_HOPS}
mtr_timeout_seconds = ${MTR_TIMEOUT_SECONDS}

[[net_observer.targets]]
address = "8.8.8.8"
class_name = "public"
location = "California"
provider = "google"

[[net_observer.targets]]
address = "1.1.1.1"
class_name = "public"
location = "Queensland"
provider = "cloudflare"

[[net_observer.targets]]
address = "34.86.142.37"
class_name = "cross_region"
location = "Washington"
provider = "google"

[[net_observer.targets]]
address = "185.209.179.155"
class_name = "critical"
location = "NYC"
provider = "latitude"

[[net_observer.targets]]
address = "103.219.171.153"
class_name = "critical"
location = "Frankfurt"
provider = "latitude"

[[net_observer.targets]]
address = "64.34.85.31"
class_name = "critical"
location = "Frankfurt2"
provider = "latitude"

[[net_observer.targets]]
address = "57.129.83.10"
class_name = "critical"
location = "Limburg"
provider = "ovh"

[[net_observer.targets]]
address = "67.213.127.51"
class_name = "critical"
location = "Amsterdam"
provider = "latitude"

[[net_observer.targets]]
address = "185.26.9.113"
class_name = "critical"
location = "ASH"
provider = "latitude"
EOF

echo
echo "Detected instance: ${INSTANCE_NAME}"
echo "Detected region: ${REGION}"
echo "Detected provider: ${PROVIDER}"
echo "Detected snarkos service: ${SNARKOS_SERVICE:-not-found}"
echo "Detected snarkos binary: ${SNARKOS_BINARY:-not-found}"
echo "Detected snarkos network: ${SNARKOS_NETWORK}"
echo
echo "Written ${CONFIG_FILE}"
echo "Written ${ENV_FILE}"
