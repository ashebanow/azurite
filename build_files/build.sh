#!/bin/bash

set -ouex pipefail

log() {
	echo "=== $* ==="
}

COPR_REPOS=(
    avengemedia/dms
	pgdev/ghostty
	ulysg/xwayland-satellite
	yalter/niri
)
for repo in "${COPR_REPOS[@]}"; do
	# Try to enable the repo, but don't fail the build if it doesn't support this Fedora version
	if ! dnf5 -y copr enable "$repo" 2>&1; then
		log "Warning: Failed to enable COPR repo $repo (may not support Fedora $RELEASE)"
	fi
done

NIRI_PKGS=(
    dms
	niri
	cava
	cliphist
	dgop
	dsearch
	gnome-keyring
	matugen
	wl-clipboard
	xdg-desktop-portal-gtk
	xwayland-satellite
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

	thunar
	thunar-volman
	thunar-archive-plugin
)

# we do all package installs in one rpm-ostree command
# so that we create minimal layers in the final image
log "Installing packages using dnf5..."
dnf5 install --setopt=install_weak_deps=False -y \
	"${FONTS[@]}" \
	"${NIRI_PKGS[@]}" \
	"${ADDITIONAL_SYSTEM_APPS[@]}"

#######################################################################
### Disable repositeories so they aren't cluttering up the final image

log "Disable Copr repos to get rid of clutter..."
for repo in "${COPR_REPOS[@]}"; do
	dnf5 -y copr disable "$repo"
done
