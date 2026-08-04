Azurite is a custom image of bazzite using the Niri/DankMaterialShell combo. There is **NO NVIDIA BULD** yet.

Note that it does not contain any preconfigured dotfiles beyond those that are set up by the base bazzite image. That in turn means that neither niri nor dms are configured by default. To set up a good set of defaults, run the dms setup script as shown below. All the software needed by the base config is preinstalled, so it should be work without any additional installs (which would fail since we're on an atomic linux).

```shell
curl -fsSL https://install.danklinux.com | sh
```

You also **MUST** run the following command to get systemd to init everything properly:

```shell
systemctl --user add-wants niri.service dms
```

To enable dms's search functionality, run the following command (but not as root):

```shell
systemctl --user enable --now dsearch
```

Now log out. Then check the login manager's popup menu to switch to Niri/DMS if it isn't already selected and then relogin.

Note that alacritty, kitty, AND ghostty are all preinstalled. The basic dms config file uses alacritty, but feel free to change as needed.

## Building locally

```shell
./build_local.sh --preflight        # check your environment, build nothing
./build_local.sh --container-only   # just the container image
./build_local.sh                    # container image + Anaconda installer ISO
./build_local.sh --type qcow2       # container image + VM disk
```

`build_local.sh --help` documents the rest. The `just` recipes
(`just build`, `just build-iso`, `just build-qcow2`) still work too; the script
just adds the preflight checks and the cross-arch handling.

Image name, description, tags and the BIB image are configured in
[`azurite.env`](./azurite.env), which the `just` recipes load.

**There is no aarch64 build, and there cannot be one right now:** azurite is
derived from `ghcr.io/ublue-os/bazzite`, which is published for amd64 only. On
Apple Silicon the script builds `linux/amd64` under emulation inside the podman
machine, which works but is slow — tens of minutes for the container image and
hours for an ISO. Give the podman machine >= 8 GiB RAM and ~60 GiB of free disk
before attempting an ISO, or better yet build on an x86_64 Linux host.
