const std = @import("std");
const DateTime = @import("datetime.zig");

/// Opens a directory at "~/.config/systemd/user". The directory is a system resource that remains
/// open until `close` is called on the result.
fn get_systemd_user_dir(allocator: std.mem.Allocator) !std.fs.Dir {
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    const home_path = env_map.get("HOME") orelse return error.HomeEnvNotSet;
    const systemd_user_sub_path = ".config/systemd/user";

    var home_dir = try std.fs.openDirAbsolute(home_path, .{});
    defer home_dir.close();

    try home_dir.makePath(systemd_user_sub_path);

    const systemd_user_path = try std.fs.path.join(allocator, &.{ home_path, systemd_user_sub_path });
    defer allocator.free(systemd_user_path);

    return try std.fs.openDirAbsolute(systemd_user_path, .{});
}

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{}){};
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var systemd_user_dir = try get_systemd_user_dir(allocator);
    defer systemd_user_dir.close();

    var arg_iterator = try std.process.argsWithAllocator(allocator);
    defer arg_iterator.deinit();

    _ = arg_iterator.skip();

    const time = arg_iterator.next() orelse return error.TimeArgMissing;

    std.debug.assert(time.len == 5);
    std.debug.assert(time[2] == ':');

    const hour = try std.fmt.parseInt(u8, time[0..2], 10);
    const minute = try std.fmt.parseInt(u8, time[3..5], 10);

    std.debug.assert(hour >= 0 and hour < 24);
    std.debug.assert(minute >= 0 and minute < 60);

    inline for (&.{ "service", "timer" }) |format| {
        if (systemd_user_dir.deleteFile("off-time." ++ format)) {} else |err| {
            if (err != error.FileNotFound) return err;
        }
    }

    const now = try DateTime.now(allocator);

    const datetime: DateTime = blk: {
        const is_tomorrow = sub_blk: {
            const input_time: u32 = @as(u32, @intCast(hour)) * 60 + minute;
            const now_time: u32 = @as(u32, @intCast(now.hour)) * 60 + now.minute;
            break :sub_blk input_time < now_time;
        };
        var temp = now;
        if (is_tomorrow) temp = try DateTime.tomorrow(allocator);
        temp.hour = hour;
        temp.minute = minute;
        break :blk temp;
    };

    std.debug.print("{any}\n", .{datetime});

    {
        var file = try systemd_user_dir.createFile("off-time.service", .{});
        defer file.close();
        const data = try std.fmt.allocPrint(
            allocator,
            @embedFile("service.service"),
            .{ "suspend", "suspend" },
        );
        defer allocator.free(data);
        try file.writeAll(data);
    }

    {
        var file = try systemd_user_dir.createFile("off-time.timer", .{});
        defer file.close();

        const datetime_string = try datetime.to_string(allocator);
        defer allocator.free(datetime_string);

        const data = try std.fmt.allocPrint(
            allocator,
            @embedFile("timer.timer"),
            .{datetime_string},
        );
        defer allocator.free(data);
        try file.writeAll(data);
    }

    {
        const commands: [3][]const []const u8 = .{
            &.{ "systemctl", "--user", "disable", "off-time.timer" },
            &.{ "systemctl", "--user", "daemon-reload" },
            &.{ "systemctl", "--user", "enable", "--now", "off-time.timer" },
        };

        inline for (commands) |argv| {
            const child = try std.process.Child.run(.{ .allocator = allocator, .argv = argv });
            defer allocator.free(child.stdout);
            defer allocator.free(child.stderr);
        }
    }

    // inline for (&.{ "hibernate", "poweroff", "suspend" }) |service| {
    //     if (systemd_user_dir.access(service ++ ".service", .{ .mode = .write_only })) {} else |err| {
    //         if (err == error.FileNotFound) {
    //             var file = try systemd_user_dir.createFile("off-time-" ++ service ++ ".service", .{});
    //             defer file.close();
    //             try file.writeAll(@embedFile(service ++ ".service"));
    //         } else return err;
    //     }
    // }

    // ~/.config/systemd/user/

    // parse current command
    // - turn on + time (00:00 format) + type (suspend | poweroff | hibernate (suspend is default))
    // - show (or nothing)
    // - turn off
}
