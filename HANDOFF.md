# HANDOFF — azurite status & next steps

Date: 2026-08-04. Everything below is on the `merge-upstream` branch (pushed to
`origin/merge-upstream`). **`main` has NOT been force-pushed** (deliberately
parked — see "Pending decisions").

## The big picture (what got done)

- **Upstream merge**: the repo was a template copy of `ublue-os/image-template`
  (no shared history). History was rewritten so azurite sits on the template's
  real history (grafted at upstream `c25c32b`, the exact snapshot azurite was
  forked from), then `upstream/main` was merged in. Future merges are now
  normal.
- **Native build host**: Mac-native builds are dead (BIB cannot build cross-arch
  ISO — `cannot build iso for different target arches yet`; emulated BIB dies
  on crun; osbuild's lock bug breaks cross-arch qcow2 in this VM). **lumquat**
  (x86_64 NixOS box, `podman@lumquat`, 32 cores, passwordless sudo, KVM) is the
  build/test host. Repo is synced there at `~/azurite`.
- **ISO → VM install proven end-to-end**: image built natively on lumquat →
  anaconda-ISO (5.8G) → installed in a qemu VM → logged in.
- **Image is on GHCR**: `ghcr.io/ashebanow/azurite:latest` (pushed from lumquat).

## Branch contents (`merge-upstream`, 5 commits on top of the merge)

| Commit | What |
|---|---|
| `fix: re-enable dms setup...` | ships `/etc/dms/cli-policy.json` override — dms 1.5+ blocks `dms setup` on immutable systems; azurite re-enables it (greeter commands stay blocked) |
| `fix: rootful image ID comparison...` | unquoted podman `--format` template in `_rootful_load_image` (the `'{{.ID}}'` quoting bug) |
| `fix: make _run-vm recipe work on macOS...` | `_run-vm` portability: `open` vs `xdg-open`, `lsof` vs `ss`, conditional `/dev/kvm` |
| `fix: make BIB ISO depsolve work despite file:// gpg keys` | **essential**: bazzite's repo files use `file://` gpgkeys that break BIB depsolve everywhere (osbuild/bootc-image-builder#1188); build.sh disables gpgcheck on those repos (matches otonm/bazzite-custom#16) |
| `feat: add vm-lumquat.sh...` | helper: run the VM on lumquat (KVM) + SSH-tunnel noVNC to the Mac over Tailscale |

All three `fix:` commits are good candidates for PRs back to
`ublue-os/image-template` (they fix real bugs, platform-independent).

## Current issue: niri login hangs in the VM (UNRESOLVED)

**Symptom**: after bootc-upgraded reboot, logging into the **niri** session at
SDDM appears to hang — SDDM accepts the password (input fields clear) but the
screen stays frozen on SDDM's last frame.

**Diagnosed so far** (via qemu monitor + mounting the guest disk from lumquat):

- Guest itself is healthy (text console works; qemu-level input works; systemd,
  logind, dms/quickshell all start).
- The failure is **no usable DRM device for niri**:
  - `niri::backend::tty: error doing early import: Error::DeviceMissing`
  - later: `adding device: "/dev/dri/card1" ... error adding device: Failed to
    open device: Invalid argument (os error 22)` → `pausing session`
- **virtio-gpu is flaky in this VM**: initialized cleanly on 1 of 3 boots
  (`[drm] Initialized virtio_gpu ... on minor 1` present only on the first
  boot). On failing boots there are NO virtio-gpu kernel lines at all.
  Identical kernel (7.0.9-ogc3.2.fc44) across boots — not a kernel/upgrade
  regression. SDDM itself renders fine on the latest boot, so the display
  path partially works; niri's device open is what fails.
- KDE session also failed on the same boot (`plasmalogin ... crashed exit 1`),
  so it's guest-wide, not niri-specific.
- Missing data point: the **latest** boot's niri journal lines (the backup
  predates the last reboot — see backups below).

**Plan for next session**:

