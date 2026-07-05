#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="/hive-config/50xx_offset_299_to_499_when_srb.sh"
SERVICE_PATH="/etc/systemd/system/srb50xx-offset.service"

echo "Cleaning old srb50xx-offset service files..."
systemctl disable --now srb50xx-offset.service 2>/dev/null || true
rm -f "$SERVICE_PATH" /etc/systemd/system/srb50xx-offset.serviceV
systemctl daemon-reload

echo "Writing $SCRIPT_PATH ..."
cat > "$SCRIPT_PATH" <<'SCRIPT_EOF'
#!/usr/bin/env bash

START_OFFSET=299
RUNNING_OFFSET=499
START_DELAY=180
CHECK_INTERVAL=10
MINER_REGEX="SRBMiner|SRBMiner-MULTI|srbminer"

export DISPLAY=:0

log() {
  echo "$(date '+%F %T') 50xx-offset: $*"
}

is_50xx_gpu() {
  echo "$1" | grep -Eqi "RTX 50|GeForce RTX 50|5090|5080|5070|5060"
}

set_core_offset() {
  local gpu_index="$1"
  local offset_value="$2"

  nvidia-settings -a "[gpu:${gpu_index}]/GPUGraphicsClockOffsetAllPerformanceLevels=${offset_value}" >/dev/null 2>&1 && return 0

  for pstate in 0 1 2 3 4 5; do
    nvidia-settings -a "[gpu:${gpu_index}]/GPUGraphicsClockOffset[${pstate}]=${offset_value}" >/dev/null 2>&1 || true
  done
}

apply_offset_to_50xx() {
  local offset_value="$1"

  log "Applying Core Clock Offset +${offset_value} to RTX 50xx only"

  nvidia-smi --query-gpu=index,name --format=csv,noheader | while IFS=',' read -r idx name; do
    idx="$(echo "$idx" | tr -d ' ')"
    name="$(echo "$name" | sed 's/^ *//')"

    if is_50xx_gpu "$name"; then
      log "GPU ${idx} ${name} -> +${offset_value}"
      set_core_offset "$idx" "$offset_value"
    else
      log "GPU ${idx} ${name} skipped"
    fi
  done
}

srb_is_running() {
  pgrep -f "$MINER_REGEX" >/dev/null 2>&1
}

log "Service started. Waiting for SRBMiner."

while true; do
  if srb_is_running; then
    log "SRBMiner detected. Setting RTX 50xx to +${START_OFFSET}."
    apply_offset_to_50xx "$START_OFFSET"

    log "Waiting ${START_DELAY}s before switching to +${RUNNING_OFFSET}."
    sleep "$START_DELAY"

    if srb_is_running; then
      log "Switching RTX 50xx to +${RUNNING_OFFSET}."
      apply_offset_to_50xx "$RUNNING_OFFSET"

      while srb_is_running; do
        sleep "$CHECK_INTERVAL"
      done

      log "SRBMiner stopped. Returning RTX 50xx to +${START_OFFSET}."
      apply_offset_to_50xx "$START_OFFSET"
    fi
  fi

  sleep "$CHECK_INTERVAL"
done
SCRIPT_EOF

chmod +x "$SCRIPT_PATH"

echo "Writing $SERVICE_PATH ..."
cat > "$SERVICE_PATH" <<'SERVICE_EOF'
[Unit]
Description=SRBMiner RTX 50xx offset switch
After=multi-user.target

[Service]
Type=simple
ExecStart=/hive-config/50xx_offset_299_to_499_when_srb.sh
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
