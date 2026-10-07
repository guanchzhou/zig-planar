//! zig-planar command line. Each command reads one JSON object on stdin and writes one JSON
//! object on stdout.

const std = @import("std");
const planar = @import("planar");
const build_options = @import("build_options");

const usage =
    \\usage: zig-planar COMMAND < input.json
    \\
    \\Edges are [u, v] pairs of node indices below n. Self loops and repeated edges are ignored.
    \\
    \\  planar  {"n":N,"edges":[..],"certificate":bool?}
    \\          -> {"planar":true,"rotation":[[..]..],"faces":[[..]..]}
    \\          or {"planar":false,"kuratowski":{"kind":"K5"|"K3,3","edges":[..]}}
    \\             (the Kuratowski subgraph only with "certificate":true; it takes O(m^2) time)
    \\  color   {"n":N,"edges":[..],"method":"four"|"five"|"greedy"?}
    \\          -> {"colors":[..],"used":K}   four and five need a planar graph;
    \\             four also reports "passes" and "exact_steps"
    \\  version
    \\
;

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("zig-planar: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn parse(comptime T: type, arena: std.mem.Allocator, text: []const u8) T {
    return std.json.parseFromSliceLeaky(T, arena, text, .{ .ignore_unknown_fields = true }) catch |e|
        fail("invalid input: {s}", .{@errorName(e)});
}

fn emit(out: *std.Io.Writer, v: anytype) !void {
    try std.json.Stringify.value(v, .{}, out);
    try out.writeAll("\n");
}

fn index(x: f64, n: u32, i: usize) u32 {
    if (!(x >= 0 and x < @as(f64, @floatFromInt(n)) and @floor(x) == x))
        fail("edge {d}: {d} is not a node index below {d}", .{ i, x, n });
    return @intFromFloat(x);
}

fn graphOf(arena: std.mem.Allocator, n: f64, rows: []const []const f64) !planar.Graph {
    if (!(n >= 0 and n < std.math.maxInt(u32) and @floor(n) == n)) fail("n must be a whole number of nodes", .{});
    const count: u32 = @intFromFloat(n);
    const edges = try arena.alloc(planar.Edge, rows.len);
    for (rows, edges, 0..) |r, *e, i| {
        if (r.len != 2) fail("edge {d} has {d} values, expected 2", .{ i, r.len });
        e.* = .{ index(r[0], count, i), index(r[1], count, i) };
    }
    return planar.Graph.init(arena, count, edges);
}

fn numbers(arena: std.mem.Allocator, colors: []const u8) ![]const u32 {
    const out = try arena.alloc(u32, colors.len);
    for (colors, out) |c, *o| o.* = c;
    return out;
}

fn slices(arena: std.mem.Allocator, count: usize, start: []const u32, items: []const u32) ![]const []const u32 {
    const out = try arena.alloc([]const u32, count);
    for (out, 0..) |*s, i| s.* = items[start[i]..start[i + 1]];
    return out;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var buf: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout.interface;
    defer out.flush() catch {};
    if (args.len != 2) {
        std.debug.print("{s}", .{usage});
        std.process.exit(2);
    }
    const cmd: []const u8 = args[1];
    if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version")) {
        try out.print("zig-planar {s}\n", .{build_options.version});
        return;
    }
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        try out.writeAll(usage);
        return;
    }
    if (!std.mem.eql(u8, cmd, "planar") and !std.mem.eql(u8, cmd, "color")) {
        std.debug.print("zig-planar: unknown command: {s}\n{s}", .{ cmd, usage });
        std.process.exit(2);
    }

    var in_buf: [64 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(init.io, &in_buf);
    const text = stdin.interface.allocRemaining(arena, .unlimited) catch |e| switch (e) {
        error.ReadFailed => return stdin.err.?,
        else => |x| return x,
    };

    if (std.mem.eql(u8, cmd, "planar")) {
        const in = parse(struct { n: f64, edges: []const []const f64, certificate: bool = false }, arena, text);
        const g = try graphOf(arena, in.n, in.edges);
        if (try planar.planarity.embed(arena, g)) |e| {
            const faces = try e.faces(arena);
            try emit(out, .{
                .planar = true,
                .rotation = try slices(arena, g.n, e.start, e.rotation),
                .faces = try slices(arena, faces.count(), faces.start, faces.vertices),
            });
        } else if (in.certificate) {
            const cert = (try planar.kuratowski.find(arena, g)).?;
            const kind = (try planar.kuratowski.classify(arena, g.n, cert)).?;
            try emit(out, .{ .planar = false, .kuratowski = .{ .kind = kind.name(), .edges = cert } });
        } else try emit(out, .{ .planar = false });
    } else {
        const in = parse(struct { n: f64, edges: []const []const f64, method: []const u8 = "four" }, arena, text);
        const g = try graphOf(arena, in.n, in.edges);
        if (std.mem.eql(u8, in.method, "greedy")) {
            const colors = try planar.color.greedy(arena, g);
            try emit(out, .{ .colors = try numbers(arena, colors), .used = planar.color.count(colors) });
        } else if (std.mem.eql(u8, in.method, "five")) {
            const colors = planar.color.five(arena, g) catch |e| switch (e) {
                error.NotPlanar => fail("the graph is not planar; five needs a planar graph", .{}),
                else => |x| return x,
            };
            try emit(out, .{ .colors = try numbers(arena, colors), .used = planar.color.count(colors) });
        } else if (std.mem.eql(u8, in.method, "four")) {
            var stats: planar.color.FourStats = .{};
            const colors = planar.color.four(arena, g, .{ .stats = &stats }) catch |e| switch (e) {
                error.NotPlanar => fail("the graph is not planar; four needs a planar graph", .{}),
                error.SearchLimit => fail("no 4-colouring found within the search limit", .{}),
                else => |x| return x,
            };
            try emit(out, .{
                .colors = try numbers(arena, colors),
                .used = planar.color.count(colors),
                .passes = stats.passes,
                .exact_steps = stats.exact_steps,
            });
        } else fail("method must be four, five or greedy, not {s}", .{in.method});
    }
}
