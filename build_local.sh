#!/usr/bin/env bash
#
# build_local.sh -- build the azurite container image, and optionally a
# bootable disk image (installer ISO / qcow2 / raw), on your own machine.
#
# ARCHITECTURE NOTE, PLEASE READ
# -----------------------------------------------------------------------
# azurite is built on ghcr.io/ublue-os/bazzite, and bazzite is published
# for **amd64 only** -- there is no aarch64/arm64 bazzite tag. So an
# aarch64 azurite image or ISO is not possible today, no matter what
# hardware you build on.
#
# On an Apple Silicon Mac (or any arm64 box) this script therefore builds
# linux/amd64 under qemu-user emulation inside the podman machine. That
# works, but it is *slow*: expect tens of minutes for the container image
# and multiple hours for an anaconda-iso, since osbuild/lorax
# (squashfs + xz + dracut) is entirely CPU bound.
#
# bootc-image-builder also only really supports building for the host
# architecture ("--target-arch" is experimental), which is why we run the
# builder container itself as linux/amd64 rather than passing a target
# arch. If you have access to an x86_64 Linux machine, use that instead;
# it will be an order of magnitude faster.
#
# Usage:
#   ./build_local.sh                     # container image + installer ISO
#   ./build_local.sh --container-only    # just the container image
#   ./build_local.sh --type qcow2        # container image + VM disk
#   ./build_local.sh --preflight         # check the environment and exit
#   ./build_local.sh --help
#
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT

IMAGE_NAME="${IMAGE_NAME:-azurite}"
TAG="${DEFAULT_TAG:-latest}"
BIB_IMAGE="${BIB_IMAGE:-quay.io/centos-bootc/bootc-image-builder:latest}"

# bazzite is amd64-only, so this is not configurable by accident.
TARGET_PLATFORM="linux/amd64"
TARGET_UNAME="x86_64"

TYPE="anaconda-iso"
CONFIG=""
CONTAINER_ONLY=0
SKIP_CONTAINER=0
PREFLIGHT_ONLY=0
NO_CACHE=0
ASSUME_YES=0

log() { printf '\n=== %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\n!!! %s\n' "$*" >&2; }
die() {
	printf '\nERROR: %s\n' "$*" >&2
	exit 1
}

usage() {
	# print the header comment block, minus the shebang line
	awk 'NR>1 { if (/^#/) { sub(/^# ?/, ""); print } else { exit } }' "${BASH_SOURCE[0]}"
	cat <<-EOF
		Options:
		  --type TYPE        anaconda-iso (default), iso, qcow2, raw, vmdk, ...
		  --config FILE      build config (default: disk_config/iso.toml for ISO
		                     types, disk_config/disk.toml otherwise)
		  --tag TAG          image tag to build/use (default: ${TAG})
		  --container-only   build the container image, skip the disk image
		  --skip-container   reuse an already-built container image
		  --no-cache         pass --no-cache to podman build
		  --preflight        run environment checks only, then exit
		  -y, --yes          don't prompt before long emulated builds
		  -h, --help         this text

		Environment: IMAGE_NAME, DEFAULT_TAG, BIB_IMAGE
	EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--type)
		TYPE="${2:?--type needs a value}"
		shift 2
		;;
	--config)
		CONFIG="${2:?--config needs a value}"
		shift 2
		;;
	--tag)
		TAG="${2:?--tag needs a value}"
		shift 2
		;;
	--container-only)
		CONTAINER_ONLY=1
		shift
		;;
	--skip-container)
		SKIP_CONTAINER=1
		shift
		;;
	--no-cache)
		NO_CACHE=1
		shift
		;;
	--preflight)
		PREFLIGHT_ONLY=1
		shift
		;;
	-y | --yes)
		ASSUME_YES=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*) die "unknown argument: $1 (try --help)" ;;
	esac
done

if [[ -z "$CONFIG" ]]; then
	case "$TYPE" in
	*iso*) CONFIG="disk_config/iso.toml" ;;
	*) CONFIG="disk_config/disk.toml" ;;
	esac
fi

IMAGE_REF="localhost/${IMAGE_NAME}:${TAG}"

