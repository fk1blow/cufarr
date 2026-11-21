const std = @import("std");
const mem = std.mem;
const linux = std.os.linux;

const ArgsError = error{ TooFewArgs, UnknownCommand };

pub fn main(init: std.process.Init.Minimal) !void {
    // what the args?:
    //
    // arg[0] = /Users/dragostudorache/.cache/zig/o/5293685f780fbac06b5d3f81a458aa75/00_fork_exec
    // arg[1] = run
    // arg[2] = /bin/echo
    // arg[3] = hello zig
    //
    // std.debug.print("coool {s} \n", .{f});
    //
    for (init.args.vector, 0..) |arg, i| {
        std.debug.print("arg[{d}] = {s} \n", .{ i, arg });
    }

    const vector = init.args.vector;
    if (vector.len < 3) {
        return ArgsError.TooFewArgs;
    }

    if (!mem.eql(u8, mem.span(vector[1]), "run")) return ArgsError.UnknownCommand;

    const rc = linux.fork();
    if (linux.errno(rc) != .SUCCESS) return error.ForkFailed;

    const pid: linux.pid_t = @intCast(rc);

    if (pid == 0) {
        std.debug.print("inside child \n", .{});

        const child_args = vector[2..];
        const path = child_args[0];
        const argv: [*:null]const ?[*:0]const u8 = @ptrCast(child_args);
        const envp = init.environ.block.slice.ptr;

        const exec_rc = linux.execve(path, argv, envp);
        const err = linux.errno(exec_rc);
        std.debug.print("err: {t} \n", .{err});

        linux.exit(127);
    } else {
        var status: i32 = undefined;
        _ = linux.waitpid(pid, &status, 0);
        const s: u32 = @bitCast(status);

        if (linux.W.IFEXITED(s)) {
            std.debug.print("child exited with {d}\n", .{linux.W.EXITSTATUS(s)});
        } else if (linux.W.IFSIGNALED(s)) {
            std.debug.print("child signaled {d}\n", .{linux.W.TERMSIG(s)});
        }
    }
}
