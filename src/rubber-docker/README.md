# rubber-docker in Zig

Zig port of [rubber-docker](https://github.com/Fewbytes/rubber-docker) levels. These are practice drills, kept separate from brig itself.

## Layout

One standalone file per level. Each level starts as a copy of the previous one and then adds the new step, so `diff` between two levels shows what changed.

```
src/rubber-docker/
├── README.md
├── 00_fork_exec.zig
├── 01_chroot.zig        # copy of 00 + new stuff
└── ...
```

Use `std.os.linux` syscalls directly (`fork`, `execve`, `wait4`, later `clone`, `unshare`, `mount`, `pivot_root`, ...). You don't need the Python `linux` C extension.

## Building

No build.zig needed. Build by path, inside the VM. The drills use Linux-only syscalls, so they can't run on macOS. VM setup (repo mount, Zig install) is in [docs/testing-inside-vm.md](../../docs/testing-inside-vm.md).

Edit on the Mac, then build and run in one step inside the VM:

```sh
cd ~/cufarr
sudo zig run src/rubber-docker/00_fork_exec.zig -- run /bin/ls
```

Debug with `strace -f`.

If the command gets long, add a shell alias or a small `justfile`. Switch to build.zig only when you want to build every level with one command, share flags across levels, or share modules or tests between them.

## Level 00 gotchas

- Python's `os.execvp` searches `PATH` for you. Raw `execve` doesn't, so pass absolute paths (`/bin/ls`) or resolve `PATH` yourself.
- argv must be null-terminated: `[*:null]const ?[*:0]const u8`. No allocation needed: the kernel's argv (`init.args.vector`) already ends in `NULL`, so `@ptrCast(vector[2..])` works. Only suffix slices are safe, because execve reads until `NULL` and ignores the slice length.
- Raw syscalls return `usize` holding `-errno` on failure. Check with `linux.errno(rc)` before `@intCast`, and print it with `{t}`.
- `execve` only returns on failure, so code after it is the error path (`exit(127)`).
- Decode the wait status with `std.os.linux.W` (`IFEXITED`, `EXITSTATUS`, `IFSIGNALED`, `TERMSIG`).
