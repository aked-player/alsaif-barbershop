#!/usr/bin/env bash
# Configure this HiveOS host as a persistent Tailscale exit node.
#
# Run as root from the main HiveOS host (not from a miner/container shell):
#   chmod 700 /hive-config/install-tailscale-exit-node.sh
#   /bin/bash /hive-config/install-tailscale-exit-node.sh

set -Eeuo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

readonly SYSCTL_FILE="/etc/sysctl.d/99-tailscale.conf"
readonly TUN_MODULE_FILE="/etc/modules-load.d/tailscale-tun.conf"

on_error() {
  local exit_code=$?
  echo "ERROR: setup stopped at line ${BASH_LINENO[0]} (exit ${exit_code})." >&2
  echo "Fix the reported problem, then run this script again; it is safe to re-run." >&2
  exit "${exit_code}"
}
trap on_error ERR

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_root() {
  [[ ${EUID} -eq 0 ]] || die "Run this script as root."
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

write_persistent_network_settings() {
  echo "Writing persistent TUN and IP-forwarding settings..."
  install -d -m 0755 /etc/modules-load.d /etc/sysctl.d
  printf 'tun\n' >"${TUN_MODULE_FILE}"
  printf '%s\n' \
    '# Required for this host to act as a Tailscale exit node.' \
    'net.ipv4.ip_forward = 1' \
    'net.ipv6.conf.all.forwarding = 1' \
    >"${SYSCTL_FILE}"

  modprobe tun
  [[ -c /dev/net/tun ]] || die "/dev/net/tun is unavailable after loading the tun module."
  sysctl -p "${SYSCTL_FILE}"
}

install_tailscale() {
  if command -v tailscale >/dev/null 2>&1; then
    echo "Tailscale is already installed."
    tailscale version
    return
  fi

  require_command curl
  echo "Downloading the official Tailscale installer..."
  local installer
  installer="$(mktemp /tmp/tailscale-install.XXXXXX)"
  trap 'rm -f "${installer}"' RETURN
  curl --fail --show-error --silent --location \
    --proto '=https' --tlsv1.2 \
    https://tailscale.com/install.sh \
    --output "${installer}"
  /bin/sh "${installer}"
  rm -f "${installer}"
  trap - RETURN

  require_command tailscale
}

enable_tailscaled() {
  require_command systemctl
  echo "Enabling and starting tailscaled..."
  systemctl enable --now tailscaled.service
  systemctl is-active --quiet tailscaled.service || die "tailscaled did not become active. Check: journalctl -u tailscaled.service --no-pager"
}

advertise_exit_node() {
  echo "Configuring this host as a Tailscale exit node..."

  # 'set' preserves all existing Tailscale preferences. On a new node, 'up'
  # both starts the login flow and records the exit-node advertisement.
  if tailscale ip -4 >/dev/null 2>&1; then
    tailscale set --advertise-exit-node
  else
    echo
    echo "Tailscale login is required. Open the URL printed below in a browser."
    tailscale up --advertise-exit-node
    if ! tailscale ip -4 >/dev/null 2>&1; then
      echo
      echo "Authentication is still pending. Complete the browser login, then run this script again to verify the setup."
      exit 0
    fi
  fi
}

verify_configuration() {
  local ipv4_forward ipv6_forward
  ipv4_forward="$(sysctl -n net.ipv4.ip_forward)"
  ipv6_forward="$(sysctl -n net.ipv6.conf.all.forwarding)"

  [[ "${ipv4_forward}" == "1" ]] || die "IPv4 forwarding is not enabled."
  [[ "${ipv6_forward}" == "1" ]] || die "IPv6 forwarding is not enabled."

  echo
  echo "Setup complete."
  echo "Tailscale status:"
  tailscale status || true
  echo
  echo "Next required step: in the Tailscale admin console, open Machines,"
  echo "find this HiveOS rig, choose Edit route settings, enable 'Use as exit node', and save."
  echo "Then select this rig as the exit node on the Sweden client and verify its public IP."
  echo
  echo "Persistence installed:"
  echo "  ${TUN_MODULE_FILE}        (loads tun at boot)"
  echo "  ${SYSCTL_FILE}            (enables IPv4/IPv6 forwarding at boot)"
  echo "  tailscaled.service         (enabled at boot)"
}

main() {
  require_root
  [[ "$(uname -s)" == "Linux" ]] || die "This script must run on Linux."
  require_command install
  require_command modprobe
  require_command sysctl

  write_persistent_network_settings
  install_tailscale
  enable_tailscaled
  advertise_exit_node
  verify_configuration
}

main "$@"
