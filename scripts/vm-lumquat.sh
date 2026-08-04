#!/usr/bin/env bash
# vm-lumquat.sh — run the azurite VM on lumquat (KVM-accelerated, native
# x86_64) and expose its noVNC console here over Tailscale.
#
# lumquat is the native build/test host (see build_local.sh notes): it has
# /dev/kvm, so qemu runs near-native speed there instead of TCG-emulating
# x86_64 on an arm64 Mac. qemux/qemu is headless — the noVNC web UI *is*
# the display — so it's trivial to reach over SSH.
#
# What this does:
#   1. starts `just run-vm-<type>` on lumquat, detached (log: /tmp/azurite-vm.log)
#   2. SSH-tunnels the noVNC port (127.0.0.1:8006) to this machine
#   3. opens the browser at http://localhost:8006
#
# The tunnel is the only thing this script keeps open; the VM keeps running
# on lumquat after you Ctrl-C (stop it with --stop).
#
# Usage:
#   ./vm-lumquat.sh [iso|qcow2|raw]   # default: iso
#   ./vm-lumquat.sh --stop            # stop the VM on lumquat
#
# Env:
#   LUMQUAT_HOST  ssh target (default: podman@lumquat; e.g. podman@100.90.247.10
#                to use the raw Tailscale IP directly)
#   LOCAL_PORT    local port for the tunnel (default: 8006)

set -euo pipefail

HOST="${LUMQUAT_HOST:-podman@lumquat}"
TYPE="${1:-iso}"
LOCAL_PORT="${LOCAL_PORT:-8006}"

ssh_lumquat() {
	ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" "$@"
}

if [[ "${1:-}" == "--stop" ]]; then
	ids="$(ssh_lumquat 'sudo podman ps -q --filter ancestor=docker.io/qemux/qemu 2>/dev/null')"
	if [[ -n "$ids" ]]; then
		echo "Stopping VM container(s) on ${HOST}: $ids"
		ssh_lumquat 'for c in $(sudo podman ps -q --filter ancestor=docker.io/qemux/qemu); do sudo podman rm -f "$c"; done'
	else
		echo "No VM running on ${HOST}."
	fi
	exit 0
fi

echo "Checking for a running VM on ${HOST}..."
if ssh_lumquat 'podman ps -q --filter ancestor=docker.io/qemux/qemu 2>/dev/null | grep -q .'; then
	echo "VM already running on ${HOST} — skipping start, just tunneling."
else
	echo "Starting 'just run-vm-${TYPE}' on ${HOST} (detached)..."
	ssh_lumquat "cd ~/azurite && nohup just run-vm-${TYPE} > /tmp/azurite-vm.log 2>&1 & echo started"
fi

echo "Tunneling noVNC → http://localhost:${LOCAL_PORT}  (Ctrl-C closes the tunnel; VM keeps running)"
ssh -o BatchMode=yes -o ConnectTimeout=10 -N -L "${LOCAL_PORT}:127.0.0.1:8006" "$HOST" &
TUNNEL_PID=$!
trap 'kill "$TUNNEL_PID" 2>/dev/null || true' EXIT

open "http://localhost:${LOCAL_PORT}" 2>/dev/null || true

wait "$TUNNEL_PID"
