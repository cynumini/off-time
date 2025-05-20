const std = @import("std");
const skn = @import("sakana");
const rl = skn.raylib;

var main_allocator: std.mem.Allocator = undefined;
var hour: u8 = 0;
var minute: u8 = 0;
var systemd_user_dir: std.fs.Dir = undefined;
var enabled = false;
var real_enabled = false;
var end = false;
var toggle_button: *skn.UI.Button = undefined;
var mutex = std.Thread.Mutex{};

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

fn generateNumbers(
    step: comptime_int,
    max: comptime_int,
    padding: comptime_int,
) [@divExact(max, step)][]const u8 {
    const len = @divExact(max, step);
    var array: [len][]const u8 = undefined;
    inline for (0..len) |i| {
        const fmt = std.fmt.comptimePrint("{{:0>{}}}", .{padding});
        array[i] = std.fmt.comptimePrint(fmt, .{i * step});
    }
    return array;
}

pub fn reflectEnabled() void {
    if (enabled) {
        toggle_button.background = rl.getColor(0x9ace87ff);
        toggle_button.text = "Turn off";
    } else {
        toggle_button.background = rl.getColor(0x8c3744ff);
        toggle_button.text = "Turn on";
    }
}

pub fn onButtonClick(_: *skn.UI.Button) !void {
    enabled = !enabled;
    reflectEnabled();
}

pub fn onComboBoxIndexChanged(_: *skn.UI.ComboBox) !void {
    enabled = false;
    reflectEnabled();
}

pub fn changeTimerState(enable: bool) !void {
    std.debug.print("Start {}\n", .{enable});
    const now = try skn.DateTime.now(main_allocator);

    const datetime: skn.DateTime = blk: {
        const is_tomorrow = sub_blk: {
            const input_time: u32 = @as(u32, @intCast(hour)) * 60 + minute;
            const now_time: u32 = @as(u32, @intCast(now.hour)) * 60 + now.minute;
            break :sub_blk input_time < now_time;
        };
        var temp = now;
        if (is_tomorrow) temp = try skn.DateTime.tomorrow(main_allocator);
        temp.hour = hour;
        temp.minute = minute;
        if (!enable) {
            temp.year -= 1;
        }
        break :blk temp;
    };

    {
        var file = try systemd_user_dir.createFile("off-time.service", .{});
        defer file.close();
        const data = try std.fmt.allocPrint(
            main_allocator,
            @embedFile("service.service"),
            .{ "suspend", "suspend" },
        );
        defer main_allocator.free(data);
        try file.writeAll(data);
    }

    {
        var file = try systemd_user_dir.createFile("off-time.timer", .{});
        defer file.close();

        const datetime_string = try datetime.to_string(main_allocator);
        defer main_allocator.free(datetime_string);

        const data = try std.fmt.allocPrint(
            main_allocator,
            @embedFile("timer.timer"),
            .{datetime_string},
        );
        defer main_allocator.free(data);
        try file.writeAll(data);
    }

    const commands: [3][]const []const u8 = .{
        &.{ "systemctl", "--user", "daemon-reload" },
        &.{ "systemctl", "--user", "enable", "--now", "off-time.timer" },
        &.{ "systemctl", "--user", "restart", "off-time.timer" },
    };

    inline for (commands) |argv| {
        const child = try std.process.Child.run(.{ .allocator = main_allocator, .argv = argv });
        defer main_allocator.free(child.stdout);
        defer main_allocator.free(child.stderr);
    }
    real_enabled = enable;
    std.debug.print("End {}\n", .{enable});
}

pub fn loadData() !void {
    var file = systemd_user_dir.openFile("off-time.timer", .{}) catch |err| if (err == error.FileNotFound) return else return err;
    defer file.close();

    var buffer: [4096]u8 = undefined;

    const size = try file.readAll(&buffer);

    const index = std.mem.indexOf(u8, buffer[0..size], "OnCalendar") orelse return;

    const datetime_str = buffer[index + 11 .. index + 11 + 16];
    const datetime = try skn.DateTime.from_string(datetime_str);
    const now = try skn.DateTime.now(main_allocator);

    if (datetime.compare(&now) == .gt) enabled = true;
    real_enabled = enabled;

    hour = datetime.hour;
    minute = datetime.minute;
}

pub fn reactOnChange() !void {
    while (!end) {
        if (enabled != real_enabled) {
            mutex.lock();
            try changeTimerState(enabled);
            mutex.unlock();
        }
    }
    if (enabled != real_enabled) {
        mutex.lock();
        try changeTimerState(enabled);
        mutex.unlock();
    }
}

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{}){};
    defer _ = debug_allocator.deinit();
    main_allocator = debug_allocator.allocator();

    systemd_user_dir = try get_systemd_user_dir(main_allocator);
    defer systemd_user_dir.close();

    try loadData();

    const thread = try std.Thread.spawn(.{}, reactOnChange, .{});
    defer thread.detach();

    rl.initWindow(320, 320, "off-time");
    defer rl.closeWindow();

    var ui = try skn.UI.init(main_allocator);
    defer ui.deinit();

    const padding = 8;
    const width = @divExact(320 - padding * 3, 2);

    const hours = generateNumbers(1, 24, 2);
    const hours_combo_box = try ui.addComboBox(.{ .x = padding, .y = padding, .width = width, .height = width }, &hours, onComboBoxIndexChanged);
    hours_combo_box.index = hour;

    const minutes = generateNumbers(5, 60, 2);
    const minutes_combo_box = try ui.addComboBox(.{ .x = hours_combo_box.rect.width + padding * 2, .y = padding, .width = width, .height = width }, &minutes, onComboBoxIndexChanged);
    minutes_combo_box.index = @divExact(minute, 5);

    toggle_button = try ui.addButton(.{
        .x = padding,
        .y = hours_combo_box.rect.height + padding * 2,
        .width = 320 - padding * 2,
        .height = width,
    }, "Turn on", onButtonClick);

    reflectEnabled();

    rl.setTargetFPS(60);

    while (!rl.windowShouldClose()) {
        try ui.update();
        hour = @intCast(hours_combo_box.index);
        minute = @intCast(minutes_combo_box.index * 5);

        rl.beginDrawing();
        rl.clearBackground(skn.UI.Colors.background);
        ui.draw();
        rl.endDrawing();
    }

    end = true;
}
