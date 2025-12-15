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
