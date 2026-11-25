# chroot

where do images(downloaded) live? `/var/lib/brig/images`

(running)containers go to `/var/lib/brig/containers/<id>`

base_dir
images_dir

- `/var/lib/<runtime>/images`
- `/var/lib/<runtime>/containers/<id>/root_fs`

uuid https://muhammad-fiaz.github.io/uuid.zig/guide/getting-started.html

## todo

- [x] container id: `linux.getrandom` -> 6 bytes -> hex (`{x}` on `&id`)
- [x] path: `mem.printSentinel(&buf, containers_dir ++ "/{x}/rootfs", .{&id}, 0)`
- [x] mkdir `containers/<id>` then `containers/<id>/rootfs` (no `-p`, 2 calls)
- [x] extract: fork+exec `/bin/tar -xzf images/alpine.tar.gz -C <path>`, waitpid, check exit 0
- [x] helper: fork -> exec -> wait (shared by tar + container)
- [x] `changeRoot(path)`: take path as param, drop hardcoded one
- [x] cleanup: `rm -rf containers/<id>` after container exits (`/bin/rm` or own walk)
- [ ] leftovers: drop `containers/nothing` test path + commented-out old code

## later

- own extractor via `std.tar.Iterator`: full mode (setuid/sticky via `fchmod`), `fchown`, hardlinks, devices. `std.tar.extract` only keeps exec bit.
- overlayfs: extract once per image, per-container writable layer (how docker/podman do it)