confirm() {
	[[ $ASSUME_YES -eq 1 ]] && return 0
	local reply
	read -r -p "    $1 [y/N] " reply || true
	[[ "$reply" == [yY]* ]]
}

#######################################################################
### Preflight
#######################################################################

EMULATED=0

preflight() {
	log "Preflight"

	command -v podman >/dev/null || die "podman is not installed"
	info "podman: $(podman --version)"

	[[ -f "${REPO_ROOT}/Containerfile" ]] || die "no Containerfile in ${REPO_ROOT}"
	[[ $CONTAINER_ONLY -eq 1 || -f "${REPO_ROOT}/${CONFIG}" ]] ||
		die "config not found: ${REPO_ROOT}/${CONFIG}"

	if [[ "$(uname -s)" == "Darwin" ]]; then
		podman machine list --format '{{.Running}}' 2>/dev/null | grep -q true ||
			die "no podman machine is running -- try: podman machine start"
		local rootful
		rootful="$(podman machine inspect --format '{{.Rootful}}' 2>/dev/null || echo unknown)"
		info "podman machine rootful: ${rootful}"
		if [[ "$rootful" != "true" && $CONTAINER_ONLY -eq 0 ]]; then
			die "bootc-image-builder needs a rootful machine: podman machine set --rootful && podman machine stop && podman machine start"
		fi
		podman machine inspect --format \
			'    machine cpus={{.Resources.CPUs}} memory={{.Resources.Memory}}MiB disk={{.Resources.DiskSize}}GiB' 2>/dev/null || true
		local mem
		mem="$(podman machine inspect --format '{{.Resources.Memory}}' 2>/dev/null || echo 0)"
		if [[ "$mem" -lt 8192 && $CONTAINER_ONLY -eq 0 ]]; then
			warn "podman machine has ${mem}MiB RAM; osbuild wants >= 8192MiB for ISO builds"
			info "podman machine set --memory 12288 (then stop/start the machine)"
		fi
	elif [[ "$(id -u)" -ne 0 && $CONTAINER_ONLY -eq 0 ]]; then
		command -v sudo >/dev/null ||
			die "bootc-image-builder needs root (or a rootful podman machine)"
		info "will use sudo for bootc-image-builder"
	fi

	# container storage headroom: a bazzite-derived ISO needs a lot of scratch
	local alloc used free_gib need_gib=25
	[[ $CONTAINER_ONLY -eq 0 ]] && need_gib=60
	alloc="$(podman info --format '{{.Store.GraphRootAllocated}}' 2>/dev/null || echo 0)"
	used="$(podman info --format '{{.Store.GraphRootUsed}}' 2>/dev/null || echo 0)"
	if [[ "$alloc" -gt 0 ]]; then
		free_gib=$(((alloc - used) / 1073741824))
		info "container storage free: ${free_gib} GiB (want >= ${need_gib} GiB)"
		if [[ "$free_gib" -lt "$need_gib" ]]; then
			warn "low on space for this build; prune images or grow the podman machine disk"
		fi
	fi

	local host_arch
	host_arch="$(uname -m)"
	info "host arch: ${host_arch}"
	if [[ "$host_arch" != "$TARGET_UNAME" ]]; then
		EMULATED=1
		warn "bazzite is amd64-only, so this build must be emulated on ${host_arch}."
		info "checking that linux/amd64 emulation works..."
		local out
		out="$(podman run --rm --platform "$TARGET_PLATFORM" \
			quay.io/fedora/fedora:44 uname -m 2>/dev/null | tail -1)" ||
			die "could not run a linux/amd64 container -- install qemu-user-static/binfmt support"
		[[ "$out" == "$TARGET_UNAME" ]] ||
			die "linux/amd64 emulation is not working (got '${out}')"
		info "emulation OK (linux/amd64 reports ${out})"
	fi

	log "Plan"
	info "container image : ${IMAGE_REF} (${TARGET_PLATFORM})"
	if [[ $CONTAINER_ONLY -eq 1 ]]; then
		info "disk image      : skipped (--container-only)"
	else
		info "disk image      : ${TYPE} using ${CONFIG}"
		info "builder         : ${BIB_IMAGE}"
		info "output          : ${REPO_ROOT}/output"
	fi

	if [[ $EMULATED -eq 1 && $PREFLIGHT_ONLY -eq 0 ]]; then
		local est="30-90 minutes"
		[[ $CONTAINER_ONLY -eq 0 ]] && est="several hours, and 40+ GiB of scratch space"
		warn "Emulated build: expect ~${est}. Consider an x86_64 Linux host instead."
		confirm "Continue anyway?" || die "aborted"
	fi
}

