Azurite is a custom image of bazzite using the Niri/DankMaterialShell combo.

Note that it does not contain any preconfigured dotfiles beyond those that are set up by the base bazzite image. That in turn means that neither niri nor dms are configured by default. To set up a good set of defaults, run the dms setup script. Everything is preinstalled, so it should be work without any additional installs (which would fail since we're on an atomic linux).

```shell
curl -fsSL https://install.danklinux.com | sh
```

To enable dms's search functionality, run the following command (but not as root):

```shell
systemctl --user enable --now dsearch
```
