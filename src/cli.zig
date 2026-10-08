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
    \\  paths   {"n":N,"edges":[..],"boundary":[u,v],"distances":bool?}
    \\          -> {"boundary":[..],"parent":[..],"steps":[[[v,p]..]..]}
    \\             Shortest-path trees from every vertex of the face traced from dart u -> v,
    \\             for a connected planar graph. Edges may be [u, v, length] (default 1); a
    \\             repeated edge keeps its shortest length. "parent" is the tree rooted at
    \\             boundary[0]; step i lists [vertex, new parent] for the move to
    \\             boundary[i + 1], with null for the new root. "distances":true adds one
    \\             row of distances per boundary vertex.
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

const Weighted = struct { g: planar.Graph, lengths: []u32 };

fn weightedOf(arena: std.mem.Allocator, n: f64, rows: []const []const f64) !Weighted {
    if (!(n >= 0 and n < std.math.maxInt(u32) and @floor(n) == n)) fail("n must be a whole number of nodes", .{});
    const count: u32 = @intFromFloat(n);
    const edges = try arena.alloc(planar.Edge, rows.len);
    for (rows, edges, 0..) |r, *e, i| {
        if (r.len != 2 and r.len != 3) fail("edge {d} has {d} values, expected 2 or 3", .{ i, r.len });
        e.* = .{ index(r[0], count, i), index(r[1], count, i) };
    }
    const g = try planar.Graph.init(arena, count, edges);
    const lengths = try arena.alloc(u32, g.adj.len);
    @memset(lengths, std.math.maxInt(u32));
    for (rows, edges, 0..) |r, e, i| {
        const l: f64 = if (r.len == 3) r[2] else 1;
        if (!(l >= 0 and l < std.math.maxInt(u32) and @floor(l) == l))
            fail("edge {d}: length {d} is not a whole number from 0 to 2^32 - 2", .{ i, l });
        const h = g.halfEdge(e[0], e[1]) orelse continue;
        lengths[h] = @min(lengths[h], @as(u32, @intFromFloat(l)));
        lengths[g.twin[h]] = lengths[h];
    }
    return .{ .g = g, .lengths = lengths };
}

fn paths(arena: std.mem.Allocator, out: *std.Io.Writer, text: []const u8) !void {
    const in = parse(struct {
        n: f64,
        edges: []const []const f64,
        boundary: []const f64,
        distances: bool = false,
    }, arena, text);
    const w = try weightedOf(arena, in.n, in.edges);
    const g = w.g;
    if (in.boundary.len != 2) fail("boundary must be [u, v]", .{});
    const dart: [2]u32 = .{ index(in.boundary[0], g.n, 0), index(in.boundary[1], g.n, 0) };
    const e = try planar.planarity.embed(arena, g) orelse fail("the graph is not planar; paths needs a planar graph", .{});
    const t = planar.mssp.trees(arena, g, e, w.lengths, dart) catch |err| switch (err) {
        error.NotAnEdge => fail("boundary [{d}, {d}] is not an edge", .{ dart[0], dart[1] }),
        error.Disconnected => fail("the graph is not connected", .{}),
        error.LengthOverflow => fail("the lengths add up to more than 2^58", .{}),
        else => |x| return x,
    };

    const parent = try arena.alloc(?u32, g.n);
    for (t.parent, parent) |h, *p| p.* = if (h == planar.graph.none) null else g.from[h];
    const steps = try arena.alloc([]const [2]?u32, t.boundary.len - 1);
    for (steps, 0..) |*s, i| {
        const list = try arena.alloc([2]?u32, t.step[i + 1] - t.step[i]);
        for (list, t.step[i]..) |*c, j| c.* = .{ t.vertex[j], if (t.to[j] == planar.graph.none) null else g.from[t.to[j]] };
        s.* = list;
    }
    if (!in.distances) return emit(out, .{ .boundary = t.boundary, .parent = parent, .steps = steps });

    const rows = try arena.alloc([]const u64, t.boundary.len);
    var walk = try planar.mssp.Walk.init(arena, &t);
    for (rows) |*r| {
        const d = try arena.alloc(u64, g.n);
        try planar.mssp.distances(arena, g, w.lengths, walk.parent, d);
        r.* = d;
        _ = walk.next();
    }
    try emit(out, .{ .boundary = t.boundary, .parent = parent, .steps = steps, .distances = rows });
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
    if (!std.mem.eql(u8, cmd, "planar") and !std.mem.eql(u8, cmd, "color") and !std.mem.eql(u8, cmd, "paths")) {
        std.debug.print("zig-planar: unknown command: {s}\n{s}", .{ cmd, usage });
        std.process.exit(2);
    }

    var in_buf: [64 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(init.io, &in_buf);
    const text = stdin.interface.allocRemaining(arena, .unlimited) catch |e| switch (e) {
        error.ReadFailed => return stdin.err.?,
        else => |x| return x,
    };

    if (std.mem.eql(u8, cmd, "paths")) {
        try paths(arena, out, text);
    } else if (std.mem.eql(u8, cmd, "planar")) {
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