#######################################################################
### Container image
#######################################################################

build_container() {
	log "Building ${IMAGE_REF}"

	local args=(build --platform "$TARGET_PLATFORM" --pull=newer --tag "$IMAGE_REF")
	[[ $NO_CACHE -eq 1 ]] && args+=(--no-cache)
	if [[ -z "$(git -C "$REPO_ROOT" status -s 2>/dev/null || true)" ]]; then
		args+=(--build-arg "SHA_HEAD_SHORT=$(git -C "$REPO_ROOT" rev-parse --short HEAD)")
	fi
	args+=("$REPO_ROOT")

	(
		set -x
		podman "${args[@]}"
	)
}

#######################################################################
### Disk image via bootc-image-builder
#######################################################################

# On Linux the builder must run as root, and root's container storage is a
# different store than the user's, so hand the image over.
load_image_rootful() {
	[[ "$(uname -s)" == "Darwin" ]] && return 0 # machine is already rootful
	[[ "$(id -u)" -eq 0 ]] && return 0

	local user_id root_id
	user_id="$(podman image inspect --format '{{.Id}}' "$IMAGE_REF")"
	root_id="$(sudo podman image inspect --format '{{.Id}}' "$IMAGE_REF" 2>/dev/null || true)"
	[[ "$user_id" == "$root_id" ]] && return 0

	log "Copying ${IMAGE_REF} into rootful podman storage"
	podman image scp "$(id -u)@localhost::${IMAGE_REF}" "root@localhost::${IMAGE_REF}"
}

build_disk() {
	load_image_rootful

	local sudo=()
	if [[ "$(uname -s)" != "Darwin" && "$(id -u)" -ne 0 ]]; then
		sudo=(sudo)
	fi

	local outdir="${REPO_ROOT}/output"
	mkdir -p "$outdir"

	log "Building ${TYPE} with ${BIB_IMAGE}"
	info "this is the slow part; the log lines come from osbuild"

	# -it only when we actually have a terminal, so the script also works
	# under nohup/CI.
	local tty=()
	[[ -t 0 && -t 1 ]] && tty=(-it)

	# extra flags for bootc-image-builder, e.g. BIB_EXTRA_ARGS="--use-librepo=True"
	local extra=()
	if [[ -n "${BIB_EXTRA_ARGS:-}" ]]; then
		read -r -a extra <<<"$BIB_EXTRA_ARGS"
	fi

	(
		set -x
		${sudo[@]+"${sudo[@]}"} podman run \
			--rm ${tty[@]+"${tty[@]}"} \
			--platform "$TARGET_PLATFORM" \
			--privileged \
			--pull=newer \
			--net=host \
			--security-opt label=type:unconfined_t \
			-v "${REPO_ROOT}/${CONFIG}:/config.toml:ro" \
			-v "${outdir}:/output" \
			-v /var/lib/containers/storage:/var/lib/containers/storage \
			"$BIB_IMAGE" \
			--type "$TYPE" \
			--rootfs=btrfs \
			--progress=verbose \
			--chown "$(id -u):$(id -g)" \
			${extra[@]+"${extra[@]}"} \
			"$IMAGE_REF"
	)

	log "Done"
	find "$outdir" -type f \( -name '*.iso' -o -name 'disk.*' \) -exec ls -lh {} \; || true
}

#######################################################################

preflight
[[ $PREFLIGHT_ONLY -eq 1 ]] && exit 0
[[ $SKIP_CONTAINER -eq 1 ]] || build_container
[[ $CONTAINER_ONLY -eq 1 ]] && exit 0
build_disk
