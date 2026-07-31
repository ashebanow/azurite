#!/bin/bash

set -ouex pipefail

RELEASE="$(rpm -E %fedora)"

log() {
	echo "=== $* ==="
}

#######################################################################
### Package sources
###
### Preference order: official Fedora repos > upstream-blessed COPR >
### third-party COPR. Several things we used to pull from COPRs are now
### shipped by Fedora proper (Fedora $RELEASE):
###
###   niri                 -> fedora updates  (was yalter/niri)
###   xwayland-satellite   -> fedora updates  (was ulysg/xwayland-satellite)
###   cava, wl-clipboard   -> fedora release
###   matugen, cliphist    -> fedora release (danklinux carries newer builds)
###   dgop                 -> fedora release (danklinux carries newer builds)
###
### Still not in Fedora, so a COPR is required:
###
###   ghostty              -> scottames/ghostty, the COPR recommended by
###                           ghostty.org (the old pgdev/ghostty project has
###                           been deleted, which is what broke CI).
###   dms + friends        -> avengemedia/dms plus avengemedia/danklinux,
###                           which upstream now *requires* for the DMS
###                           dependencies (quickshell-git, danksearch,
###                           dankcalendar, material-symbols-fonts, ...).
###                           Note dsearch was renamed to danksearch.
#######################################################################

log "Enable Copr repos..."
COPR_REPOS=(
	avengemedia/danklinux # DMS dependencies (quickshell-git, danksearch, ...)
	avengemedia/dms       # DankMaterialShell itself
	scottames/ghostty     # ghostty.org's recommended COPR
)
for repo in "${COPR_REPOS[@]}"; do
	# Try to enable the repo, but don't fail the build if it doesn't support this Fedora version
	if ! dnf5 -y copr enable "$repo" 2>&1; then
		log "Warning: Failed to enable COPR repo $repo (may not support Fedora $RELEASE)"
	fi
done

NIRI_PKGS=(
	niri
	xwayland-satellite

	# DankMaterialShell and its dependencies. dms pulls in dms-cli;
	# the rest are Recommends: that we must list explicitly because we
	# build with install_weak_deps=False.
	dms
	quickshell-git
	danksearch
	dgop
	matugen
	qt6-qtmultimedia

	cava
	cliphist
	gnome-keyring
	wl-clipboard
	xdg-desktop-portal-gtk
)

# Note that many font packages are preinstalled in the
# bazzite image, along with the SymbolsNerdFont which doesn't
# have an associated fedora package:
#
#   fira-code-fonts
#   google-droid-sans-fonts
#   google-noto-emoji-fonts
#   google-noto-sans-cjk-fonts
#   google-noto-color-emoji-fonts
#   jetbrains-mono-fonts
#
# Because the nerd font symbols are mapped correctly, we can get
# nerd font characters anywhere.
FONTS=(
	adobe-source-code-pro-fonts
	fontawesome-fonts-all
	material-symbols-fonts # DMS icons (avengemedia/danklinux)
)

# chrome etc are installed as flatpaks. We generally prefer that
# for most things with GUIs, and homebrew for CLI apps. This list is
# only special GUI apps that need to be installed at the system level.
ADDITIONAL_SYSTEM_APPS=(
	# pick your poison
	alacritty
	ghostty
	kitty
	kitty-terminfo

	Thunar # yes, Fedora really capitalizes this one
	thunar-volman
	thunar-archive-plugin
)

# we do all package installs in one rpm-ostree command
# so that we create minimal layers in the final image
log "Installing packages using dnf5..."
dnf5 install --setopt=install_weak_deps=False --skip-unavailable -y \
	"${FONTS[@]}" \
	"${NIRI_PKGS[@]}" \
	"${ADDITIONAL_SYSTEM_APPS[@]}"

#######################################################################
### Sanity check: --skip-unavailable means a renamed or dropped package
### silently disappears instead of failing the build, so assert that the
### things this image exists for actually landed.

log "Verifying critical packages..."
CRITICAL_PKGS=(
	dms
	ghostty
	niri
	quickshell-git
	xwayland-satellite
)
MISSING_PKGS=()
for pkg in "${CRITICAL_PKGS[@]}"; do
	rpm -q "$pkg" >/dev/null 2>&1 || MISSING_PKGS+=("$pkg")
done
if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
	log "ERROR: critical packages missing from image: ${MISSING_PKGS[*]}"
	exit 1
fi

#######################################################################
### Disable repositeories so they aren't cluttering up the final image

log "Disable Copr repos to get rid of clutter..."
for repo in "${COPR_REPOS[@]}"; do
	# a repo that failed to enable above can't be disabled, so don't
	# let that take down the whole build
	if ! dnf5 -y copr disable "$repo" 2>&1; then
		log "Warning: Failed to disable COPR repo $repo"
	fi
done