1. **Restore the VM from backup** (see below) or just boot the container again
   (the container's `--rm` disk is gone after shutdown — use the backup).
2. Try a **guest reboot** first (GPU probe is a coin flip; it worked on boot #1).
3. If niri still fails: recreate the VM container with **GPU=N** in qemux/qemu
   (a different, more VM-stable DRM driver) **and** fix the ephemeral-disk
   landmine by mounting a **persistent volume** at `/storage` (see "Landmine").
4. Get the fresh journal first: mount the restored disk (steps below), or ask
   the user to paste `journalctl -b | grep -iE 'niri|sddm|drm|virtio'`.

## VM backups on lumquat (critical)

- `/home/podman/data.img` — 64G raw btrfs disk of the installed VM
  (pre-last-reboot state; contains dms setup + services).
- `/home/podman/data.img.new` — refreshed copy (captures the last boot's
  journal) taken just before shutdown.
- The **running container's** `/storage/data.img` is deleted when the container
  stops (`--rm`, no volume) — the backups are the recovery path.

To read the disk (as `podman@lumquat`):

```bash
sudo modprobe btrfs                       # kernel lacks btrfs until loaded
sudo losetup -fP /home/podman/data.img    # → /dev/loop0 (+p1 EFI, p2 boot, p3 root)
sudo mkdir -p /mnt/vm /mnt/vmroot
sudo mount -o ro /dev/loop0p3 /mnt/vm                 # top-level (btrfs)
sudo nix-shell -p btrfs-progs --run "btrfs subvolume list /mnt/vm"
sudo mount -o ro,subvolid=257 /dev/loop0p3 /mnt/vmroot      # subvol "root"
sudo mount -o ro,subvolid=256 /dev/loop0p3 /mnt/vmroot/home # subvol "home"
# journal: /mnt/vmroot/ostree/deploy/default/var/log/journal/<machine-id>/
sudo journalctl --directory=<that dir> --no-pager -b
```

Guest username: `ashebanow` (hostname `testie`). Root has no password.

## Landmine: VM disk is ephemeral

`_run-vm` starts the qemu container with `--rm` and no volume, so
`/storage/data.img` lives in the container's writable layer. **Any container
stop destroys the installed VM.** Fix (worth doing): mount a persistent volume
at `/storage` when starting the VM (e.g. `-v /home/podman/azurite-vm:/storage`),
or wire it into `vm-lumquat.sh`. The backups above are the safety net until then.

## Tooling notes

- `scripts/vm-lumquat.sh` — starts `just run-vm-iso` on lumquat (detached),
  SSH-tunnels noVNC (`localhost:8006`) over Tailscale, opens the browser.
  `--stop` shuts the VM down. `LUMQUAT_HOST`/`LOCAL_PORT` env overrides.
  (Just fixed: `--stop` now queries rootless podman — it previously checked
  rootful and couldn't see the VM.)
- QEMU monitor access from lumquat (works even when noVNC input is stuck):
  `podman exec friendly_lalande python3 /tmp/hmp.py` (screendump + status);
  monitor socket at `/run/shm/monitor.sock` inside the container.
  `sendkey ctrl-alt-delete` = soft reboot; `sendkey ctrl-alt-f2` = VT switch.
- noVNC does **not** reliably forward Ctrl+Alt combos — use the monitor
  `sendkey` path or a physical console.

## Pending decisions / follow-ups

- [ ] **Force-push `main`** to `merge-upstream` tip
      (`git push --force-with-lease origin merge-upstream:main`) — needs
      explicit user OK. This makes `main` carry the merge + fixes and lights up
      CI (build-disk.yml on x86_64 runners).
- [ ] README cleanup: drop the `curl -fsSL https://install.danklinux.com | sh`
      step (dms ships in the image); document the dms policy override.
- [ ] PR candidates upstream (`ublue-os/image-template`): gpgkey depsolve fix,
      `_run-vm` portability, `_rootful_load_image` format fix, dms policy
      override pattern.
- [ ] Fix VM disk ephemerality (persistent volume) — see Landmine.
- [ ] Re-test niri login after GPU fix; if resolved, run the full azurite
      experience (niri + DMS + dsearch).
- [ ] Consider `bootc switch`/`bootc upgrade` as the guest's update path
      (kickstart already points at `ghcr.io/ashebanow/azurite:latest`).
