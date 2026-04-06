#!/bin/bash

set -euo pipefail

echo "🌐 Multi-Chain Exporter Setup Script (Virtualenv + Net Observer)"

echo "📦 Installing required packages..."
sudo apt-get update -y
sudo apt-get install -y python3-venv mtr-tiny curl

# Resolve app directory to an absolute path
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$APP_DIR/venv"
SERVICE_NAME="chainprobe.service"

cd "$APP_DIR"

detect_instance_name() {
  local hn
  hn="$(hostname -s 2>/dev/null || hostname)"
  hn="${hn%%.*}"
  printf '%s' "$hn"
}

INSTANCE_NAME="$(detect_instance_name)"

# ---------------------------
# Create / reuse virtualenv
# ---------------------------
if [ ! -d "$VENV_DIR" ]; then
  echo "📦 Creating Python virtualenv at: $VENV_DIR"
  python3 -m venv "$VENV_DIR"
else
  echo "📦 Reusing existing virtualenv at: $VENV_DIR"
fi

echo "📦 Installing required Python packages into venv..."
# shellcheck disable=SC1090
source "$VENV_DIR/bin/activate"
pip install --upgrade pip
pip install httpx prometheus_client toml psutil web3 schedule
deactivate

# ---------------------------
# Gather config input
# ---------------------------
echo "🛠️  Exporter Configuration"
read -r -p "Enter protocol (cosmos / evm / other): " protocol
while [[ -z "$protocol" ]]; do
  read -r -p "Enter protocol (cosmos / evm / other): " protocol
done

read -r -p "Enter network (mainnet / testnet / devnet / custom): " network
while [[ -z "$network" ]]; do
  read -r -p "Enter network (mainnet / testnet / devnet / custom): " network
done

read -r -p "Is this a validator node? (yes/no): " is_validator
while [[ "$is_validator" != "yes" && "$is_validator" != "no" ]]; do
  read -r -p "Is this a validator node? (yes/no): " is_validator
done

read -r -p "Enter Prometheus metrics port (default 3000): " metrics_port
metrics_port=${metrics_port:-3000}

read -r -p "Run mode (docker/systemd): " run_mode
while [[ "$run_mode" != "docker" && "$run_mode" != "systemd" ]]; do
  read -r -p "Run mode (docker/systemd): " run_mode
done

read -r -p "Enter node provider (default NirvanaLab): " node_provider
node_provider=${node_provider:-NirvanaLab}

read -r -p "Enter node region: " node_region
while [[ -z "$node_region" ]]; do
  read -r -p "Enter node region: " node_region
done

echo "🖥️  Instance detected from hostname: $INSTANCE_NAME"

binary_input=""
docker_input=""

if [[ "$run_mode" == "systemd" ]]; then
  read -r -p "Enter comma-separated systemd binary names (or leave blank): " binary_input
else
  read -r -p "Enter comma-separated Docker container names (or leave blank): " docker_input
fi

# ---------------------------
# Generate config.toml (in repo directory)
# ---------------------------
echo "📝 Writing config.toml..."
cat > "$APP_DIR/config.toml" <<EOF_CFG
protocol = "$protocol"
network = "$network"
metrics_port = $metrics_port
runtime = "$run_mode"
EOF_CFG

# ---------------------------
# Cosmos-specific config
# ---------------------------
if [[ "$protocol" == "cosmos" ]]; then
  echo "🔗 Cosmos configuration"
  cat >> "$APP_DIR/config.toml" <<EOF_CFG

host = "http://localhost"
rest_port = 1317
EOF_CFG

  if [[ "$is_validator" == "yes" ]]; then
    read -r -p "Enter valcons_address: " valcons_address
    read -r -p "Enter valoper_address: " valoper_address
    read -r -p "Enter account_address: " account_address
    read -r -p "Enter scaling factor (default 1e18): " scaling_factor
    scaling_factor=${scaling_factor:-1e18}

cat >> "$APP_DIR/config.toml" <<EOF_CFG

valcons_address = "$valcons_address"
valoper_address = "$valoper_address"
account_address = "$account_address"

[metrics.latest_block]
path = "/cosmos/base/tendermint/v1beta1/blocks/latest"
description = "Latest block height"

[metrics.validator_missed_blocks_total]
path = "/cosmos/slashing/v1beta1/signing_infos/\${valcons_address}"
description = "Total missed blocks"

[metrics.validator_is_jailed]
path = "/cosmos/staking/v1beta1/validators/\${valoper_address}"
description = "Is validator jailed"

