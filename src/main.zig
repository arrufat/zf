const eql = std.mem.eql;
const heap = std.heap;
const io = std.io;
const std = @import("std");
const testing = std.testing;
const ziglyph = @import("ziglyph");

const ArrayList = std.ArrayList;
const Normalizer = ziglyph.Normalizer;
const SGRAttribute = term.SGRAttribute;
const Terminal = term.Terminal;

const filter = @import("filter.zig");
const term = @import("term.zig");
const ui = @import("ui.zig");

const version = "0.9.0-dev";
const version_str = std.fmt.comptimePrint("zf {s} Nathan Craddock", .{version});

const help =
    \\Usage: zf [options]
    \\
    \\-d, --delimiter  Set the delimiter used to split candidates (default \n)
    \\-f, --filter     Skip interactive use and filter using the given query
    \\-k, --keep-order Don't sort by rank and preserve order of lines read on stdin
    \\-l, --lines      Set the maximum number of result lines to show (default 10)
    \\-p, --plain      Treat input as plaintext and disable filepath matching features
    \\-v, --version    Show version information and exit
    \\-h, --help       Display this help and exit
;

const Config = struct {
    help: bool = false,
    version: bool = false,
    skip_ui: bool = false,
    keep_order: bool = false,
    lines: usize = 10,
    plain: bool = false,
    query: []u8 = undefined,
    delimiter: []const u8 = "\n",

    // HACK: error unions cannot return a value, so return error messages in
    // the config struct instead
    err: bool = false,
    err_str: []u8 = undefined,
};

// TODO: handle args immediately after a short arg, i.e. -qhello or -l5
fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) !Config {
    var config: Config = .{};

    var skip = false;
    for (args[1..], 0..) |arg, i| {
        if (skip) {
            skip = false;
            continue;
        }

        const index = i + 1;
        if (eql(u8, arg, "-h") or eql(u8, arg, "--help")) {
            config.help = true;
            return config;
        } else if (eql(u8, arg, "-v") or eql(u8, arg, "--version")) {
            config.version = true;
            return config;
        } else if (eql(u8, arg, "-k") or eql(u8, arg, "--keep-order")) {
            config.keep_order = true;
        } else if (eql(u8, arg, "-p") or eql(u8, arg, "--plain")) {
            config.plain = true;
        } else if (eql(u8, arg, "-l") or eql(u8, arg, "--lines")) {
            if (index + 1 > args.len - 1) {
                config.err = true;
                config.err_str = try std.fmt.allocPrint(
                    allocator,
                    "zf: option '{s}' requires an argument\n{s}",
                    .{ arg, help },
                );
                return config;
            }

            config.lines = try std.fmt.parseUnsigned(usize, args[index + 1], 10);
            if (config.lines == 0) return error.InvalidCharacter;
            skip = true;
        } else if (eql(u8, arg, "-f") or eql(u8, arg, "--filter")) {
            config.skip_ui = true;

            // read query
            if (index + 1 > args.len - 1) {
                config.err = true;
                config.err_str = try std.fmt.allocPrint(
                    allocator,
                    "zf: option '{s}' requires an argument\n{s}",
                    .{ arg, help },
                );
                return config;
            }

            config.query = try allocator.alloc(u8, args[index + 1].len);
            std.mem.copy(u8, config.query, args[index + 1]);
            skip = true;
        } else if (eql(u8, arg, "-d") or eql(u8, arg, "--delimiter")) {
            if (index + 1 > args.len - 1) {
                config.err = true;
                config.err_str = try std.fmt.allocPrint(
                    allocator,
                    "zf: option '{s}' requires an argument\n{s}",
                    .{ arg, help },
                );
                return config;
            }

            config.delimiter = args[index + 1];
            if (config.delimiter.len == 0) {
                config.err = true;
                config.err_str = try std.fmt.allocPrint(
                    allocator,
                    "zf: delimiter cannot be empty\n{s}",
                    .{help},
                );
                return config;
            }

            skip = true;
        } else {
            config.err = true;
            config.err_str = try std.fmt.allocPrint(
                allocator,
                "zf: unrecognized option '{s}'\n{s}",
                .{ arg, help },
            );
            return config;
        }
    }

    return config;
}

