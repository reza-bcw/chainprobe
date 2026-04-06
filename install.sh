#!/bin/bash

set -e

echo "🌐 Multi-Chain Exporter Setup Script (Virtualenv)"

echo "📦 Installing required system packages..."
sudo apt-get update -y
sudo apt-get install -y python3-venv mtr

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$APP_DIR/venv"
CONFIG_FILE="$APP_DIR/config.toml"

cd "$APP_DIR"

if [ ! -d "$VENV_DIR" ]; then
  echo "📦 Creating Python virtualenv at: $VENV_DIR"
  python3 -m venv "$VENV_DIR"
else
  echo "📦 Reusing existing virtualenv at: $VENV_DIR"
fi

echo "📦 Installing required Python packages into venv..."
source "$VENV_DIR/bin/activate"
pip install --upgrade pip
pip install httpx prometheus_client toml psutil web3 schedule
deactivate

append_targets() {
  local raw="$1"
  local class_name="$2"

  IFS=',' read -ra ITEMS <<< "$raw"
  for item in "${ITEMS[@]}"; do
    item="$(echo "$item" | xargs)"
    [[ -z "$item" ]] && continue

    IFS='|' read -r address location provider <<< "$item"

    address="$(echo "${address:-}" | xargs)"
    location="$(echo "${location:-unknown}" | xargs)"
    provider="$(echo "${provider:-unknown}" | xargs)"

    [[ -z "$address" ]] && continue

    cat >> "$CONFIG_FILE" <<EOF

[[targets]]
address = "$address"
class_name = "$class_name"
location = "$location"
provider = "$provider"
EOF
  done
}

write_new_config() {
  echo "🛠️  Exporter Configuration"
  read -p "Enter protocol (cosmos / evm / net_observer / other): " protocol

  default_port=3000
  read -p "Enter Prometheus metrics port (default ${default_port}): " metrics_port
  metrics_port=${metrics_port:-$default_port}

  echo "📝 Writing config.toml..."
  cat > "$CONFIG_FILE" <<EOF
protocol = "$protocol"
metrics_port = $metrics_port
EOF

  if [[ "$protocol" == "cosmos" ]]; then
    read -p "Is this a validator node? (yes/no): " is_validator

    cat >> "$CONFIG_FILE" <<EOF

host = "http://localhost"
rest_port = 1317
EOF

    if [[ "$is_validator" == "yes" ]]; then
      read -p "Enter valcons_address: " valcons_address
      read -p "Enter valoper_address: " valoper_address
      read -p "Enter account_address: " account_address
      read -p "Enter scaling factor (default 1e18): " scaling_factor
      scaling_factor=${scaling_factor:-1e18}

      cat >> "$CONFIG_FILE" <<EOF

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
EOF
    else
      cat >> "$CONFIG_FILE" <<EOF

[metrics.latest_block]
path = "/cosmos/base/tendermint/v1beta1/blocks/latest"
description = "Latest block height"
EOF
    fi

  elif [[ "$protocol" == "evm" ]]; then
    cat >> "$CONFIG_FILE" <<EOF

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
EOF

  elif [[ "$protocol" == "net_observer" ]]; then
    read -p "Provider: " provider
    read -p "Region: " region
    read -p "Instance name: " instance
    read -p "Interval seconds (default 30): " interval_seconds
    interval_seconds=${interval_seconds:-30}
    read -p "MTR count (default 5): " mtr_count
    mtr_count=${mtr_count:-5}
    read -p "MTR max hops (default 30): " mtr_max_hops
    mtr_max_hops=${mtr_max_hops:-30}
    read -p "MTR timeout seconds (default 15): " mtr_timeout_seconds
    mtr_timeout_seconds=${mtr_timeout_seconds:-15}

    read -p "Enter PUBLIC_TARGETS (addr|location|provider,...): " public_targets
    read -p "Enter CROSS_REGION_TARGETS (addr|location|provider,...): " cross_region_targets
    read -p "Enter CRITICAL_TARGETS (addr|location|provider,...): " critical_targets

    cat >> "$CONFIG_FILE" <<EOF

provider = "$provider"
region = "$region"
instance = "$instance"
interval_seconds = $interval_seconds
mtr_count = $mtr_count
mtr_max_hops = $mtr_max_hops
mtr_timeout_seconds = $mtr_timeout_seconds
EOF

    append_targets "$public_targets" "public"
    append_targets "$cross_region_targets" "cross_region"
    append_targets "$critical_targets" "critical"
  fi

  read -p "Enter comma-separated systemd binary names (or leave blank): " binary_input
  read -p "Enter comma-separated Docker container names (or leave blank): " docker_input

  if [[ -n "$binary_input" ]]; then
    echo -e "\n[binaries]" >> "$CONFIG_FILE"
    IFS=',' read -ra BIN_ARRAY <<< "$binary_input"
    for alias in "${BIN_ARRAY[@]}"; do
      alias_trimmed=$(echo "$alias" | xargs)
      unit_path=$(systemctl show "${alias_trimmed}.service" -p FragmentPath --value 2>/dev/null)
      safe_alias="\"$alias_trimmed\""

      if [[ -n "$unit_path" && -f "$unit_path" ]]; then
        echo "$safe_alias = \"$unit_path\"" >> "$CONFIG_FILE"
        echo "[✓] Found unit for $alias_trimmed → $unit_path"
      else
        echo "[!] Could not find unit file for $alias_trimmed. Skipping..."
      fi
    done
  fi

  if [[ -n "$docker_input" ]]; then
    echo -e "\n[docker_containers]" >> "$CONFIG_FILE"
    IFS=',' read -ra DOCKER_ARRAY <<< "$docker_input"
    for alias in "${DOCKER_ARRAY[@]}"; do
      alias_trimmed=$(echo "$alias" | xargs)
      safe_alias="\"$alias_trimmed\""
      echo "$safe_alias = true" >> "$CONFIG_FILE"
    done
  fi

  echo "✅ config.toml created at $CONFIG_FILE."
}

if [[ -f "$CONFIG_FILE" ]]; then
  echo "⚠️ Existing config.toml found: $CONFIG_FILE"
  read -p "Do you want to keep the existing config.toml? (yes/no): " keep_existing_config

  if [[ "$keep_existing_config" == "yes" ]]; then
    echo "✅ Keeping existing config.toml"
  else
    backup_file="${CONFIG_FILE}.bak.$(date +%s)"
    cp "$CONFIG_FILE" "$backup_file"
    echo "🗂️ Backup created: $backup_file"
    write_new_config
  fi
else
  write_new_config
fi

echo "🔧 Creating systemd service: chainprobe"

sudo bash -c "cat > /etc/systemd/system/chainprobe.service" <<EOF
[Unit]
Description=chainprobe Multi-Protocol Exporter
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$APP_DIR
ExecStart=$VENV_DIR/bin/python $APP_DIR/main.py --config $CONFIG_FILE
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "🟢 Starting chainprobe service..."
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable chainprobe
sudo systemctl restart chainprobe

echo -e "\n🚀 chainprobe is installed and running!"
echo "Check status:  sudo systemctl status chainprobe"
echo "Logs:          journalctl -u chainprobe -f"
echo "Metrics:       curl http://localhost:\$(grep '^metrics_port' $CONFIG_FILE | awk '{print \$3}')/metrics"