[metrics.validator_is_active]
path = "/cosmos/staking/v1beta1/validators/\${valoper_address}"
description = "Is validator active"

[metrics.validator_commission_rate]
path = "/cosmos/staking/v1beta1/validators/\${valoper_address}"
description = "Validator commission rate"

[metrics.validator_commission_amount]
path = "/cosmos/distribution/v1beta1/validators/\${valoper_address}/commission"
description = "Total commission amount"
scaling_factor = $scaling_factor

[metrics.validator_rewards_total]
path = "/cosmos/distribution/v1beta1/delegators/\${account_address}/rewards/\${valoper_address}"
description = "Validator total rewards"
scaling_factor = $scaling_factor
EOF_CFG

  else
cat >> "$APP_DIR/config.toml" <<EOF_CFG

[metrics.latest_block]
path = "/cosmos/base/tendermint/v1beta1/blocks/latest"
description = "Latest block height"
EOF_CFG
  fi

# ---------------------------
# EVM-specific config
# ---------------------------
elif [[ "$protocol" == "evm" ]]; then
cat >> "$APP_DIR/config.toml" <<EOF_CFG

[default]
rpcaddress = "http://localhost:8545"

[metrics.latest_block]
description = "Latest block number of the chain"

[metrics.peer_count]
description = "Number of peers"

[metrics.syncing]
description = "Syncing status"

[metrics.blocks_to_sync]
description = "Remaining blocks to sync"

[metrics.network_name]
description = "Network chain ID or name"

[metrics.net_listening]
description = "Whether client is accepting connections"
EOF_CFG
fi

# ---------------------------
# Add binaries (systemd services)
# ---------------------------
if [[ "$run_mode" == "systemd" && -n "$binary_input" ]]; then
  echo -e "\n[binaries]" >> "$APP_DIR/config.toml"
  IFS=',' read -ra BIN_ARRAY <<< "$binary_input"
  for alias in "${BIN_ARRAY[@]}"; do
    alias_trimmed=$(echo "$alias" | xargs)
    unit_path=$(systemctl show "${alias_trimmed}.service" -p FragmentPath --value 2>/dev/null || true)
    safe_alias="\"$alias_trimmed\""

    if [[ -n "$unit_path" && -f "$unit_path" ]]; then
      echo "$safe_alias = \"$unit_path\"" >> "$APP_DIR/config.toml"
      echo "[✓] Found unit for $alias_trimmed → $unit_path"
    else
      echo "[!] Could not find unit file for $alias_trimmed. Skipping..."
    fi
  done
fi

# ---------------------------
# Add Docker containers
# ---------------------------
if [[ "$run_mode" == "docker" && -n "$docker_input" ]]; then
  echo -e "\n[docker_containers]" >> "$APP_DIR/config.toml"
  IFS=',' read -ra DOCKER_ARRAY <<< "$docker_input"
  for alias in "${DOCKER_ARRAY[@]}"; do
    alias_trimmed=$(echo "$alias" | xargs)
    safe_alias="\"$alias_trimmed\""
    echo "$safe_alias = true" >> "$APP_DIR/config.toml"
  done
fi

# ---------------------------
# Add Net Observer config
# ---------------------------
cat >> "$APP_DIR/config.toml" <<EOF_CFG

[net_observer]
enabled = true
provider = "$node_provider"
region = "$node_region"
instance = "$INSTANCE_NAME"
interval_seconds = 30
mtr_count = 5
mtr_max_hops = 30
mtr_timeout_seconds = 15

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
EOF_CFG

echo "✅ config.toml created at $APP_DIR/config.toml."

# ---------------------------
# Create systemd service
# ---------------------------
echo "🔧 Creating systemd service: chainprobe"

sudo bash -c "cat > /etc/systemd/system/chainprobe.service" <<EOF_SVC
[Unit]
Description=chainprobe Multi-Protocol Exporter
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$APP_DIR
ExecStart=$VENV_DIR/bin/python $APP_DIR/main.py --config $APP_DIR/config.toml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF_SVC

# ---------------------------
# Enable + start service
# ---------------------------
echo "🟢 Starting chainprobe service..."
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable chainprobe
sudo systemctl restart chainprobe

# ---------------------------
# Done!
# ---------------------------
echo -e "\n🚀 chainprobe is installed and running!"
echo "Check status:  sudo systemctl status chainprobe"
echo "Logs:          journalctl -u chainprobe -f"
echo "Metrics:       curl http://localhost:$metrics_port/metrics"