test "parse args" {
    {
        const args = [_][]const u8{"zf"};
        const config = try parseArgs(testing.allocator, &args);
        const expected: Config = .{};
        try testing.expectEqual(expected, config);
    }
    {
        const args = [_][]const u8{ "zf", "--help" };
        const config = try parseArgs(testing.allocator, &args);
        const expected: Config = .{ .help = true };
        try testing.expectEqual(expected, config);
    }
    {
        const args = [_][]const u8{ "zf", "--version" };
        const config = try parseArgs(testing.allocator, &args);
        const expected: Config = .{ .version = true };
        try testing.expectEqual(expected, config);
    }
    {
        const args = [_][]const u8{ "zf", "-v", "-h" };
        const config = try parseArgs(testing.allocator, &args);
        const expected: Config = .{ .help = false, .version = true };
        try testing.expectEqual(expected, config);
    }
    {
        const args = [_][]const u8{ "zf", "-f", "query" };
        const config = try parseArgs(testing.allocator, &args);
        defer testing.allocator.free(config.query);

        try testing.expect(config.skip_ui);
        try testing.expectEqualStrings("query", config.query);
    }
    {
        const args = [_][]const u8{ "zf", "-l", "12" };
        const config = try parseArgs(testing.allocator, &args);
        const expected: Config = .{ .lines = 12 };
        try testing.expectEqual(expected, config);
    }
    {
        const args = [_][]const u8{ "zf", "-k", "-p" };
        const config = try parseArgs(testing.allocator, &args);
        const expected: Config = .{ .keep_order = true, .plain = true };
        try testing.expectEqual(expected, config);
    }
    {
        const args = [_][]const u8{ "zf", "--keep-order", "--plain" };
        const config = try parseArgs(testing.allocator, &args);
        const expected: Config = .{ .keep_order = true, .plain = true };
        try testing.expectEqual(expected, config);
    }

    // failure cases
    {
        const args = [_][]const u8{ "zf", "--filter" };
        const config = try parseArgs(testing.allocator, &args);
        defer testing.allocator.free(config.err_str);
        try testing.expect(config.err);
    }
    {
        const args = [_][]const u8{ "zf", "asdf" };
        const config = try parseArgs(testing.allocator, &args);
        defer testing.allocator.free(config.err_str);
        try testing.expect(config.err);
    }
    {
        const args = [_][]const u8{ "zf", "bad arg here", "--help" };
        const config = try parseArgs(testing.allocator, &args);
        defer testing.allocator.free(config.err_str);
        try testing.expect(config.err);
    }
    {
        const args = [_][]const u8{ "zf", "--lines", "-10" };
        try testing.expectError(error.InvalidCharacter, parseArgs(testing.allocator, &args));
    }
}

