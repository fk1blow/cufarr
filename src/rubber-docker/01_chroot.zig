const std = @import("std");
const mem = std.mem;
const linux = std.os.linux;

const base_dir = "/var/lib/cufarr";
const images_dir = "/var/lib/cufarr/images";
const containers_dir = "/var/lib/cufarr/containers";

const ArgsError = error{ TooFewArgs, UnknownCommand };

pub fn main(init: std.process.Init.Minimal) !void {
    // get the args vector, validate its length, the command, etc
    const vector = init.args.vector;
    if (vector.len < 3) {
        return ArgsError.TooFewArgs;
    }
    if (!mem.eql(u8, mem.span(vector[1]), "run")) return ArgsError.UnknownCommand;

    // create the child process, validate the return code
    const rc = linux.fork();
    if (linux.errno(rc) != .SUCCESS) return error.ForkFailed;

    const pid: linux.pid_t = @intCast(rc);

    if (pid == 0) {
        std.debug.print("inside child \n", .{});

        // build the params for execing
        const child_args = vector[2..];
        const path = child_args[0];
        const argv: [*:null]const ?[*:0]const u8 = @ptrCast(child_args);
        const envp = init.environ.block.slice.ptr;

        // TODO the child might return the error
        try changeRoot();

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

fn changeRoot() !void {
    // chroot into images_dir
    // then make sure cwd points at that, so you have to cd into it

    // create the container
    // extract rootfs to the container, tar xvf alpine.tar.gz container_path
    // chroot into that new path, cd as well so cwd points to new root
    // run the container's command(eg: /bin/echo hello zig)

    // pattern:
    // invoke
    // get error
    // if error, print, return
    //
    // const rc = linux.chroot("/var/lib/brig/containers/01/rootfs");
    const rc = linux.chroot("/var/lib/brig/containers/nothing");
    const err = linux.errno(rc);
    if (err != .SUCCESS) {
        std.debug.print("chroot err: {t} \n", .{err});
        return error.ChrootFailed;
    }

    // pattern:
    // invoke
    // get error
    // if error, print, return
    //
    const chdir_rc = linux.chdir("/");
    const err_chdir = linux.errno(chdir_rc);
    if (err_chdir != .SUCCESS) {
        std.debug.print("chdir err: {t} \n", .{err_chdir});
        return error.ChdirFailed;
    }
}
