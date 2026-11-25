const std = @import("std");
const mem = std.mem;
const linux = std.os.linux;

const base_dir = "/var/lib/brig";
const images_dir = "/var/lib/brig/images";
const containers_dir = "/var/lib/brig/containers";

const ArgsError = error{ TooFewArgs, UnknownCommand };

pub fn main(init: std.process.Init) !void {
    // check the args vector, validate its length, the command, etc
    const vector = init.minimal.args.vector;
    if (vector.len < 3) return ArgsError.TooFewArgs;
    if (!mem.eql(u8, mem.span(vector[1]), "run")) return ArgsError.UnknownCommand;

    // build container base dir and rootfs
    const allocator = init.arena.allocator();
    const container_dirs = try buildContainerDirs(init.io, allocator);

    // create the container's base dir
    const basedir_mkdir_rc = linux.mkdir(container_dirs.basedir, 0o755);
    try check(basedir_mkdir_rc, error.MkdirFailed);

    // remove base dir
    defer spawn(&.{ "/bin/rm", "-rf", container_dirs.basedir }) catch |err| {
        std.debug.print("cleanup failed: {t}\n", .{err});
    };

    // create the container's rootfs
    const rootfs_mkdir_rc = linux.mkdir(container_dirs.rootfs, 0o755);
    try check(rootfs_mkdir_rc, error.MkdirFailed);

    // add the image
    const tar_argv = [_:null]?[*:0]const u8{ "/bin/tar", "-xzf", images_dir ++ "/alpine.tar.gz", "-C", container_dirs.rootfs };
    try spawn(&tar_argv);

    // create the child process, validate the return code
    const rc = linux.fork();
    try check(rc, error.ForkFailed);

    const pid: linux.pid_t = @intCast(rc);

    if (pid == 0) {
        std.debug.print("inside child \n", .{});

        // build the params for execing
        const child_args = vector[2..];
        const path = child_args[0];
        const argv: [*:null]const ?[*:0]const u8 = @ptrCast(child_args);
        const envp = init.minimal.environ.block.slice.ptr;

        // child doesn't have to send the failure back up through `main`
        // so it needs to catch it and exit, nothing left to do
        changeRoot(container_dirs.rootfs.ptr) catch linux.exit(125);

        // replace the (child)process by executing the program at path
        const exec_rc = linux.execve(path, argv, envp);
        const err = linux.errno(exec_rc);
        std.debug.print("err: {t} \n", .{err});

        linux.exit(127);
    } else {
        var status: i32 = undefined;
        _ = linux.waitpid(pid, &status, 0);
        const s: u32 = @bitCast(status);

        if (linux.W.IFEXITED(s)) {
            std.debug.print("child exited {d}\n", .{linux.W.EXITSTATUS(s)});
        } else if (linux.W.IFSIGNALED(s)) {
            std.debug.print("child signaled {d}\n", .{linux.W.TERMSIG(s)});
        }
    }
}

fn spawn(argv: [*:null]const ?[*:0]const u8) !void {
    // [_:null]?[*:0]const u8{ "/bin/tar", "-xzf", ..., container_path }
    // const tar_argv =
    //     [_:null]?[*:0]const u8{ "/bin/tar", "-xzf", images_dir ++ "/alpine.tar.gz", "-C", container_path };
    // - fork
    // - exec

    const path = argv[0] orelse return error.EmptyArgv;

    const rc = linux.fork();
    try check(rc, error.ForkFailed);

    const pid: linux.pid_t = @intCast(rc);

    if (pid == 0) {
        const exec_rc = linux.execve(path, argv, &[_:null]?[*:0]const u8{});

        const err = linux.errno(exec_rc);
        std.debug.print("err: {t} \n", .{err});

        linux.exit(127);
    } else {
        var status: i32 = undefined;
        _ = linux.waitpid(pid, &status, 0);
        const s: u32 = @bitCast(status);

        if (linux.W.IFEXITED(s)) {
            std.debug.print("spawn, child exited {d}\n", .{linux.W.EXITSTATUS(s)});
        } else if (linux.W.IFSIGNALED(s)) {
            std.debug.print("spawn, child signaled {d}\n", .{linux.W.TERMSIG(s)});
        }
    }
}

fn changeRoot(path: [*:0]const u8) !void {
    std.debug.print("path {s} \n", .{path});
    // chroot into images_dir
    // then make sure cwd points at that, so you have to cd into it

    // create the container
    // extract rootfs to the container, tar xvf alpine.tar.gz container_path
    // chroot into that new path, cd as well so cwd points to new root
    // run the container's command(eg: /bin/echo hello zig)

    const rc = linux.chroot(path);
    // const rc = linux.chroot("/var/lib/brig/containers/01/rootfs");
    // const rc = linux.chroot("/var/lib/brig/containers/nothing");
    try check(rc, error.ChrootFailed);

    const chdir_rc = linux.chdir("/");
    try check(chdir_rc, error.ChdirFailed);
}

fn check(rc: usize, comptime fail: anytype) @TypeOf(fail)!void {
    const err = linux.errno(rc);
    if (err != .SUCCESS) {
        std.debug.print("{t}: {t}\n", .{ fail, err });
        return fail;
    }
}

fn generateRandomId(io: std.Io) ![64]u8 {
    while (true) {
        var bytes: [32]u8 = undefined;
        try io.randomSecure(&bytes);
        const id = std.fmt.bytesToHex(bytes, .lower);

        // Docker rejects IDs whose 12-char short form is all digits
        if (std.mem.findNone(u8, id[0..12], "0123456789") == null) continue;
        return id;
    }
}

fn buildContainerDirs(io: std.Io, allocator: std.mem.Allocator) !struct { basedir: [:0]u8, rootfs: [:0]u8 } {
    const id = try generateRandomId(io);
    const dir = try allocator.printSentinel(containers_dir ++ "/{s}", .{id}, 0);
    const rootfs = try allocator.printSentinel("{s}/rootfs", .{dir}, 0);
    return .{ .basedir = dir, .rootfs = rootfs };
}