pub fn main() anyerror!void {
    // create an arena allocator to reduce time spent allocating
    // and freeing memory during runtime.
    var arena = heap.ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit();

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    const config = parseArgs(allocator, args) catch |e| switch (e) {
        error.InvalidCharacter, error.Overflow => {
            try stderr.print("Number of lines must be an integer greater than 0\n", .{});
            std.process.exit(2);
        },
        else => return e,
    };

    if (config.err) {
        try stderr.print("{s}\n", .{config.err_str});
        std.process.exit(2);
    } else if (config.help) {
        try stdout.print("{s}\n", .{help});
        std.process.exit(0);
    } else if (config.version) {
        try stdout.print("{s}\n", .{version_str});
        std.process.exit(0);
    }

    var normalizer = try Normalizer.init(allocator);
    defer normalizer.deinit();

    // read all lines or exit on out of memory
    const buf = blk: {
        var stdin = io.getStdIn().reader();
        const buf = try readAll(allocator, &stdin);
        break :blk std.mem.trim(u8, (try normalizer.nfd(allocator, buf)).slice, "\n");
    };

    // escape specific delimiters
    const delimiter = blk: {
        if (eql(u8, config.delimiter, "\\n")) {
            break :blk '\n';
        } else if (eql(u8, config.delimiter, "\\0")) {
            break :blk 0;
        } else {
            break :blk config.delimiter[0];
        }
    };

    var candidates = try filter.collectCandidates(allocator, buf, delimiter);
    if (candidates.len == 0) std.process.exit(1);

    if (config.skip_ui) {
        // Use the heap here rather than an array on the stack. Testing showed that this is actually
        // faster, likely due to locality with other heap-alloced data used in the algorithm.
        var tokens_buf = try allocator.alloc([]const u8, 16);
        const tokens = ui.splitQuery(tokens_buf, config.query);
        const case_sensitive = ui.hasUpper(config.query);
        var filtered_buf = try allocator.alloc(filter.Candidate, candidates.len);
        const filtered = filter.rankCandidates(filtered_buf, candidates, tokens, config.keep_order, config.plain, case_sensitive);
        if (filtered.len == 0) std.process.exit(1);
        for (filtered) |candidate| {
            try stdout.print("{s}\n", .{candidate.str});
        }
    } else {
        const prompt_str = std.process.getEnvVarOwned(allocator, "ZF_PROMPT") catch "> ";
        const vi_mode = if (std.process.getEnvVarOwned(allocator, "ZF_VI_MODE")) |value| blk: {
            break :blk value.len > 0;
        } else |_| false;
        const no_color = if (std.process.getEnvVarOwned(allocator, "NO_COLOR")) |value| blk: {
            break :blk value.len > 0;
        } else |_| false;
        const highlight_color: SGRAttribute = if (std.process.getEnvVarOwned(allocator, "ZF_HIGHLIGHT")) |value| blk: {
            inline for (std.meta.fields(SGRAttribute)) |field| {
                if (eql(u8, value, field.name)) {
                    break :blk @intToEnum(SGRAttribute, field.value);
                }
            }
            break :blk .cyan;
        } else |_| .cyan;

        var terminal = try Terminal.init(@min(candidates.len, config.lines), highlight_color, no_color);
        terminal.nodelay(false);
        var selected = ui.run(
            allocator,
            &terminal,
            normalizer,
            candidates,
            config.keep_order,
            config.plain,
            prompt_str,
            vi_mode,
        ) catch |err| switch (err) {
            error.UnknownANSIEscape => {
                try stderr.print("error: unknown ANSI escape sequence in ZF_PROMPT", .{});
                std.process.exit(2);
            },
            else => return err,
        };

        try terminal.deinit();

        if (selected) |selected_lines| {
            for (selected_lines) |str| {
                try stdout.print("{s}\n", .{str});
            }
        } else std.process.exit(1);
    }
}

/// read from a file into an ArrayList. similar to readAllAlloc from the
/// standard library, but will read until out of memory rather than limiting to
/// a maximum size.
pub fn readAll(allocator: std.mem.Allocator, reader: *std.fs.File.Reader) ![]u8 {
    var buf = ArrayList(u8).init(allocator);

    // ensure the array starts at a decent size
    try buf.ensureTotalCapacity(4096);

    var index: usize = 0;
    while (true) {
        buf.expandToCapacity();
        const slice = buf.items[index..];
        const read = try reader.readAll(slice);
        index += read;

        if (read != slice.len) {
            buf.shrinkAndFree(index);
            return buf.toOwnedSlice();
        }

        try buf.ensureTotalCapacity(index + 1);
    }
}

test {
    _ = @import("array_toggle_set.zig");
    _ = @import("clib.zig");
    _ = @import("EditBuffer.zig");
    _ = @import("filter.zig");
    _ = @import("lib.zig");
    _ = @import("ui.zig");
}
