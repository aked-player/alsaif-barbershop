#!/usr/bin/env bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

SCRIPT_PATH="/hive-config/onezero50xx-offset.sh"
SERVICE_PATH="/etc/systemd/system/onezero50xx-offset.service"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: this installer must be run as root." >&2
  exit 1
fi

if [ "$#" -ne 1 ]; then
  echo "Usage: bash install-onezero50xx-offset.sh OFFSET" >&2
  echo "Example: curl -fsSL RAW_URL | bash -s -- 599" >&2
  exit 2
fi

RUNNING_OFFSET="$1"
case "$RUNNING_OFFSET" in
  ''|*[!0-9]*)
    echo "ERROR: OFFSET must be a non-negative integer (for example 550, 599, or 699)." >&2
    exit 2
    ;;
esac

for dependency in systemctl nvidia-settings pgrep sed sleep; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    echo "ERROR: $dependency was not found. Run this in the main HiveOS root shell." >&2
    exit 127
  fi
done

echo "Stopping the previous OneZeroMiner offset service, if installed..."
if [ -e "$SERVICE_PATH" ]; then
  systemctl disable --now onezero50xx-offset.service
fi

echo "Writing $SCRIPT_PATH ..."
cat > "$SCRIPT_PATH" <<'SCRIPT_EOF'
#!/usr/bin/env bash
set -u

RUNNING_OFFSET="${1:?Missing running core offset}"
STOP_OFFSET=0
CHECK_INTERVAL=1

export DISPLAY=:0

log() {
  echo "$(date '+%F %T') onezero50xx-offset: $*"
}

is_supported_gpu() {
  case "$1" in
    *"5090"*)    return 0 ;;
    *"5080"*)    return 0 ;;
    *"5070 Ti"*) return 0 ;;
    *"5070"*)    return 0 ;;
    *"5060 Ti"*) return 0 ;;
    *"5060"*)    return 0 ;;
    *)            return 1 ;;
  esac
}

list_gpus() {
  nvidia-settings -q gpus 2>/dev/null |
    sed -n 's/.*\[gpu:\([0-9][0-9]*\)\] (\(.*\))[[:space:]]*$/\1,\2/p'
}

set_and_check_offset() {
  local attribute="$1"
  local offset_value="$2"
  local actual_value

  nvidia-settings -a "${attribute}=${offset_value}" >/dev/null 2>&1 || return 1
  actual_value="$(nvidia-settings -t -q "$attribute" 2>/dev/null)" || return 1
  [ "$actual_value" = "$offset_value" ]
}

set_core_offset() {
  local gpu_index="$1"
  local offset_value="$2"
  local applied=1
  local pstate

  if set_and_check_offset "[gpu:${gpu_index}]/GPUGraphicsClockOffsetAllPerformanceLevels" "$offset_value"; then
    return 0
  fi

  for pstate in 0 1 2 3 4 5; do
    if set_and_check_offset "[gpu:${gpu_index}]/GPUGraphicsClockOffset[${pstate}]" "$offset_value"; then
      applied=0
    fi
  done

  return "$applied"
}

apply_offset() {
  local offset_value="$1"
  local gpu_list
  local idx
  local name
  local failed=0

  gpu_list="$(list_gpus)"
  if [ -z "$gpu_list" ]; then
    log "WARNING: nvidia-settings listed no GPUs."
    return 1
  fi

  while IFS=',' read -r idx name; do
    if ! is_supported_gpu "$name"; then
      log "GPU ${idx} ${name} skipped"
      continue
    fi

    if set_core_offset "$idx" "$offset_value"; then
      log "GPU ${idx} ${name} -> +${offset_value} success (offset read back)"
    else
      log "GPU ${idx} ${name} -> +${offset_value} failure (could not confirm offset)"
      failed=1
    fi
  done <<< "$gpu_list"

  return "$failed"
}

get_onezero_pid() {
  local pid
  local status

  if pid="$(pgrep -ixo onezerominer)"; then
    echo "$pid"
  else
    status=$?
    if [ "$status" -ne 1 ]; then
      return "$status"
    fi
  fi
}

previous_pid=""
initialized=0
log "Service started. Running offset +${RUNNING_OFFSET}; stopped offset ${STOP_OFFSET}; no warmup delay."

while true; do
  if ! current_pid="$(get_onezero_pid)"; then
    log "WARNING: could not determine OneZeroMiner PID; leaving offsets untouched."
    sleep "$CHECK_INTERVAL"
    continue
  fi

  if [ "$initialized" -eq 0 ] || [ "$current_pid" != "$previous_pid" ]; then
    if [ -n "$previous_pid" ]; then
      log "OneZeroMiner stopped or restarted (${previous_pid} -> ${current_pid:-none}). Resetting listed GPUs to ${STOP_OFFSET}."
      apply_offset "$STOP_OFFSET" || log "WARNING: reset was not confirmed for every listed GPU."
    fi

    if [ -n "$current_pid" ]; then
      log "OneZeroMiner detected as PID ${current_pid}. Applying +${RUNNING_OFFSET} to listed GPUs without a warmup delay."
      apply_offset "$RUNNING_OFFSET" || log "WARNING: running offset was not confirmed for every listed GPU."
    elif [ "$initialized" -eq 0 ]; then
      log "OneZeroMiner is stopped. Resetting listed GPUs to ${STOP_OFFSET}."
      apply_offset "$STOP_OFFSET" || log "WARNING: reset was not confirmed for every listed GPU."
    fi

    previous_pid="$current_pid"
    initialized=1
  fi

  sleep "$CHECK_INTERVAL"
done
SCRIPT_EOF

chmod 755 "$SCRIPT_PATH"

echo "Writing $SERVICE_PATH ..."
cat > "$SERVICE_PATH" <<SERVICE_EOF
[Unit]
Description=OneZeroMiner RTX 50xx core offset switch
After=multi-user.target

[Service]
Type=simple
ExecStart=/bin/bash /hive-config/onezero50xx-offset.sh ${RUNNING_OFFSET}
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICE_EOF

echo "Enabling and starting the OneZeroMiner offset service..."
systemctl daemon-reload
systemctl enable --now onezero50xx-offset.service

echo
echo "=== service status ==="
systemctl status onezero50xx-offset.service --no-pager || true

echo
echo "=== recent logs ==="
journalctl -u onezero50xx-offset.service -n 80 --no-pager || true
