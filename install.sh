#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/net_observer"
ENV_FILE="${APP_DIR}/.env"

mkdir -p "${APP_DIR}"

INSTANCE_NAME="$(hostname -s 2>/dev/null || hostname)"
INSTANCE_NAME="${INSTANCE_NAME%%.*}"

read -r -p "Node provider: " PROVIDER
while [ -z "${PROVIDER}" ]; do
  read -r -p "Node provider: " PROVIDER
done

read -r -p "Node region: " REGION
while [ -z "${REGION}" ]; do
  read -r -p "Node region: " REGION
done

INTERVAL_SECONDS="${INTERVAL_SECONDS:-30}"
LISTEN_PORT="${LISTEN_PORT:-9400}"
MTR_COUNT="${MTR_COUNT:-5}"
MTR_MAX_HOPS="${MTR_MAX_HOPS:-30}"
MTR_TIMEOUT_SECONDS="${MTR_TIMEOUT_SECONDS:-15}"

PUBLIC_TARGETS=""
CROSS_REGION_TARGETS=""
CRITICAL_TARGETS=""

append_target() {
  local bucket="$1"
  local value="$2"

  if [ -z "${!bucket}" ]; then
    printf -v "$bucket" '%s' "$value"
  else
    printf -v "$bucket" '%s,%s' "${!bucket}" "$value"
  fi
}

collect_targets() {
  local class_name="$1"

  while true; do
    read -r -p "Add ${class_name} target address (empty to finish): " address
    [ -z "${address}" ] && break

    read -r -p "Location for ${address}: " location
    while [ -z "${location}" ]; do
      read -r -p "Location for ${address}: " location
    done

    read -r -p "Provider for ${address}: " target_provider
    while [ -z "${target_provider}" ]; do
      read -r -p "Provider for ${address}: " target_provider
    done

    entry="${address}|${location}|${target_provider}"

    case "${class_name}" in
      public) append_target PUBLIC_TARGETS "${entry}" ;;
      cross_region) append_target CROSS_REGION_TARGETS "${entry}" ;;
      critical) append_target CRITICAL_TARGETS "${entry}" ;;
    esac
  done
}

echo
echo "Configure public targets"
collect_targets public

echo
echo "Configure cross_region targets"
collect_targets cross_region

echo
echo "Configure critical targets"
collect_targets critical

if [ -z "${PUBLIC_TARGETS}" ] && [ -z "${CROSS_REGION_TARGETS}" ] && [ -z "${CRITICAL_TARGETS}" ]; then
  echo "No targets configured"
  exit 1
fi

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
cat "${ENV_FILE}"
