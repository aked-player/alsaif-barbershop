#!/usr/bin/env bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

SCRIPT_PATH="/hive-config/srb50xx-offset.sh"
OLD_SCRIPT_PATH="/hive-config/50xx_offset_299_to_499_when_srb.sh"
SERVICE_PATH="/etc/systemd/system/srb50xx-offset.service"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: this installer must be run as root." >&2
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "ERROR: systemctl was not found in PATH: $PATH" >&2
  echo "Run this in the main HiveOS root shell, not inside a miner/container shell." >&2
  echo "Debug commands: whoami; pwd; echo \$PATH; command -v systemctl; ls -l /bin/systemctl /usr/bin/systemctl" >&2
  exit 127
fi

echo "Cleaning old srb50xx-offset service files..."
systemctl disable --now srb50xx-offset.service 2>/dev/null || true
rm -f "$SERVICE_PATH" /etc/systemd/system/srb50xx-offset.serviceV "$OLD_SCRIPT_PATH"
systemctl daemon-reload

echo "Writing $SCRIPT_PATH ..."
cat > "$SCRIPT_PATH" <<'SCRIPT_EOF'
#!/usr/bin/env bash

START_OFFSET=299
START_DELAY=30
CHECK_INTERVAL=1
MINER_REGEX="SRBMiner|SRBMiner-MULTI|srbminer"

export DISPLAY=:0

log() {
  echo "$(date '+%F %T') 50xx-offset: $*"
}

running_offset_for() {
  case "$1" in
    *"5090"*)    echo 550 ;;
    *"5080"*)    echo 550 ;;
    *"5070 Ti"*) echo 550 ;;
    *"5070"*)    echo 550 ;;
    *"5060 Ti"*) echo 550 ;;
    *"5060"*)    echo 550 ;;
    *)            echo "" ;;
  esac
}

list_gpus() {
  nvidia-settings -q gpus 2>/dev/null |
    sed -n 's/.*\[gpu:\([0-9][0-9]*\)\] (\(.*\))[[:space:]]*$/\1,\2/p'
}

set_core_offset() {
  local gpu_index="$1"
  local offset_value="$2"

  nvidia-settings -a "[gpu:${gpu_index}]/GPUGraphicsClockOffsetAllPerformanceLevels=${offset_value}" >/dev/null 2>&1 && return 0

  local applied=1
  local pstate

  for pstate in 0 1 2 3 4 5; do
    if nvidia-settings -a "[gpu:${gpu_index}]/GPUGraphicsClockOffset[${pstate}]=${offset_value}" >/dev/null 2>&1; then
      applied=0
    fi
  done

  return "$applied"
}

apply_offsets() {
  local mode="$1"
  local gpu_list
  local idx
  local name
  local offset_value

  gpu_list="$(list_gpus)"
  if [ -z "$gpu_list" ]; then
    log "WARNING: nvidia-settings listed no GPUs."
    return 1
  fi

  while IFS=',' read -r idx name; do
    offset_value="$(running_offset_for "$name")"

    if [ -z "$offset_value" ]; then
      log "GPU ${idx} ${name} skipped"
      continue
    fi

    if [ "$mode" = "startup" ]; then
      offset_value="$START_OFFSET"
    fi

    if set_core_offset "$idx" "$offset_value"; then
      log "GPU ${idx} ${name} -> +${offset_value} success"
    else
      log "GPU ${idx} ${name} -> +${offset_value} failure"
    fi
  done <<< "$gpu_list"
}

apply_start_offsets() {
  log "Applying startup Core Clock Offset +${START_OFFSET} to listed GPUs only"
  apply_offsets startup
}

apply_running_offsets() {
  log "Applying per-model running Core Clock Offsets to listed GPUs only"
  apply_offsets running
}

get_srb_pid() {
  pgrep -fo "$MINER_REGEX" 2>/dev/null || true
}

log "Service started. Waiting for SRBMiner."

while true; do
  miner_pid="$(get_srb_pid)"

  if [ -z "$miner_pid" ]; then
    sleep "$CHECK_INTERVAL"
    continue
  fi

  log "SRBMiner detected as PID ${miner_pid}. Leaving the current offset untouched."
  log "Waiting ${START_DELAY}s before applying per-model running offsets."

  elapsed=0
  while [ "$elapsed" -lt "$START_DELAY" ]; do
    sleep "$CHECK_INTERVAL"
    current_pid="$(get_srb_pid)"

    if [ "$current_pid" != "$miner_pid" ]; then
      log "SRBMiner PID changed or stopped during warmup (${miner_pid} -> ${current_pid:-none})."
      log "Applying +${START_OFFSET} to listed GPUs and restarting the timer."
      apply_start_offsets
      miner_pid=""
      break
    fi

    elapsed=$((elapsed + CHECK_INTERVAL))
  done

  if [ -z "$miner_pid" ]; then
    continue
  fi

  current_pid="$(get_srb_pid)"
  if [ "$current_pid" != "$miner_pid" ]; then
    log "SRBMiner PID changed before the delayed switch (${miner_pid} -> ${current_pid:-none})."
    log "Applying +${START_OFFSET} to listed GPUs and restarting the timer."
    apply_start_offsets
    continue
  fi

  log "PID ${miner_pid} remained stable. Applying per-model running offsets."
  apply_running_offsets

  while true; do
    sleep "$CHECK_INTERVAL"
    current_pid="$(get_srb_pid)"

    if [ "$current_pid" != "$miner_pid" ]; then
      log "SRBMiner PID changed or stopped (${miner_pid} -> ${current_pid:-none})."
      log "Applying +${START_OFFSET} to listed GPUs."
      apply_start_offsets
      break
    fi
  done
done
SCRIPT_EOF

chmod +x "$SCRIPT_PATH"
chmod 755 "$SCRIPT_PATH"

echo "Writing $SERVICE_PATH ..."
cat > "$SERVICE_PATH" <<'SERVICE_EOF'
[Unit]
Description=SRBMiner RTX 50xx offset switch
After=multi-user.target

[Service]
Type=simple
ExecStart=/bin/bash /hive-config/srb50xx-offset.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICE_EOF

echo "Enabling and starting service..."
systemctl daemon-reload
systemctl enable --now srb50xx-offset.service

echo
echo "=== service status ==="
systemctl status srb50xx-offset.service --no-pager || true

echo
echo "=== recent logs ==="
journalctl -u srb50xx-offset.service -n 80 --no-pager || true

echo
echo "=== installed files ==="
ls -l "$SCRIPT_PATH" "$SERVICE_PATH"
cat -n "$SERVICE_PATH"
