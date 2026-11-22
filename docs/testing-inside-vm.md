# testing inside vm

## 1. Install it
brew install --cask multipass

## 2. Create the VM (run on Mac, from the repo root)
```sh
multipass launch 24.04 --name brig --cpus 1 --memory 1G --disk 8G \
  --mount ~/Playground/cufarr:/home/ubuntu/cufarr \
  --cloud-init docs/brig-vm.yaml
```
- Mounts the repo: edit on the Mac, the VM sees changes right away. Mounts persist across restarts.
- [brig-vm.yaml](brig-vm.yaml) runs on first boot: installs Zig 0.17.0 (`zig` and `sudo zig` both work), `strace`, a 2G swap file, and creates `/var/lib/brig/{images,containers}`.
- Disk grows on demand; 8G is the cap, not what it takes up front (Ubuntu needs ≥3.5G).
- Let it finish (~1–2 min). Don't interrupt or delete it mid-launch; that can hang the daemon.

Check it's ready (inside the VM):
```sh
cloud-init status --wait   # "status: done"
zig version                # 0.17.0
free -h                    # Swap: 2.0G
```
Setup failed? Logs: `sudo cat /var/log/cloud-init-output.log`.

Broken VM? Start over: `multipass delete --purge brig`, then the launch command again.

## Runtime state: `/var/lib/brig`
```
/var/lib/brig/
├── images/          # read-only image tarballs
└── containers/
    └── <id>/rootfs/ # per-container extracted copy
```
Keep it on the VM disk, never on the Mac mount. The mount (sshfs, case-insensitive APFS) drops root ownership, setuid bits and device nodes, and is slow.

VM created before this was added? cloud-init only runs on first boot, so create it once by hand:
```sh
sudo mkdir -p /var/lib/brig/images /var/lib/brig/containers
```

Download an image (inside the VM, manually):
```sh
sudo curl -fsSL -o /var/lib/brig/images/alpine.tar.gz \
  "https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/$(uname -m)/alpine-minirootfs-3.24.4-$(uname -m).tar.gz"
```
Pin the version dir (`v3.24/`), not `latest-stable/`: that one moves on each release and the pinned filename then 404s. Newer versions: https://alpinelinux.org/downloads/

## 3. Open a shell inside it
multipass shell brig

This also starts the VM if it's stopped.

## 4. Build and run inside the VM
```sh
cd ~/cufarr
sudo zig run src/rubber-docker/00_fork_exec.zig -- run /bin/ls
```
Debug with `strace -f`.

## 5. Start / stop the VM (run on Mac)
```sh
multipass list            # state of each VM (Running/Stopped)
multipass start brig      # start without opening a shell
multipass shell brig      # start if stopped + open a shell
multipass stop brig       # full shutdown; next start is a fresh boot
multipass suspend brig    # pause, keep memory state; resume with start/shell
```
`exit` inside the VM only closes the shell; the VM keeps running.
Stop it when you're done: a stopped VM uses no RAM.
Prefer `stop` over `suspend`: a fresh boot clears leftovers from crashed drills (stuck processes, mounts, namespaces).

## Multipass hangs?
Every command waits on the daemon. If `multipass list` hangs:
```sh
sudo pkill -9 -f qemu-system                                   # kill stuck VM process
sudo launchctl kickstart -k system/com.canonical.multipassd   # restart daemon
multipass list && multipass purge
```
