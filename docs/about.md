# brig: a tiny container runtime for cufarr

Nov 2, 2026 · @Dragos

## What we're building and why

You'll build **brig**, a small container runtime in Zig, and **bosun**, a job dispatcher in Go that lives inside cufarr. Together they replace Docker for one job: running cufarr's enrichers (Kobo lookup, cover finder, Goodreads crawler, later movies) on demand, with hard memory limits, on an 8GB machine. The enrichers themselves stay easy to write in Python or JS; all the systems programming goes into the layer that runs them.

**Constraints**

1. **Light:** no always-on daemon, a few MB of overhead per job, memory capped per job.
2. **Built by you:** the point is to learn systems programming, so the runtime is hand-written on top of raw syscalls.

**Why the split: Zig below the process boundary, Go above it**

This mirrors how real stacks are split: containerd (Go) decides *what* runs, runc or crun decides *how* it runs.

- **brig in Zig.** Container work means `fork`, `clone3`, `unshare`, `setns` and `pivot_root`. Go fights you here: its runtime is multithreaded, namespaces apply per thread, `unshare(CLONE_NEWUSER)` refuses to work in a multithreaded process, and you can't safely `fork` without `exec`. Go projects work around this with a self re-exec trick (Liz Rice's talk) or a C constructor (runc's `nsenter`). Zig has no hidden runtime and exposes raw syscalls in `std.os.linux`, so every step stays visible. It also puts your allocator and ownership practice to real use.
- **bosun in Go.** The queue, retries, rate limits and HTTP live in cufarr, which is already Go + SQLite. Go is good at exactly that.
- **The contract between them** is a CLI plus JSON: bosun runs `brig run … -- <enricher>` per job, pipes the job JSON in, and reads one JSON report back. Either side can be rewritten without touching the other, and a WASM backend can slot in later behind the same contract.

&#91;embedded content: architecture · 6 parts, brig highlighted\]

cufarr queues a job in SQLite; bosun claims it and runs brig, which runs the enricher and hands back one report. Chapter 1 builds the highlighted box.

If you'd rather use one language, all-Zig is the purest option. All-Go also works if you accept the re-exec trick, but you'll see less of the machinery.

The Zig standard library changed a lot in 0.16 (released spring 2026; I/O moved to `std.Io`, process spawning now takes an `io`). brig mostly avoids that churn by calling `std.os.linux` directly, but pin one Zig version for the whole project.

## The roadmap

Eleven chapters, each ending in something that runs. cufarr enriches links for real after Chapter 3; everything after that hardens and slims it down. Chapters 6, 9 and 10 are optional.

| # | Lang | What you build | What you learn |
| --- | --- | --- | --- |
| 0 | — | The Wyse prepared: distro, kernel, cgroup v2, Zig pinned, test enrichers | How to check what your kernel supports; `strace` as your main debugger |
| 1 | Zig | `brig run`: spawn one enricher, pipe JSON in and out, timeouts, kill escalation, a JSON report | fork/exec, file descriptors, pipes, wait status, signals, process groups, `poll`, pidfd |
| 2 | Zig | Resource limits: a cgroup per job with memory, CPU and PID caps; peak memory and OOM detection; kill the whole tree | cgroups v2 files, `clone3` with `CLONE_INTO_CGROUP`, `cgroup.kill`, systemd delegation |
| 3 | Go | `bosun`: SQLite job queue inside cufarr, worker loop, retries with backoff, per-domain rate limits, admission control from memory pressure | Job queues, backpressure, PSI (`/proc/pressure/memory`), designing the brig–bosun contract |
| 4 | Zig | Isolation: each job in new PID, UTS, IPC and mount namespaces, with brig as PID 1 | Namespaces, `/proc`, why PID 1 must reap zombies, mount propagation |
| 5 | Zig | Filesystems: an Alpine/Debian rootfs, shared read-only base via overlayfs, a throwaway layer per job, `pivot_root` | Mounts, overlayfs, bind mounts, tmpfs, `pivot_root` vs `chroot` |
| 6 | Go | `brig pull` (optional): fetch OCI images from a registry and unpack layers | OCI image and distribution specs, content addressing, tar, whiteout files |
| 7 | Zig | Hardening: drop capabilities, `no_new_privs`, a hand-written seccomp filter, rootless via user namespaces | Capabilities, seccomp-BPF, uid/gid mapping, the user-namespace attack surface |
| 8 | Zig + Go | Scale to zero: your own socket activator that starts cufarr on the first request; cufarr exits when idle and the queue is empty | Sockets, `epoll`, passing fds to a child (`LISTEN_FDS`), graceful shutdown |
| 9 | Zig | Networking (optional): a network namespace per job with veth, a bridge and NAT | rtnetlink sockets, veth pairs, bridges, nftables |
| 10 | Zig | WASM backend (optional): embed Wasmtime's C API so brig can also run `.wasm` enrichers behind the same contract | Embedding a runtime, WASI, comparing a WASM sandbox with a Linux one |

Rough sizes: Chapters 1, 2 and 4 are a weekend or two each; 5, 7 and 9 are the hardest. Real work will vary, so treat these as guesses.

## Reading list

Start with the three marked **start here**; read the rest when its chapter comes up. *The Linux Programming Interface* (TLPI) is the backbone for the whole project.

**Containers, end to end**

| Resource | Format | Why | Chapters |
| --- | --- | --- | --- |
| [Containers From Scratch](https://github.com/lizrice/containers-from-scratch), Liz Rice — **start here** | Talk + Go repo | A container in about 60 lines; shows the Go re-exec trick | 4, 5 |
| [Linux containers in 500 lines of code](https://blog.lizzie.io/linux-containers-in-500-loc.html), Lizzie Dixon — **start here** | Annotated C | Every mechanism (namespaces, cgroups, capabilities, seccomp, user namespaces) with reasoning about what's unsafe; the closest thing to brig's full design | 2, 4, 5, 7 |
| [How Containers Work!](https://wizardzines.com/zines/containers/), Julia Evans | Zine | The whole picture in drawings; good for a first pass | All |
| [Containers from Scratch](https://ericchiang.github.io/post/containers-from-scratch/), Eric Chiang | Blog post, Go | Builds a container step by step from shell commands, then code | 4, 5 |
| [Bocker](https://github.com/p8952/bocker) | Bash repo | Docker's core in about 100 lines of shell; shows how little magic there is | 5, 6 |
| [OCI runtime spec](https://github.com/opencontainers/runtime-spec) | Spec | What a real runtime's `config.json` covers; borrow ideas for brig's job spec | 3, 5 |
| [runc libcontainer/nsenter](https://github.com/opencontainers/runc/tree/main/libcontainer/nsenter) | Source + README | Why Go needs C to enter namespaces; read when you wonder why brig is in Zig | 4 |
| *Container Security*, Liz Rice (O'Reilly) | Book | Namespaces, cgroups, capabilities and seccomp from the security angle | 4, 7 |

**Linux system programming**

| Resource | Format | Why | Chapters |
| --- | --- | --- | --- |
| [The Linux Programming Interface](https://man7.org/tlpi/), Michael Kerrisk — **start here** | Book | The reference for every syscall brig uses; chapter pointers are given in each chapter of this plan | All |
| [Linux man pages](https://man7.org/linux/man-pages/) | Reference | Section 2 for syscalls, section 7 for overviews (`namespaces(7)`, `cgroups(7)`, `signal(7)`, `pipe(7)`, `capabilities(7)`) | All |
| [Namespaces in operation](https://lwn.net/Articles/531114/), Michael Kerrisk (LWN) | Article series | The clearest walk through each namespace type, with demo programs | 4, 5, 7 |
| *Advanced Programming in the UNIX Environment*, Stevens & Rago | Book | A second explanation of processes, signals and I/O when TLPI's doesn't click | 1, 8 |
| [Beej's Guide to Network Programming](https://beej.us/guide/bgnet/) | Guide | Sockets from zero | 8, 9 |

**Kernel documentation**

| Resource | Format | Why | Chapters |
| --- | --- | --- | --- |
| [Control Group v2](https://docs.kernel.org/admin-guide/cgroup-v2.html) | Kernel docs | The authoritative cgroup v2 reference: every file brig writes | 2 |
| [Pressure Stall Information](https://docs.kernel.org/accounting/psi.html) | Kernel docs | How to read memory pressure for bosun's admission control | 3 |
| [Seccomp BPF](https://docs.kernel.org/userspace-api/seccomp_filter.html) | Kernel docs | How seccomp filters work, for writing one by hand | 7 |
| [Rootless containers](https://rootlesscontaine.rs/) | Site | How unprivileged containers work and what they can't do | 7 |

**systemd and activation**

| Resource | Format | Why | Chapters |
| --- | --- | --- | --- |
| [systemd for Developers I](https://0pointer.de/blog/projects/socket-activation.html), Lennart Poettering | Blog post | Socket activation explained by its author; the protocol your activator will copy | 8 |
| `systemd.socket(5)`, `sd_listen_fds(3)` | Man pages | The exact `LISTEN_FDS` contract | 8 |

**Zig and Go**

| Resource | Format | Why | Chapters |
| --- | --- | --- | --- |
| [Learning Zig](https://www.openmymind.net/learning_zig/), Karl Seguin | Guide | Practical Zig, especially pointers and memory | 1+ |
| [Ziglings](https://codeberg.org/ziglings/exercises) | Exercises | Small exercises to drill syntax | 0, 1 |
| `lib/std/os/linux.zig` in your Zig install | Source | The raw syscall wrappers brig uses; read it for your exact version since the std library changes between releases | All Zig chapters |
| *The Go Programming Language*, Donovan & Kernighan | Book | Solid Go foundations for bosun | 3, 6 |

## Chapter 0: Prepare the Wyse

An evening's work: make sure the kernel has what later chapters need, so you don't discover a missing feature in Chapter 4.

- [ ] Install a current server distro (Debian 13 or Ubuntu 24.04+). You want **kernel 5.19 or newer**: `pidfd_open` needs 5.3, `CLONE_INTO_CGROUP` 5.7, `memory.peak` 5.19.
- [ ] Confirm cgroup v2 is the only hierarchy: `stat -fc %T /sys/fs/cgroup` prints `cgroup2fs`.
- [ ] Check which controllers are enabled: `cat /sys/fs/cgroup/cgroup.controllers` should list `cpu memory pids`.
- [ ] Check PSI is on: `cat /proc/pressure/memory` prints two lines instead of an error.
- [ ] Check unprivileged user namespaces (needed in Chapter 7): `unshare --user --map-root-user id` should print `uid=0(root)`.
- [ ] Install and pin one Zig version (0.16.x at the time of writing). Write the version in a `.zig-version` file in the repo.
- [ ] Install tools: `strace` (your main debugger from here on), `python3`, `jq`, `util-linux` (`unshare`, `nsenter`, `lsns`).
- [ ] Create the repo: `brig/` (Zig) and `tests/jobs/` (the torture-test enrichers from Chapter 1).
- [ ] Optional warm-up: do the Ziglings exercises on pointers, slices, errors and allocators.

## Chapter 1: brig run, a process supervisor

You'll build `brig run`: a Zig CLI that starts one enricher, feeds it the job JSON, collects its output, enforces a deadline, kills it and everything it spawned when needed, and always prints exactly one JSON report. No isolation yet; this chapter is about controlling a process completely. It is also the core that every later chapter wraps.

### What you'll have at the end

```
brig run [--timeout 30s] [--grace 2s] [--max-output 1MiB] -- <cmd> [args...]
```

- brig's **stdin** goes to the job's stdin (the job JSON).
- The job's **stderr** is forwarded live to brig's stderr, and the last 4 KiB are kept for the report.
- The job's **stdout** is captured, up to `--max-output`.
- brig's **stdout** carries one report, always:

```json
{
  "status": "ok",
  "exit_code": 0,
  "signal": null,
  "duration_ms": 412,
  "cpu_user_ms": 180,
  "cpu_sys_ms": 30,
  "max_rss_kb": 23140,
  "stdout": "{\"title\": \"Dune\"}",
  "stdout_truncated": false,
  "stderr_tail": ""
}
```

`status` is one of `ok`, `failed` (non-zero exit), `signaled`, `timeout`, `output_limit`, `spawn_error` or `cancelled`. brig's **own** exit code says only whether brig worked: `0` whenever a report was written, even if the job failed; `2` for bad arguments; `1` for an internal error. Keeping "the job failed" separate from "the runtime failed" is the same split runc makes, and bosun will depend on it.

### What you'll learn

- How a process is born and replaced: `fork`, `execve`, and what a child inherits (file descriptors, signal dispositions, signal mask, environment).
- File descriptors as the universal handle: `pipe2`, `dup2`, `O_CLOEXEC`, `O_NONBLOCK`, and why a stray fd makes a pipe never reach EOF.
- Wait status: exit code vs signal, `wait4` and resource usage.
- Signals: delivery, `SIGTERM` vs `SIGKILL`, `SIGPIPE`, and process groups for signalling a whole tree.
- Event loops: one `poll` loop over pipes, a deadline and a **pidfd** (a file descriptor for a process, Linux 5.3+).
- Using `strace -f` to watch your own program's syscalls.

### Milestones

Build these in order. Each one is runnable and testable on its own.

1. **Spawn and wait.** `fork`, then `execve` in the child, `wait4` in the parent. Decode the wait status into `exit_code` or `signal`. Implement a small `PATH` search yourself, since `execve` needs a full path.
   - Learn: why fork-then-exec is two steps; what the wait status bits mean.
   - Done when: `true`, `false` and `sh -c 'kill -SEGV $$'` give the right status.
2. **Report exec failures.** If `execve` fails in the child, the parent must find out. Classic trick: a pipe with `O_CLOEXEC`. The child writes `errno` into it if exec fails; a successful exec closes it, so the parent reads EOF.
   - Learn: close-on-exec, and how two processes can talk across `fork`.
   - Done when: `brig run -- /nope` reports `spawn_error` with the reason.
3. **Plumbing and the event loop.** Create stdin/stdout/stderr pipes, `dup2` them onto 0/1/2 in the child, close every other end. In the parent, make your ends non-blocking and drive them from one `poll` loop: write stdin as the job accepts it, read stdout and stderr as they arrive, and watch a pidfd for the exit.
   - Learn: why writing all of stdin before reading stdout deadlocks once the pipe buffer (64 KiB by default) fills; `EAGAIN`, `EINTR`, short reads and writes.
   - Done when: 1 MiB through `cat` comes back intact.
4. **Deadlines and kill escalation.** Put the child in its own process group (`setpgid` in both parent and child, to avoid a race). At the deadline, send `SIGTERM` to the group, wait `--grace`, then `SIGKILL`. Use the monotonic clock for deadlines, never wall time.
   - Learn: process groups; that **process exit and pipe EOF are different events** (a grandchild can hold the pipe open after the main process exits).
   - Done when: the slow, stubborn and grandchild tests below pass.
5. **Limits, usage and the report.** Cap captured stdout; on overflow, kill the group and report `output_limit`. Take CPU time and `max_rss_kb` from `wait4`'s rusage. Write the report JSON. Stretch goal: handle `SIGTERM`/`SIGINT` sent to brig itself through a `signalfd` in the same poll loop, forward them to the job group, and report `cancelled`.
   - Learn: `getrusage` fields and their limits (`ru_maxrss` is only rough here; Chapter 2 gives the real number).
   - Done when: the full torture suite passes.

### Torture-test enrichers

Put each one in `tests/jobs/` as a tiny script, and write a test runner (a shell script is fine) that checks the `status` field of each report with `jq`.

| Test | What the job does | Expected report | Teaches |
| --- | --- | --- | --- |
| echo.py | Reads the job JSON, writes a JSON result | `ok` | The happy path |
| fail.sh | `exit 3` | `failed`, exit\_code 3 | Decoding wait status |
| segv.sh | `kill -SEGV $$` | `signaled`, signal 11 | Exit vs signal |
| missing | `brig run -- /nope` | `spawn_error` | The close-on-exec pipe trick |
| slow.sh | `sleep 60`, run with `--timeout 2s` | `timeout` after SIGTERM | Deadlines |
| stubborn.sh | `trap '' TERM; sleep 60` | `timeout`, killed by SIGKILL after the grace period | Kill escalation |
| bigio | `cat` with 1 MiB on stdin | `ok`, 1 MiB of stdout | Pipe buffers, non-blocking I/O |
| nostdin | `exit 0` without reading 1 MiB of stdin | `ok`, brig doesn't crash | SIGPIPE and EPIPE |
| spammer | `yes` | `output_limit` | Caps, killing on overflow |
| grandchild.sh | `sleep 300 &` then `exit 0` | `ok` within the grace period; the sleep is killed | Exit vs EOF; group kill |
| escapee.sh | `setsid sleep 300 &` then `exit 0` | `ok`, but the sleep **survives** | A known gap, fixed in Chapter 2 |
| cancel | SIGTERM sent to brig mid-job | `cancelled`, job group killed | Signal forwarding (stretch) |

The escapee is the point of the chapter's ending: `setsid` moves a process into a new session and process group, so nothing in Chapter 1 can find or kill it. brig should notice the stdout pipe never closes, stop waiting after a short drain deadline, and still report. Then `pgrep sleep` shows the survivor. Chapter 2 closes the gap: a cgroup holds every descendant, whatever it does, and `cgroup.kill` ends them all at once.

### Hints and pitfalls

- **Ignored signals survive `execve`.** If brig ignores `SIGPIPE` (it should, to handle `EPIPE` itself), reset it to the default in the child before `execve`, or Python inherits the ignore. The same goes for a blocked signal mask if you use `signalfd`.
- **Use `O_CLOEXEC` on everything** and let `dup2` clear it on 0/1/2 only. A single leaked write end keeps a pipe open forever.
- **Keep brig single-threaded.** `fork` in a multithreaded process copies only the calling thread, which is the root of Go's problems. Avoid `std.Io.Threaded` in brig's core and call `std.os.linux` directly.
- **In Zig, raw syscalls return a number;** convert it to an error with the `E` helpers in `std.os.linux`. Function names move between Zig versions, so read `lib/std/os/linux.zig` for your installed version rather than trusting tutorials.
- **Use an arena allocator per run;** it fits a one-shot CLI and keeps cleanup trivial.
- **When stuck, run `strace -f -e trace=process,desc,signal ./brig run …`** and read what actually happened.

### Reading for this chapter

- TLPI chapters 24–28 (process creation, termination, monitoring children, program execution), 20–22 (signals), 34 (process groups and sessions), 44 (pipes) and 63 (alternative I/O models: `poll`, `epoll`).
- Man pages: `fork(2)`, `execve(2)`, `pipe(7)`, `dup2(2)`, `wait4(2)`, `pidfd_open(2)`, `poll(2)`, `signal(7)`, `signal-safety(7)`, `setpgid(2)`, `getrusage(2)`.
- If TLPI's take on signals doesn't land, read APUE chapters 8 and 10 for a second explanation.

### Definition of done

- [ ] All 11 core torture tests pass from one command.
- [ ] Every run prints exactly one valid JSON report, including on `spawn_error`.
- [ ] No leftover processes after any test except the escapee, checked with `pgrep`.
- [ ] No leaked fds: `ls /proc/<brig pid>/fd` mid-run shows only what you expect.
- [ ] You can explain, without notes, why the grandchild test would hang without a process group and a drain deadline.
- [ ] Stretch: the cancel test passes.

## Chapter 2: limits with cgroups v2

You'll put every job in its own cgroup, so brig can cap its memory, CPU and process count, measure its real peak memory, detect OOM kills, and kill **every** process it spawned, including the Chapter 1 escapee. After this chapter, a misbehaving enricher can no longer hurt the rest of the Wyse.

### What you'll have at the end

```
brig run [--timeout 30s] [--grace 2s] [--max-output 1MiB]
         [--memory 256M] [--cpus 0.5] [--pids 64] -- <cmd> [args...]
```

The report gains four fields and one status:

```json
{
  "status": "oom",
  "memory_peak_bytes": 268435456,
  "oom_killed": true,
  "cpu_throttled_ms": 1840,
  "pids_limit_hit": false
}
```

`oom` joins the status list from Chapter 1. `cpu_user_ms` and `cpu_sys_ms` now come from the cgroup, so they include every descendant, not only the direct child.

### What you'll learn

- How cgroups v2 works: a tree of directories under `/sys/fs/cgroup`, controlled entirely by reading and writing small text files.
- The **no internal processes** rule: a cgroup that hands controllers to its children can't hold processes itself, so brig needs a careful layout.
- **Delegation:** how systemd gives a program its own subtree to manage, and why you shouldn't write anywhere else.
- What "memory" really means to the kernel: anonymous memory, page cache and kernel memory are all charged to the cgroup, which is why `memory.peak` and Chapter 1's `max_rss_kb` disagree.
- `memory.max` vs `memory.high`, `memory.oom.group`, `cpu.max` quotas and throttling, `pids.max`.
- Starting a process directly inside a cgroup with `clone3` and `CLONE_INTO_CGROUP`, and killing a whole cgroup with `cgroup.kill`.
- Waiting on a file: `cgroup.events` signals changes, so "the job and all its descendants are gone" becomes an event in your `poll` loop.

### The layout

brig gets one delegated subtree from systemd and arranges it like this:

```
<delegated root>/            subtree_control: +memory +cpu +pids
├── supervisor/              brig itself lives here (a leaf)
└── jobs/                    subtree_control: +memory +cpu +pids
    ├── job-<id>/            one per run: memory.max, cpu.max, pids.max
    └── job-<id>/
```

brig can't stay in the delegated root, because that cgroup enables controllers for its children. So its first act is to move itself into `supervisor/`. Forgetting this gives a confusing `EBUSY` when you write `subtree_control`.

For development, get a delegated scope with `sudo systemd-run --scope -p Delegate=yes --unit=brig-dev bash` and run brig from that shell; `cat /proc/self/cgroup` shows the path you own. Running as root is fine for now; Chapter 7 makes brig rootless.

### Milestones

1. **Find and prepare your subtree.** Read `/proc/self/cgroup` to find where brig lives, create `supervisor/` and `jobs/`, move brig into `supervisor/` by writing `0` to its `cgroup.procs` (`0` means "the writing process"), then enable controllers by writing `+memory +cpu +pids` to `cgroup.subtree_control` at each level.
   - Learn: the cgroup filesystem, the no-internal-processes rule, delegation.
   - Done when: `cat jobs/cgroup.controllers` lists `cpu memory pids`.
2. **One cgroup per job, joined before exec.** Create `jobs/job-<id>/` and write the limits. Simplest way in: the child writes `0` to the job's `cgroup.procs` after `fork` and before `execve`. Since that happens before the enricher's code runs, nothing escapes.
   - Limits: `memory.max` (bytes), `memory.swap.max` = `0` so the cap is real, `memory.oom.group` = `1` so an OOM kills the whole job rather than one random process, `cpu.max` ("50000 100000" means half a CPU), `pids.max`.
   - Learn: what each file means and its units.
   - Done when: `cat /proc/<job pid>/cgroup` shows the job's cgroup, and the hog test below reports `oom`.
3. **Upgrade to `clone3` with `CLONE_INTO_CGROUP`.** Open the job's cgroup directory, pass the fd in `clone_args.cgroup`, and the child is born inside it, with no window where it isn't. In Zig you'll likely define the `clone_args` struct yourself and call the raw syscall; read `clone(2)` closely.
   - Learn: the difference between `fork`, `clone` and `clone3`; the syscall ABI for structs.
   - Done when: all Chapter 1 tests still pass with `clone3` replacing `fork`.
4. **Kill everything and clean up.** When the main process exits (or at timeout), write `1` to `cgroup.kill`. Add the job's `cgroup.events` to your `poll` loop and wait until it reports `populated 0`, which means no process is left. Then `rmdir` the job's cgroup; it only succeeds when the cgroup is empty.
   - Learn: `cgroup.kill` vs signalling a process group; event-driven waiting instead of sleeping.
   - Done when: the escapee and daemon tests leave **zero** processes behind.
5. **Measure and report.** Before removing the cgroup, read `memory.peak`, `memory.events` (the `oom_kill` count), `cpu.stat` (`user_usec`, `system_usec`, `throttled_usec`) and `pids.events` (the `max` count). Map them into the report, and set status `oom` when `oom_kill` went up.
   - Learn: `memory.stat`'s breakdown (`anon`, `file`, `kernel`); compare it with `ru_maxrss` for a Python job and explain the gap.
   - Done when: the full Chapter 2 suite passes.

### Torture tests

All of Chapter 1's tests still pass. Add these, and after every test assert that `jobs/` has no subdirectories left.

| Test | What the job does | Flags | Expected report | Teaches |
| --- | --- | --- | --- | --- |
| hog.py | Allocates and touches 1 GiB | `--memory 128M` | `oom`, oom\_killed true | memory.max, OOM detection |
| grows.py | Allocates 100 MB, then exits | `--memory 256M` | `ok`, memory\_peak around 100–120 MB | memory.peak vs ru\_maxrss |
| spinner.py | Busy loop for 4 s of wall time | `--cpus 0.5` | `ok`, about 2 s of CPU, throttled time > 0 | cpu.max, throttling |
| forkbomb.sh | `while :; do sleep 100 & done` | `--pids 32 --timeout 3s` | `timeout`, pids\_limit\_hit true, nothing left | pids.max |
| escapee.sh | `setsid sleep 300 &` then `exit 0` | — | `ok`, the sleep is **gone** | cgroup.kill fixes Chapter 1's gap |
| daemon.py | Double-forks into a background daemon, parent exits | — | `ok`, the daemon is gone | Nothing escapes a cgroup |
| parallel | Three `brig run` at once | — | Three separate cgroups, no name clashes, all cleaned | Unique job IDs, concurrent setup |
| crash-brig | `kill -9` brig mid-job | — | The job is left running: note it for Chapter 3 | Why bosun must sweep stale cgroups |

The last test has no fix in this chapter on purpose. If brig itself dies, nobody writes `cgroup.kill`. bosun will handle it in Chapter 3 by sweeping `jobs/` for cgroups whose brig is gone.

### Hints and pitfalls

- **Writes can fail with useful errors.** `EBUSY` usually means the no-internal-processes rule; `ENOENT` on a limit file means the controller isn't enabled for that level; `EINVAL` means bad units or format.
- **Swap hides limits.** Without `memory.swap.max` = `0`, a job over its limit can swap instead of being killed, and on the Wyse's SATA SSD that just looks like a hang.
- **`memory.high` is the gentle limit.** Above it the kernel throttles and reclaims; above `memory.max` it kills. Setting high at about 90% of max can turn some OOMs into slowdowns. Try both and compare.
- **Page cache counts.** A crawler that writes a big temp file is charged for its page cache. That's usually fine, since cache is reclaimed before the OOM killer runs, but it explains surprising `memory.peak` numbers.
- **Don't sleep-poll for cleanup.** `cgroup.events` changes are reported through `poll` (see the kernel docs). Treat "cgroup empty" like any other event in the loop.
- **Never touch cgroups outside your delegated subtree.** systemd owns the rest and will undo or fight your changes.

### Reading for this chapter

- [Control Group v2](https://docs.kernel.org/admin-guide/cgroup-v2.html): the sections on the basic operations, the no-internal-process constraint, delegation, and the memory, CPU and PID controllers. This is the main text for the chapter.
- Man pages: `cgroups(7)`, `clone(2)` (the `clone3` and `CLONE_INTO_CGROUP` parts), `systemd.resource-control(5)` (`Delegate=`).
- [systemd: Control Group APIs and Delegation](https://systemd.io/CGROUP_DELEGATION/): the rules for living alongside systemd.
- Lizzie Dixon's "Linux containers in 500 lines", cgroups section: useful for the reasoning, but note it uses the older cgroup v1 interface, so the file names differ.
- TLPI predates cgroups v2, so it doesn't cover this chapter.

### Definition of done

- [ ] All Chapter 1 and Chapter 2 tests pass from one command.
- [ ] No processes and no job cgroups are left after any test, except after crash-brig.
- [ ] brig starts jobs with `clone3` and `CLONE_INTO_CGROUP`.
- [ ] The report shows `memory_peak_bytes`, and `oom` is reported correctly.
- [ ] You can explain why brig must live in `supervisor/` and not in its delegated root.
- [ ] You can explain why `memory.peak` for a Python job is larger than its `ru_maxrss`.

## Chapter 3: bosun, the dispatcher

You'll build bosun, a Go package inside cufarr that keeps the job queue in SQLite, runs each job through `brig run`, retries what failed for temporary reasons, respects per-site rate limits, and only starts a job when the machine has room for it. At the end of this chapter, saving a link in cufarr triggers real enrichment, end to end.

### What you'll have at the end

- A `jobs` table and a worker loop that claims jobs, runs them through brig, and stores results.
- A registry of enricher kinds, each with its command, limits and retry policy:

```toml
[kinds.kobo_lookup]
command = ["python3", "/opt/enrichers/kobo_lookup.py"]
timeout = "30s"
memory = "128M"
cpus = 0.5
pids = 32
max_attempts = 5
rate_limit = { domain = "kobo.com", every = "5s" }
```

- An exit-code contract for enrichers, borrowed from `sysexits.h`: `0` success, `75` (EX\_TEMPFAIL) "try again later", `65` (EX\_DATAERR) "nothing to find, don't retry". Any other failure is retried until `max_attempts`.
- Crash recovery: on startup, jobs stuck in `running` go back to the queue, and job cgroups whose brig is gone are killed and removed. This fixes Chapter 2's crash-brig gap.
- Two real enrichers: a generic one that reads JSON-LD and OpenGraph from any page, and an Open Library lookup by ISBN.

### What you'll learn

- Designing a job queue: states, claiming, leases, at-least-once delivery, and why enrichers must be idempotent.
- SQLite as a queue: WAL mode, `busy_timeout`, `UPDATE … RETURNING` to claim a job atomically.
- Retries: exponential backoff with jitter, and telling temporary failures from permanent ones.
- Rate limiting with a token bucket you write yourself.
- **Admission control:** reading Pressure Stall Information (`/proc/pressure/memory`) and `/proc/meminfo` to decide whether the Wyse can take one more job.
- Go concurrency in practice: a worker pool, `context` cancellation, graceful shutdown.

### Milestones

1. **The table and the claim.** Create `jobs` with `id`, `kind`, `payload` (JSON), `status` (`queued`, `running`, `done`, `failed`, `dead`), `attempts`, `run_after`, `lease_until`, `last_error`, `result` and timestamps. Claim one job in a single statement: `UPDATE jobs SET status = 'running', lease_until = ? WHERE id = (SELECT id FROM jobs WHERE status = 'queued' AND run_after <= ? ORDER BY run_after LIMIT 1) RETURNING *`. Turn on WAL mode.
   - Learn: why the claim must be one atomic step; leases vs locks.
   - Done when: 100 queued jobs are each claimed exactly once by 4 concurrent workers.
2. **Run through brig.** Build the `brig run` argument list from the kind's settings, pipe the payload in with `os/exec`, parse the report, and map it to a job outcome: `ok` → done; exit `75`, `timeout` or `oom` → retry; exit `65` → done with no result; anything else → retry until `max_attempts`, then `dead`.
   - Learn: the brig–bosun contract in practice; why brig's own exit code must differ from the job's.
   - Done when: a saved link produces a stored result.
3. **Retries and rate limits.** On retry, set `run_after = now + base × 2^attempts`, plus random jitter, capped at a maximum. For rate limits, keep one token bucket per domain in memory; if a job's bucket is empty, push its `run_after` forward instead of blocking a worker.
   - Learn: why jitter matters; why a rate-limited job should never hold a worker slot.
   - Done when: 10 jobs for one domain with `every = "2s"` start about 2 s apart.
4. **Admission control.** Before starting a job, check three things: running jobs < `max_concurrent`; `MemAvailable` in `/proc/meminfo` > the job's memory limit + a reserve; and `avg10` from the `some` line of `/proc/pressure/memory` is below a threshold. If any check fails, wait and re-check. Stretch: replace re-checking with a PSI **trigger** (write a threshold to the pressure file and `poll` for an event).
   - Learn: what PSI measures and why it's a better signal than free memory alone.
   - Done when: running a memory hog outside cufarr makes bosun pause, and it resumes when the hog exits.
5. **Crash recovery and shutdown.** On startup, requeue `running` jobs whose lease expired, and sweep brig's `jobs/` cgroup directory: kill and remove any job cgroup without a live brig. On `SIGTERM`, stop claiming, give running jobs a deadline, then signal brig (which reports `cancelled`) and requeue them.
   - Learn: at-least-once semantics; designing for crashes instead of hoping they don't happen.
   - Done when: `kill -9` on cufarr mid-job, then a restart, leaves no orphans and the job completes.

### Tests

| Test | Setup | Expected |
| --- | --- | --- |
| Exactly once | 100 jobs, 4 workers | Every job claimed once, none lost |
| Temporary failure | Enricher exits `75` twice, then succeeds | `done` after 3 attempts, growing delays |
| Poison job | Enricher always exits `1` | `dead` after `max_attempts`, error stored |
| No data | Enricher exits `65` | `done`, no retries |
| Rate limit | 10 jobs, one domain, `every = "2s"` | Starts spaced about 2 s apart, workers stay free |
| Memory pressure | A hog running outside cufarr | New jobs wait, then resume |
| Crash mid-job | `kill -9` cufarr, restart | Stale cgroup removed, job requeued and finished |
| Graceful stop | `SIGTERM` with 3 jobs running | Jobs cancelled and requeued, clean exit |

### Hints and pitfalls

- **SQLite drivers:** `modernc.org/sqlite` is pure Go (no cgo, easy cross-compiling); `mattn/go-sqlite3` uses cgo. Either works. Use a single writer connection to avoid `SQLITE_BUSY` surprises.
- **Idempotent enrichers:** a job may run twice after a crash. Results should be upserts keyed by the job's link or thing, never blind inserts.
- **Don't hard-code the Wyse's numbers.** Make `max_concurrent`, the memory reserve and the PSI threshold configurable, then tune them by watching real runs.
- **Keep enrichers dumb.** They read JSON, fetch, parse and print JSON. Retries, rate limits and scheduling all live in bosun, so every enricher stays a short script.
- **Use APIs before scraping.** Open Library and Google Books for books, TMDB for movies, JSON-LD for almost everything else.

### Reading for this chapter

- [Pressure Stall Information](https://docs.kernel.org/accounting/psi.html): the file format and the trigger API.
- SQLite docs on [WAL mode](https://www.sqlite.org/wal.html) and [RETURNING](https://www.sqlite.org/lang_returning.html).
- [Exponential Backoff And Jitter](https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/), Marc Brooker (AWS Architecture Blog).
- [Go Concurrency Patterns: Pipelines and cancellation](https://go.dev/blog/pipelines) and the [context package](https://pkg.go.dev/context) docs.
- `sysexits.h` (`man sysexits` on most systems) for the exit-code conventions.
- [Transactional enqueueing](https://riverqueue.com/docs/transactional-enqueueing) (River docs): why storing the data and its job in one transaction avoids lost or orphaned jobs. River supports SQLite too, so its docs map closely onto cufarr. For the Elixir take on job states, see [Oban's docs](https://hexdocs.pm/oban).
- [containerd architecture](https://github.com/containerd/containerd/blob/main/design/architecture.md) (design doc in the containerd repo): how Docker splits "what runs" from "how it runs". Read it before deciding whether bosun's queue and its machine-wide admission control should stay together.
- [Docker: runc, containerd, and the OCI](https://accenture.github.io/blog/2021/03/18/docker-components-and-oci.html) (Accenture blog): a gentler overview of how Docker, containerd and runc fit together.

### Definition of done

- [ ] Saving a book link in cufarr produces enriched metadata without manual steps.
- [ ] All tests in the table pass.
- [ ] No orphan processes or cgroups after any crash test.
- [ ] You can explain why bosun gives at-least-once delivery, not exactly-once, and what that requires of enrichers.

## Chapter 4: isolation with namespaces

You'll make each job see only itself: its own process list, hostname, IPC objects, mount table and cgroup tree. This is the step where `brig run` starts producing something you'd honestly call a container. Networking stays shared with the host until Chapter 9.

### What you'll have at the end

- Each job runs in new **PID, UTS, IPC, mount and cgroup** namespaces, created through `clone3` flags alongside Chapter 2's `CLONE_INTO_CGROUP`.
- A small **init** inside each job: the first process in the new PID namespace is brig's own code (PID 1), which starts the enricher as PID 2, forwards signals to it, reaps every zombie, and exits with the enricher's status. It's the same idea as `tini` or `dumb-init`.
- Inside the job: `ps` shows only the job's processes, `hostname` prints `brig-<id>`, and `/proc` is a fresh mount for that namespace.
- A flag to keep the host network for now (`--net host`, the default until Chapter 9).

### What you'll learn

- What a namespace is, how `/proc/<pid>/ns/*` represents one, and how `setns` and `nsenter` join an existing one.
- **PID 1 is special:** signals with no handler don't kill it, orphans are re-parented to it, and when it exits the kernel kills the rest of the namespace.
- Mount namespaces and **propagation** (shared, private, slave), and why the first step inside a new mount namespace is making everything private.
- Why `/proc` must be remounted for a new PID namespace to look right.
- Debugging live jobs with `lsns` and `nsenter`.

### Milestones

1. **UTS and IPC first.** Add `CLONE_NEWUTS | CLONE_NEWIPC` and call `sethostname` in the child. These two are the easiest wins and prove your `clone3` flags work.
   - Done when: `hostname` inside a job prints `brig-<id>` and the host's hostname is unchanged; `readlink /proc/<job>/ns/uts` differs from the host's.
2. **PID namespace and the init.** Add `CLONE_NEWPID`. The first child becomes PID 1 and runs brig's init code: block signals, fork the enricher (PID 2), then loop on a `signalfd`, forwarding `SIGTERM` and `SIGINT` to the enricher and calling `waitpid(-1, …)` for every `SIGCHLD` to reap orphans. Exit with the enricher's status when it ends.
   - Learn: what breaks if the enricher itself is PID 1 (try it first: a script without a `SIGTERM` handler ignores the signal).
   - Done when: the zombie and signal tests pass.
3. **Mount namespace and `/proc`.** Add `CLONE_NEWNS`. In the child, first remount `/` recursively as private (`MS_REC | MS_PRIVATE`), then mount a fresh `proc` on `/proc`.
   - Learn: what happens without the private step (mounts leak back to the host, or the remount fails).
   - Done when: a `tmpfs` mounted inside a job doesn't appear in the host's `/proc/self/mountinfo`, and `ps` inside shows two or three processes.
4. **Cgroup namespace.** Add `CLONE_NEWCGROUP` so the job sees its own cgroup as `/`, not the host's full path.
   - Done when: `cat /proc/self/cgroup` inside a job prints `0::/`.
5. **Debugging tools.** Add `brig ps` (list running jobs with their host PIDs, read from the cgroup tree) and `brig exec <job> -- <cmd>` (join a running job's namespaces with `setns` on its `/proc/<pid>/ns/*` files, then exec).
   - Learn: `setns`, and why joining a PID namespace only takes effect for children.
   - Done when: `brig exec <job> -- ps` shows the job's processes.

### Tests

| Test | What the job does | Expected |
| --- | --- | --- |
| ps | `ps aux` | Only init, the enricher and `ps` itself |
| hostname | `hostname` | `brig-<id>`; host unchanged |
| zombies | Spawns 20 children that exit, never waits for them | No `Z` processes during the run; init reaped them |
| no-handler | `sleep 60` with `--timeout 2s` | Stops at SIGTERM through init, no SIGKILL needed |
| mount leak | Mounts a `tmpfs` at `/mnt` | Not visible on the host |
| ns links | `readlink /proc/self/ns/*` | All but `net` and `user` differ from the host |
| exec | `brig exec` into a running job | Commands run inside its namespaces |
| All earlier tests | Chapters 1–2 suites | Still pass |

### Hints and pitfalls

- **`/proc` before pivoting.** For now jobs still see the host's files; you're only remounting `/proc` inside the job's private mount table. Chapter 5 gives jobs their own root.
- **`CLONE_NEWPID` with `unshare` affects children only.** Using `clone3` with the flag avoids the confusion: the child is born as PID 1.
- **Init must block signals before forking,** then unblock them in the enricher, or a signal can arrive between steps and be lost.
- **Keep the init tiny and allocation-free in its loop.** It runs for the whole job.
- **Read `/proc/<pid>/status` for `NSpid`.** It shows a process's PID in each nested namespace, which helps map host PIDs to job PIDs.

### Reading for this chapter

- [Namespaces in operation](https://lwn.net/Articles/531114/), Michael Kerrisk (LWN): parts 1–4 (overview, API, PID namespaces) and part 8 (mount namespaces and shared subtrees).
- Man pages: `namespaces(7)`, `pid_namespaces(7)`, `mount_namespaces(7)`, `uts_namespaces(7)`, `cgroup_namespaces(7)`, `setns(2)`, `nsenter(1)`.
- [tini](https://github.com/krallin/tini) README: why containers need an init, explained briefly.
- Liz Rice's Containers From Scratch: watch her PID namespace and `/proc` sections, now that you've built the same thing in Zig.

### Definition of done

- [ ] Every job runs in new PID, UTS, IPC, mount and cgroup namespaces.
- [ ] brig's init reaps zombies and forwards signals.
- [ ] `brig ps` and `brig exec` work.
- [ ] All tests from Chapters 1–4 pass.
- [ ] You can explain why a bare script as PID 1 ignores `SIGTERM`.

## Chapter 5: filesystems and images

You'll give each job its own root filesystem: a shared, read-only base image stacked with a throwaway writable layer through overlayfs, then `pivot_root` into it. The job can no longer see your home directory, SSH keys or cufarr's database, and anything it writes disappears when it ends.

### What you'll have at the end

```
brig run --image python-alpine [--mount /opt/enrichers:/job:ro] [--tmp 64M] -- python3 /job/kobo_lookup.py
```

- An image store at `/var/lib/brig/images/<name>/`, each image a plain directory tree used read-only.
- Per job: an overlayfs whose lower layer is the image and whose upper layer lives on a size-limited `tmpfs`, so writes are capped and vanish afterwards.
- A minimal `/dev` (`null`, `zero`, `random`, `urandom`, `tty`, `shm`), a fresh `/proc`, a `tmpfs` at `/tmp`, and the host's `/etc/resolv.conf` bound read-only so DNS works while the network is shared.
- `--mount` for read-only bind mounts, which is how enricher code gets into the job.
- Stretch: `brig commit <job> <new-image>`, which saves a job's upper layer as a new image layer. That's how `docker build` works underneath.

### What you'll learn

- `mount(2)` in depth: bind mounts, flags (`nodev`, `nosuid`, `noexec`, `ro`), and the classic gotcha that a read-only bind mount takes two calls.
- overlayfs: lower, upper and work directories, copy-up, and whiteout files for deletions.
- `pivot_root` vs `chroot`: why `chroot` alone can be escaped, and the conditions `pivot_root` demands.
- `tmpfs` and its `size=` limit, and that `tmpfs` pages are charged to the job's cgroup memory (`shmem` in `memory.stat`).
- What a Linux userland actually needs to run a program: the dynamic loader, libc, a few `/dev` nodes, `/proc`.

### Milestones

1. **Build a first image by hand.** Download Alpine's minirootfs tarball and unpack it into `images/alpine-base/`. Make `images/python-alpine/` by copying it, then `chroot` in (with `resolv.conf` copied) and run `apk add python3 py3-requests py3-beautifulsoup4`.
   - Learn: how small a working userland is; what `apk` touches.
   - Done when: `sudo chroot images/python-alpine python3 -c 'import bs4'` works.
2. **`pivot_root` into the plain image.** In the job's mount namespace: bind-mount the image directory onto itself (so it becomes a mount point), mount `/proc`, then `pivot_root(new_root, new_root/.old)`, `chdir("/")`, and unmount `/.old` with `MNT_DETACH`.
   - Learn: why each step is needed; read `pivot_root(2)`'s list of conditions.
   - Done when: `ls /home` inside a job is empty and `cat /etc/os-release` says Alpine.
3. **overlayfs per job.** Mount a `tmpfs` (with `size=` from `--tmp`) for the job, create `upper/` and `work/` on it, then mount `overlay` with `lowerdir=<image>,upperdir=…,workdir=…` and pivot into the merged directory instead.
   - Learn: copy-up (modify a lower file, then look in `upper/`); whiteouts (delete one, then look again).
   - Done when: writes inside a job never reach the image directory, and two parallel jobs share the image without copying it.
4. **`/dev`, `/tmp` and mounts.** Mount a `tmpfs` on `/dev` and bind-mount the host's device nodes into it one by one; mount `/dev/shm` and `/tmp` as `tmpfs`; add `--mount` bind mounts with the two-step read-only remount; bind `resolv.conf` read-only. Mount everything `nosuid`, and `nodev` where possible.
   - Learn: why binding device nodes beats `mknod` (it also works rootless in Chapter 7).
   - Done when: Python enrichers run from `/job`, and `/job` can't be written.
5. **Wire it into bosun, then commit (stretch).** Add `image` and `mounts` to bosun's kind registry. For `brig commit`, keep the job's upper directory after it exits, then copy it into a new image directory that lists the base as its lower layer.
   - Learn: images as stacks of layers; why whiteouts must survive the copy.
   - Done when: bosun runs all enrichers with `--image python-alpine`.

### Tests

| Test | What the job does | Expected |
| --- | --- | --- |
| host hidden | `ls /home /root`, `cat /etc/hostname` | Empty dirs; Alpine's files, not the host's |
| writes vanish | Writes `/etc/foo`, then a second job reads it | Not found in the second job; image unchanged |
| shared base | Two jobs at once, check `du` on the image store | No copies of the image |
| tmp full | Writes past `--tmp 64M` | `ENOSPC` inside the job; host disk untouched |
| tmpfs memory | Fills `/tmp` with `--memory 128M` | Counted in `memory.stat` `shmem`; can trigger `oom` |
| ro mount | Writes into `/job` | `EROFS` |
| escape | The classic `chroot`-escape program (`mkdir` + `chroot` + `chdir("..")` loop) | Stays inside the new root |
| devices | `head -c 16 /dev/urandom`, `echo > /dev/null` | Work; no other device nodes exist |
| All earlier tests | Chapters 1–4 suites, using an image | Still pass |

### Hints and pitfalls

- **Order matters:** private propagation, then build the new root's mounts, then `pivot_root`, then unmount the old root. Mounts done after the pivot can't see host paths any more.
- **`EINVAL` from `pivot_root`** almost always means the new root isn't a mount point or something is still shared. Check `/proc/self/mountinfo` from inside the job.
- **`upperdir` and `workdir` must be on the same filesystem,** and `workdir` must be empty.
- **Read-only bind mounts take two calls:** first `MS_BIND`, then `MS_REMOUNT | MS_BIND | MS_RDONLY`. A single call silently ignores `MS_RDONLY`.
- **The J4105 is x86\_64.** Pick amd64 images and tarballs.
- **Keep the old root's lazy unmount.** Without it, the job can still reach the host through `/.old`.

### Reading for this chapter

- [Overlay Filesystem](https://docs.kernel.org/filesystems/overlayfs.html): kernel documentation, including whiteouts and copy-up.
- Man pages: `pivot_root(2)`, `mount(2)`, `umount2(2)`, `mount_namespaces(7)`, `tmpfs(5)`.
- [Namespaces in operation](https://lwn.net/Articles/531114/) parts 8 and 9: mount propagation in depth.
- Lizzie Dixon's "Linux containers in 500 lines": the mounts section and its `pivot_root` reasoning.
- Eric Chiang's "Containers from Scratch": the `chroot` part, to see why `pivot_root` replaced it.
- [Alpine Linux downloads](https://alpinelinux.org/downloads/): the minirootfs tarballs.

### Definition of done

- [ ] Every enricher runs from an image with its own root filesystem.
- [ ] Jobs can't read host files except what's explicitly mounted.
- [ ] Writes are size-limited and vanish after the job.
- [ ] All tests from Chapters 1–5 pass.
- [ ] You can explain why `chroot` is not isolation and what `pivot_root` plus the unmount adds.

## Chapter 6: brig pull (optional)

You'll write `brig-pull`, a small Go tool that downloads OCI images (the format behind "Docker images") from a registry like Docker Hub and unpacks them into brig's image store. It replaces Chapter 5's hand-built images with the thousands of images already published. Go fits here: HTTP, JSON, SHA-256, gzip and tar are all in its standard library.

### What you'll have at the end

```
brig-pull python:3.12-alpine
brig run --image python:3.12-alpine -- python3 -c 'print(1)'
```

- A content-addressed blob store: `/var/lib/brig/blobs/sha256/<hash>`, so a layer shared by several images is downloaded and stored once.
- Each image in `images/<name>/` as an ordered list of unpacked layers plus a `config.json`.
- brig stacks those layers as multiple overlayfs lower directories and honors the image's `Env`, `WorkingDir` and default `Cmd`.

### What you'll learn

- The OCI image and distribution specs: index, manifest, config and layer blobs, media types.
- **Content addressing:** naming data by its hash, verifying while streaming, deduplication for free.
- Registry token authentication (anonymous tokens for public images).
- Platform selection from a multi-architecture index.
- tar in detail, and **safe extraction**: path traversal, symlink tricks and hard links are classic attack routes.
- Translating OCI whiteouts into overlayfs whiteouts.

### Milestones

1. **Talk to the registry.** Parse a reference (`python:3.12-alpine` means `docker.io/library/python:3.12-alpine`). Get an anonymous token from Docker Hub's token service for `repository:library/python:pull`, then request the manifest with `Accept` headers for both OCI and Docker manifest types.
   - Learn: why one tag can point to an index of per-platform manifests.
   - Done when: you print the list of platforms and pick `linux/amd64`.
2. **Download blobs by digest.** Fetch the config and each layer, hashing while you write; reject and delete anything whose SHA-256 doesn't match its digest. Skip blobs already in the store.
   - Learn: streaming verification with `io.TeeReader`; atomic writes (write to a temp file, then rename).
   - Done when: a second pull of the same image downloads nothing.
3. **Unpack safely.** Extract each layer into its own directory. Reject absolute paths and any `..` that leaves the layer directory; never follow a symlink that points outside it; handle hard links within the layer only; keep permissions and ownership.
   - Learn: why archive extraction is a frequent source of security bugs.
   - Done when: the malicious-tar tests below are all rejected.
4. **Whiteouts.** In OCI layers, a deleted file shows up as `.wh.<name>`, and `.wh..wh..opq` marks a directory as replaced. overlayfs uses a different form (a 0/0 character device, and an `opaque` extended attribute on directories). Convert while unpacking. A simpler first step: flatten all layers into one directory, applying whiteouts as deletions.
   - Learn: two formats for the same idea, and why they differ.
   - Done when: a file deleted in a higher layer is absent inside the job.
5. **Run it.** Write `config.json` with the parts brig needs (`Env`, `WorkingDir`, `Cmd`, `User`), teach brig to read it, and pass multiple layers to overlayfs as a colon-separated `lowerdir` (top layer first).
   - Done when: bosun runs an enricher on `python:3.12-alpine`, pulled by `brig-pull`.

### Tests

| Test | Setup | Expected |
| --- | --- | --- |
| pull small | `brig-pull alpine:latest` | Unpacked image that runs `/bin/sh -c 'echo ok'` |
| dedupe | Pull two tags that share base layers | Shared layers stored once |
| corrupt blob | Flip a byte in a stored blob, re-verify | Detected and re-downloaded |
| traversal | A tar with `../../etc/x` | Rejected; nothing written outside |
| symlink escape | A tar with `link -> /etc`, then `link/x` | Rejected |
| whiteout | An image that deletes a file from its base | File absent in the job |
| platform | A multi-arch tag | `linux/amd64` chosen |

### Hints and pitfalls

- **Anonymous Docker Hub pulls are rate-limited.** Content addressing plus caching keeps you well under the limit; don't re-pull in loops.
- **Some newer images use zstd-compressed layers.** Go's standard library has no zstd, so start with gzip images and add a zstd library later if you need one.
- **Extract as root, run as non-root.** Ownership in layers matters once Chapter 7 maps users.
- **Use [crane](https://github.com/google/go-containerregistry) to compare.** `crane manifest` and `crane config` show what the registry returns, which helps when your parsing disagrees.

### Reading for this chapter

- [OCI image spec](https://github.com/opencontainers/image-spec): manifest, index, config, layers and the whiteout rules.
- [OCI distribution spec](https://github.com/opencontainers/distribution-spec): the registry HTTP API.
- Docker's registry token authentication docs, for how anonymous tokens are issued.
- [Overlay Filesystem](https://docs.kernel.org/filesystems/overlayfs.html): the whiteout and opaque-directory format on the overlay side.
- Go's `archive/tar`, `compress/gzip` and `crypto/sha256` package docs.
- Bocker's `pull` function: the same idea in a few lines of shell.

### Definition of done

- [ ] `brig-pull` fetches, verifies and unpacks public images.
- [ ] Layers are deduplicated across images.
- [ ] All malicious-tar tests are rejected.
- [ ] bosun runs at least one enricher on a pulled image.
- [ ] You can explain what a digest guarantees and what it doesn't.

## Chapter 7: hardening and rootless brig

You'll take away everything a job doesn't need: root's special powers (capabilities), the ability to gain privileges, dangerous syscalls, and finally root itself. At the end, brig runs as your normal user, and a job that breaks out of its sandbox is still just an unprivileged process.

### What you'll have at the end

- Jobs run as a non-root user inside the container, with **no capabilities**, `no_new_privs` set, and a **seccomp filter you wrote by hand** in BPF.
- Sensitive parts of `/proc` masked or read-only, and `rlimits` set (open files, no core dumps).
- **Rootless mode:** brig itself runs without `sudo`. A user namespace maps your user to root inside the job, and your systemd user session delegates the cgroup subtree.
- A `--seccomp-log` mode that logs instead of blocking, for finding out which syscalls an enricher really uses.

### What you'll learn

- Capabilities: the five sets (bounding, permitted, effective, inheritable, ambient) and how `execve` transforms them.
- `no_new_privs`, and why it makes setuid binaries harmless and unprivileged seccomp possible.
- **seccomp-BPF:** the `seccomp_data` struct, classic BPF instructions, checking the architecture first, and returning `EPERM` vs killing.
- **User namespaces:** `uid_map`, `gid_map`, `setgroups`, what "root in a namespace" can and can't do, and why they've been a source of kernel bugs.
- What changes when you go rootless: which mounts still work, how cgroups get delegated, and where `/etc/subuid` fits.

### Milestones

1. **Drop capabilities and privileges.** In the job's init, before running the enricher: drop every capability from the bounding set (`prctl(PR_CAPBSET_DROP, …)` for each), clear the ambient set, `setgroups`, then `setresgid` and `setresuid` to an unprivileged user from the image (default 1000). Set `PR_SET_NO_NEW_PRIVS`.
   - Learn: read `/proc/self/status` (`CapBnd`, `CapEff`, `NoNewPrivs`) before and after each step.
   - Done when: inside a job `CapEff` and `CapBnd` are all zeros, and running `su` or `ping` gains nothing.
2. **Write the seccomp filter.** Build an array of BPF instructions in Zig: load `arch` and kill the process if it isn't `AUDIT_ARCH_X86_64`; load `nr`; jump to `SECCOMP_RET_ERRNO | EPERM` for a deny list (`ptrace`, `mount`, `umount2`, `pivot_root`, `unshare`, `setns`, `keyctl`, `add_key`, `bpf`, `perf_event_open`, `userfaultfd`, `kexec_load`, `init_module`, `finit_module`, `reboot`, `swapon`, `clock_settime` and similar); otherwise allow. Install it with `seccomp(SECCOMP_SET_MODE_FILTER, …)` as the last step before `execve`.
   - Learn: why the arch check comes first, and the x32 syscall-number trick that filters must also block.
   - Done when: `unshare -U` and `mount` fail with `EPERM` inside a job, and enrichers still work.
3. **Mask `/proc` and set limits.** Bind `/dev/null` over files like `/proc/kcore` and `/proc/sched_debug`, mount `/proc/sys` read-only, set `RLIMIT_CORE` to 0 and a sensible `RLIMIT_NOFILE`.
   - Done when: `cat /proc/kcore` returns nothing and writes to `/proc/sys` fail.
4. **User namespace.** Add `CLONE_NEWUSER` to `clone3`. The child waits on a pipe while the parent writes `deny` to `/proc/<child>/setgroups`, then a one-line `uid_map` and `gid_map` mapping your user to 0 inside. Then the child continues with the other namespaces and mounts.
   - Learn: the order of operations, and why the map has to be written from outside.
   - Done when: `id` inside prints `uid=0(root)`, while on the host `ps` shows the job owned by you.
5. **Fully rootless.** Run brig as your user from a delegated user scope (`systemd-run --user --scope -p Delegate=yes`). Check which controllers your scope got in `cgroup.controllers`. overlayfs inside a user namespace works on kernel 5.11+. Stretch: use `/etc/subuid` with the `newuidmap` helper to map a whole range, so jobs can have more than one user inside.
   - Learn: what still requires privileges (some mounts, host networking changes) and how real rootless runtimes work around it.
   - Done when: every earlier test passes without `sudo`.

### Tests

| Test | What the job does | Expected |
| --- | --- | --- |
| caps | Reads `/proc/self/status` | `CapEff` and `CapBnd` all zeros, `NoNewPrivs: 1` |
| setuid | Runs a setuid binary | No privilege gained |
| ptrace | `strace ls` | `EPERM` |
| nested ns | `unshare -U true` | `EPERM` |
| mount | `mount -t tmpfs x /mnt` | `EPERM` |
| wrong arch | A 32-bit (`int 0x80`) syscall | Process killed by seccomp |
| proc mask | `cat /proc/kcore`; write to `/proc/sys/...` | Empty; write fails |
| rootless | The whole suite as a normal user | Passes |
| file owner | Job creates a file in a writable bind mount | Owned by your user on the host |
| enrichers | bosun's real enrichers | Still work under the filter |

### Hints and pitfalls

- **Order matters:** user namespace and maps first, then other namespaces and mounts, then drop capabilities, set `no_new_privs`, install seccomp, and `execve` last. seccomp blocks syscalls that brig itself still needs, so it must be the final step.
- **Return `EPERM`, not kill, for the deny list.** Programs handle an error gracefully; a killed process gives you a mystery.
- **Ubuntu 24.04 restricts unprivileged user namespaces** through AppArmor by default. If Chapter 0's `unshare` check failed, you'll need an AppArmor profile for brig or the matching sysctl.
- **Use log mode to build an allow list later.** Run each enricher with `--seccomp-log`, collect syscalls from the audit log, and you have the data for a stricter allow-list filter.
- **Don't trust that a sandbox works; test that it fails.** Each test above should fail loudly if the protection is missing.

### Reading for this chapter

- Man pages: `capabilities(7)`, `prctl(2)` (`PR_CAPBSET_DROP`, `PR_SET_NO_NEW_PRIVS`), `seccomp(2)`, `user_namespaces(7)`, `setresuid(2)`, `newuidmap(1)`.
- [Seccomp BPF](https://docs.kernel.org/userspace-api/seccomp_filter.html): kernel docs, including the BPF program format.
- [Namespaces in operation](https://lwn.net/Articles/531114/) parts 5 and 6: user namespaces.
- Lizzie Dixon's "Linux containers in 500 lines": the capabilities, seccomp and user-namespace sections, with careful reasoning on what to deny and why.
- Docker's default seccomp profile (`profiles/seccomp/default.json` in the moby repository): a real deny/allow list to compare with yours.
- [Rootless containers](https://rootlesscontaine.rs/): how rootless runtimes work and what they can't do.
- Liz Rice, *Container Security*: chapters on capabilities, seccomp and user namespaces.

### Definition of done

- [ ] Jobs have no capabilities, run as non-root, and have `no_new_privs` and seccomp enabled.
- [ ] brig runs the whole test suite without `sudo`.
- [ ] Every test in the table fails loudly if you disable the matching protection.
- [ ] You can explain the five capability sets and what `execve` does to them.

## Chapter 8: scale to zero with lookout

You'll write **lookout**, a tiny socket activator in Zig (the "Socket activator" box in the architecture diagram). It holds cufarr's port open while cufarr isn't running, starts cufarr on the first connection, and hands over the socket. cufarr shuts itself down when it's idle and has no work left. When nobody uses cufarr, the only thing in memory is lookout.

### What you'll have at the end

```
lookout --listen 127.0.0.1:8080 --wake-file /var/lib/cufarr/next-wake -- /usr/local/bin/cufarr
```

- Caddy proxies to `127.0.0.1:8080` as before. It can't tell whether cufarr is running.
- On the first connection, lookout starts cufarr and passes the listening socket as fd 3, following systemd's `LISTEN_FDS` protocol. Connections that arrive during startup wait in the kernel's backlog, so none are lost.
- cufarr exits when there have been no requests for N minutes **and** bosun has no ready or running jobs.
- Before exiting, cufarr writes the time its next scheduled retry is due to the wake file; lookout starts it again at that time, even without a request.
- Crash-loop protection: if cufarr keeps dying right after starting, lookout backs off.

### What you'll learn

- Sockets from the bottom: `socket`, `bind`, `listen`, the accept backlog, and why a listening socket can outlive the process that will `accept` on it.
- `epoll`: level- vs edge-triggered events, adding and removing fds, combining sockets with `timerfd` and pidfds in one loop.
- Passing file descriptors to a child: `dup2` onto fd 3, clearing close-on-exec, and the `LISTEN_FDS` / `LISTEN_PID` environment contract.
- Graceful shutdown in Go: `http.Server.Shutdown`, draining in-flight requests and finishing jobs.
- Measuring what you built: cold-start latency and idle memory.

### Milestones

1. **Listen without accepting.** lookout creates the socket, binds, listens with a reasonable backlog, and waits in `epoll` for the socket to become readable. It never calls `accept`.
   - Learn: what "readable" means for a listening socket; where waiting connections live.
   - Done when: `curl` connects and hangs (nobody answers yet), and `ss -ltn` shows the queued connection.
2. **Spawn and hand over.** On readiness, `fork`; in the child, `dup2` the socket onto fd 3, set `LISTEN_FDS=1` and `LISTEN_PID` to the child's own PID (known only after the fork), then `exec` cufarr. The parent removes the socket from `epoll` and watches the child's pidfd instead; when the child exits, it adds the socket back.
   - Learn: why `LISTEN_PID` exists (so a grandchild doesn't wrongly grab the fds).
   - Done when: the first `curl` gets a real response from cufarr.
3. **cufarr accepts the socket.** In Go: if `LISTEN_FDS` is `1` and `LISTEN_PID` matches `os.Getpid()`, wrap fd 3 with `os.NewFile` and `net.FileListener`; otherwise listen normally, so local development still works.
   - Done when: cufarr runs both under lookout and standalone.
4. **Idle exit.** Track in-flight requests and the last request time with a small middleware. A background loop checks: no requests for N minutes, nothing in flight, no ready jobs (`run_after <= now`) and nothing running. Then it calls `http.Server.Shutdown`, writes the earliest future `run_after` to the wake file, and exits `0`.
   - Learn: the race between "decide to exit" and "a request arrives"; why the backlog makes it safe (a request that arrives after shutdown waits for the next start).
   - Done when: cufarr exits after the idle period but never with jobs pending.
5. **Wake-ups and crash loops.** lookout reads the wake file when cufarr exits and arms a `timerfd` for that time. Track recent exits; if cufarr fails several times within a short window, wait longer before restarting.
   - Done when: a link saved just before shutdown, whose job is retried later, completes without any request arriving.

### Tests

| Test | Setup | Expected |
| --- | --- | --- |
| idle memory | cufarr stopped | Only lookout is resident; measure its RSS |
| cold start | First request after idle | Answered; record the latency |
| burst during start | 50 parallel requests while cold | All answered, none refused |
| idle exit | No traffic for N minutes, empty queue | cufarr exits `0` |
| busy | No traffic but a job running | cufarr stays up until it finishes |
| scheduled wake | Job with `run_after` 5 minutes ahead, cufarr idle-exits | lookout restarts cufarr on time; job runs |
| crash loop | cufarr built to crash on start | lookout backs off, doesn't spin the CPU |
| standalone | Run cufarr without lookout | Listens on its own |

### Hints and pitfalls

- **Don't accept in lookout.** If lookout accepted a connection, it would have to proxy it. Leaving connections in the backlog lets the kernel hand them to cufarr directly.
- **Clear close-on-exec on fd 3 only.** `dup2` does this for you; everything else in lookout should stay `O_CLOEXEC`.
- **Use level-triggered `epoll` for the listen socket.** Edge-triggered mode can miss the case where connections are already queued when you re-add it.
- **systemd does all of this** with a `.socket` unit. Building it yourself is the lesson; afterwards, compare your behavior with systemd's to spot gaps.
- **The cold start should be small.** A Go binary with SQLite usually starts fast; if it's slow, profile startup (migrations, cache warming) before blaming lookout.

### Reading for this chapter

- [systemd for Developers I](https://0pointer.de/blog/projects/socket-activation.html), Lennart Poettering: the idea and the protocol.
- Man pages: `sd_listen_fds(3)`, `systemd.socket(5)`, `socket(7)`, `listen(2)`, `epoll(7)`, `timerfd_create(2)`.
- [Beej's Guide to Network Programming](https://beej.us/guide/bgnet/): sockets, if they're new to you.
- TLPI chapters 56–61 (sockets) and 63 (`epoll`).
- Go docs: `net.FileListener` and `http.Server.Shutdown`.

### Definition of done

- [ ] With no traffic and no pending work, only lookout is running.
- [ ] The first request after idle succeeds, and bursts during startup aren't dropped.
- [ ] Scheduled retries run on time without incoming requests.
- [ ] You've measured and written down lookout's idle RSS and cufarr's cold-start latency.
- [ ] You can explain why no connection is lost between cufarr deciding to exit and lookout starting it again.

## Chapter 9: networking (optional)

You'll give each job its own network namespace, connected to the internet through a bridge and NAT, and blocked from your home network. A compromised or buggy crawler can then reach Kobo and Goodreads, but not your router's admin page, your NAS or cufarr's own ports. Everything is configured by speaking netlink directly from Zig, the same protocol the `ip` command uses.

### What you'll have at the end

```
brig run --net none   -- …   # loopback only
brig run --net bridge -- …   # internet through NAT, LAN blocked
brig run --net host   -- …   # today's behavior, kept for debugging
```

- A bridge `brig0` on the host with a small private subnet (for example `10.88.0.0/24`), created once by brig.
- Per job: a veth pair, one end on the bridge, the other moved into the job's namespace as `eth0`, with an address from a tiny file-backed address allocator and a default route.
- NAT for outbound traffic and firewall rules that drop job traffic to private LAN ranges and between jobs, with DNS allowed.
- bosun's kind registry gains a `net` setting; enrichers that don't need the network get `none`.

### What you'll learn

- Network namespaces: what's per-namespace (interfaces, routes, firewall rules, `/proc/net`) and the loopback interface that starts down.
- **netlink:** the `nlmsghdr` header, attributes as nested type-length-value records with 4-byte alignment, request flags, ACKs and error replies.
- veth pairs, Linux bridges, IP addresses and routes, set from code.
- How NAT works: masquerading, connection tracking, IP forwarding.
- nftables basics: tables, chains, hooks and rules.
- Cleanup by design: destroying a network namespace destroys its veth end, which removes the pair.

### Milestones

1. **`--net none`.** Add `CLONE_NEWNET` and bring up `lo` from inside the job. Use netlink right away (`RTM_NEWLINK` with `IFF_UP` on interface index 1) rather than shelling out.
   - Learn: your first netlink request and ACK.
   - Done when: `curl example.com` fails inside the job and `ping 127.0.0.1` works.
2. **Create the bridge and a veth pair.** From brig (on the host side): create `brig0` if missing (link kind `bridge`), give it the subnet's first address, bring it up. Per job: create a veth pair (kind `veth` with a nested peer), attach one end to `brig0` (`IFLA_MASTER`), and move the other into the job's namespace (`IFLA_NET_NS_FD`).
   - Learn: nested attributes; reading the replies.
   - Done when: `ip link` on the host shows the veth on `brig0`, and inside the job `ip link` shows `eth0`.
3. **Addresses and routes.** Inside the job (the child waits on a pipe until the parent has moved the interface in), rename the interface to `eth0`, assign its address (`RTM_NEWADDR`), bring it up, and add a default route through the bridge address (`RTM_NEWROUTE`). Allocate addresses from a small file under `/var/lib/brig`, protected by a file lock.
   - Done when: the job can ping the bridge address.
4. **NAT and the LAN block.** Enable `net.ipv4.ip_forward`. Apply an nftables ruleset (shelling out to `nft` with a ruleset file is fine): masquerade traffic from the subnet going out the main interface; in the forward chain, drop traffic from `brig0` to `192.168.0.0/16`, `172.16.0.0/12`, `10.0.0.0/8` and to the host itself, except DNS to your resolver; drop traffic between jobs.
   - Learn: hooks and chain priorities; why the order of rules matters.
   - Done when: `curl example.com` works inside a job, and your router's address doesn't respond.
5. **Cleanup and bosun.** Release the job's address when the job ends; confirm the veth vanished with the namespace. Add `net` to bosun's registry and default it to `none`.
   - Done when: 100 jobs in a row leave no stray interfaces and no leaked addresses.

### Tests

| Test | Mode | Expected |
| --- | --- | --- |
| none | `--net none` | No external access; loopback works |
| internet | `--net bridge` | `curl https://example.com` works |
| LAN blocked | `--net bridge` | Router, NAS and host ports unreachable; DNS works |
| job to job | Two bridge jobs | Can't reach each other |
| cleanup | 100 sequential jobs | No leftover veths; addresses reused |
| parallel | 5 jobs at once | Unique addresses, all online |
| host | `--net host` | Same as before this chapter |

### Hints and pitfalls

- **Watch what `ip` sends.** `strace -e trace=sendmsg,recvmsg -s 2000 ip link add …` shows real netlink messages to compare byte for byte with yours. The `nlmon` kernel module lets you capture netlink traffic in Wireshark.
- **Always request ACKs** (`NLM_F_ACK`) and check the error code in every reply. Netlink fails silently otherwise.
- **Attribute alignment** is the most common bug: every attribute's length is padded to 4 bytes, and nested lengths must include the padding of their children.
- **Your host firewall may interfere.** If the Wyse runs ufw or Docker, their forward-chain rules can drop or allow traffic before yours. Check `nft list ruleset` to see everything.
- **Skip IPv6 at first.** Disable it inside jobs and add it later if needed.
- **Rootless networking is different.** Creating veths on the host needs privileges, so rootless runtimes use user-space tools such as slirp4netns or pasta. Decide whether `--net bridge` runs as root or whether rootless jobs get `none` or `host` only.

### Reading for this chapter

- Man pages: `network_namespaces(7)`, `netlink(7)`, `rtnetlink(7)`, `veth(4)`, `ip-link(8)`, `ip-netns(8)`.
- [Introduction to Netlink](https://docs.kernel.org/userspace-api/netlink/intro.html): kernel docs on the message format and conventions.
- [Namespaces in operation](https://lwn.net/Articles/531114/), part 7: network namespaces.
- [nftables wiki](https://wiki.nftables.org/): quick start, NAT and the families and hooks pages.
- Julia Evans's networking zines, for a friendly overview of NAT, routing and DNS.
- Note that Lizzie Dixon's container leaves networking out, so you're past the classic tutorials here.

### Definition of done

- [ ] Jobs run with `none`, `bridge` or `host` networking, chosen per enricher kind.
- [ ] Bridge jobs reach the internet but not the LAN, the host or each other.
- [ ] All network setup is done through netlink from Zig (nftables via `nft` is fine).
- [ ] No interfaces or addresses leak after many runs.
- [ ] You can draw the path of one HTTP request from a job to Kobo and back, naming every hop and table.

## Chapter 10: a WASM backend (optional)

You'll come back to where this started: brig gains a second way to run a job, executing a `.wasm` enricher with an embedded Wasmtime instead of `execve`. It keeps the same JSON contract, so bosun doesn't notice the difference. The WASM module gets exactly one capability you define yourself, a `fetch` host function with a domain allow list, and you'll measure how it compares with a Python enricher in a container.

### What you'll have at the end

```
brig run --wasm /opt/enrichers/jsonld.wasm --allow-fetch kobo.com,openlibrary.org
```

- brig links Wasmtime's C API. In the job's child process, after cgroups, namespaces and seccomp are set up, brig loads the module instead of calling `execve`, so all the Linux isolation from earlier chapters still applies around the WASM sandbox.
- The guest gets WASI for stdin, stdout and stderr only: no preopened directories, no environment.
- One custom import, `cufarr.fetch(url, out) -> status`, implemented by brig: it checks the URL's domain against `--allow-fetch`, performs the request, and copies the body into the guest's memory.
- CPU time is bounded with Wasmtime's epoch interruption, memory with a store limiter; both map onto the report's `timeout` and `oom` statuses.
- An enricher written in Zig, compiled to `wasm32-wasi`, that extracts JSON-LD from a page.
- A short write-up comparing the WASM and container paths on the Wyse.

### What you'll learn

- Embedding a runtime from the host side: engine, store, module, linker, instance, and how imports are satisfied. This is the other half of what you studied about modules, imports and exports.
- Reading and writing guest linear memory safely from the host (pointer + length, with bounds checks).
- Capability-based design: a guest can only do what its imports allow.
- Interrupting guest code: epochs vs fuel, and how a host stops an infinite loop without killing the process.
- An informed answer to the question this project began with: where WASM beats containers on this hardware, and where it doesn't.

### Milestones

1. **Link Wasmtime and run hello world.** Download the prebuilt C API release for x86\_64 Linux, link it from `build.zig`, import `wasmtime.h` with `@cImport`, and run a WASI "hello" module with stdout inherited.
   - Learn: Zig's C interop; the engine/store/module lifecycle.
   - Done when: `brig run --wasm hello.wasm` prints through the normal report.
2. **Plug into brig's child.** Make WASM an alternative to `execve` at the very end of the child setup. stdin and stdout are already the job pipes, so WASI's inherited stdio carries the job JSON in and the result out.
   - Done when: Chapter 1's echo test passes with a WASM echo module.
3. **Write the `fetch` host function.** Define it in the linker under module `cufarr`. Validate the guest's pointers and lengths against its memory size, check the domain, fetch with Zig's HTTP client, and copy the body into a buffer the guest provides, returning the length or a negative error code.
   - Learn: the trust boundary: everything the guest passes is untrusted.
   - Done when: an allowed domain returns HTML to the guest and any other domain returns an error.
4. **Limits.** Enable epoch interruption, set a deadline, and have brig's timer advance the epoch, so a guest stuck in a loop traps cleanly; report it as `timeout`. Add a store limiter capping linear memory growth; report refused growth as `oom`.
   - Learn: why epochs are cheaper than fuel, and what each guarantees.
   - Done when: the loop and memory tests below pass.
5. **The Zig guest and the comparison.** Write the JSON-LD enricher in Zig for `wasm32-wasi`, declaring the import as `extern "cufarr" fn fetch(…)`. Run it and the equivalent Python enricher 50 times each and record, for each: cold-start time, `memory_peak_bytes`, CPU time and binary or image size.
   - Done when: the comparison is written into this doc, with your conclusion.

### Tests

| Test | Guest behavior | Expected |
| --- | --- | --- |
| contract | Same input as the Python JSON-LD enricher | Same result JSON, same report shape |
| loop | `while (true) {}` | `timeout`; brig stays healthy |
| memory | Grows memory past the limit | `oom` |
| fetch denied | Fetches a domain not on the list | Error returned to the guest, no request made |
| bad pointers | Passes an out-of-range pointer to `fetch` | Rejected by the host, no crash |
| no files | Tries to open `/etc/passwd` through WASI | Fails: nothing is preopened |
| inside the sandbox | Run with Chapters 2–7 enabled | Works under cgroups, namespaces and seccomp |

### Hints and pitfalls

- **Check the C API names against your Wasmtime version.** The header changes between releases; read `wasmtime.h` and the C examples in the Wasmtime repository rather than relying on memory or tutorials.
- **Stick to core modules and WASI preview 1 at first.** Component-model and WASI 0.2 support in the C API is newer and less complete; custom host imports give you the networking you need without it.
- **Seccomp and the JIT:** Wasmtime compiles to machine code, so it needs `mmap` and `mprotect`. Your Chapter 7 deny list doesn't block those, but a future allow list must include them.
- **Zig's HTTP client changed in 0.16** (it now takes an `io`). Read its current docs before writing `fetch`.
- **Be fair in the comparison.** Measure cold starts and peaks the same way for both paths, and include the cost of loading Wasmtime itself.

### Reading for this chapter

- [Wasmtime documentation](https://docs.wasmtime.dev/): the C API section, epoch interruption and resource limits.
- The C examples in the [Wasmtime repository](https://github.com/bytecodealliance/wasmtime) (`examples/`): hello, WASI, linking, interrupting.
- The WASI preview 1 documents in the [WASI repository](https://github.com/WebAssembly/WASI).
- Zig's language reference on the `wasm32-wasi` target and `extern` functions.
- Your own October chats on WebAssembly imports, exports and runtimes: this chapter is the host side of the same ideas.

### Definition of done

- [ ] bosun can run a WASM enricher and a container enricher side by side, with no code change in bosun.
- [ ] The guest's only way out is `fetch`, and it's restricted to listed domains.
- [ ] Infinite loops and memory blow-ups end as `timeout` and `oom`.
- [ ] Your comparison of the two paths is written down, with a verdict on when each fits cufarr.
