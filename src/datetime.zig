const std = @import("std");

const Self = @This();

year: u16,
month: u8,
day: u8,
hour: u8,
minute: u8,

fn parse(string: []const u8) !Self {
    std.debug.assert(string.len == 16);
    return .{
        .year = try std.fmt.parseInt(u16, string[0..4], 10),
        .month = try std.fmt.parseInt(u8, string[5..7], 10),
        .day = try std.fmt.parseInt(u8, string[8..10], 10),
        .hour = try std.fmt.parseInt(u8, string[11..13], 10),
        .minute = try std.fmt.parseInt(u8, string[14..16], 10),
    };
}

pub fn now(allocator: std.mem.Allocator) !Self {
    const child = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "date", "--iso-8601=minutes" } });
    defer allocator.free(child.stdout);
    return parse(child.stdout[0..16]);
}

pub fn tomorrow(allocator: std.mem.Allocator) !Self {
    const child = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{
        "date",
        "-d",
        "+1day",
        "--iso-8601=minutes",
    } });
    defer allocator.free(child.stdout);
    return parse(child.stdout[0..16]);
}

/// The caller owns the returned memory
pub fn to_string(self: Self, allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{:0>4}-{:0>2}-{:0>2} {:0>2}:{:0>2}:00", .{
        self.year,
        self.month,
        self.day,
        self.hour,
        self.minute,
    });
}
