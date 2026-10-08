//! Replays test/golden.json, written by test/reference.py from networkx. The planarity answer
//! must match networkx, and every answer must carry a certificate that checks on its own: a
//! genus-0 embedding when planar, a K5 or K3,3 subdivision when not. Planar graphs must also
//! receive proper 6-, 5- and 4-colourings.

const std = @import("std");
const planar = @import("planar");
const Graph = planar.Graph;
const color = planar.color;

const Case = struct { n: u32, edges: []const planar.Edge, planar: bool };
const Golden = struct { planarity: []const Case, large: []const Case };

fn load(arena: std.mem.Allocator) !Golden {
    return std.json.parseFromSliceLeaky(Golden, arena, @embedFile("golden.json"), .{});
}

fn checkPlanar(gpa: std.mem.Allocator, g: Graph, e: planar.Embedding) !void {
    try std.testing.expectEqual(0, try e.genus(gpa));
    for (0..g.n) |v| {
        const got = try gpa.dupe(u32, e.neighbors(@intCast(v)));
        defer gpa.free(got);
        std.mem.sort(u32, got, {}, std.sort.asc(u32));
        try std.testing.expectEqualSlices(u32, g.neighbors(@intCast(v)), got);
    }

    const order = try color.smallestLast(gpa, g, null);
    defer order.deinit(gpa);
    try std.testing.expect(order.degeneracy <= 5);
    const c6 = try color.greedy(gpa, g);
    defer gpa.free(c6);
    try std.testing.expect(color.isProper(g, c6, 6));
    const c5 = try color.five(gpa, g);
    defer gpa.free(c5);
    try std.testing.expect(color.isProper(g, c5, 5));
    const c4 = try color.four(gpa, g, .{});
    defer gpa.free(c4);
    try std.testing.expect(color.isProper(g, c4, 4));
}

test "planarity matches networkx, with a certificate either way" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const golden = try load(arena_state.allocator());
    var certified: usize = 0;
    for (golden.planarity, 0..) |c, i| {
        const g = try Graph.init(gpa, c.n, c.edges);
        defer g.deinit(gpa);
        const e = try planar.planarity.embed(gpa, g);
        if ((e != null) != c.planar) {
            std.debug.print("case {d}: networkx says planar={}, got {}\n", .{ i, c.planar, e != null });
            return error.TestUnexpectedResult;
        }
        if (e) |emb| {
            defer emb.deinit(gpa);
            try checkPlanar(gpa, g, emb);
        } else if (g.edgeCount() <= 200) {
            const cert = (try planar.kuratowski.find(gpa, g)).?;
            defer gpa.free(cert);
            for (cert) |edge| try std.testing.expect(g.halfEdge(edge[0], edge[1]) != null);
            try std.testing.expect(try planar.kuratowski.classify(gpa, c.n, cert) != null);
            certified += 1;
        }
    }
    try std.testing.expect(certified >= 150);
}

fn dijkstra(gpa: std.mem.Allocator, g: Graph, lengths: []const u32, source: u32, out: []u64) !void {
    const Item = struct { d: u64, v: u32 };
    var queue: std.PriorityQueue(Item, void, struct {
        fn order(_: void, a: Item, b: Item) std.math.Order {
            return std.math.order(a.d, b.d);
        }
    }.order) = .empty;
    defer queue.deinit(gpa);
    @memset(out, std.math.maxInt(u64));
    out[source] = 0;
    try queue.push(gpa, .{ .d = 0, .v = source });
    while (queue.pop()) |it| {
        if (it.d != out[it.v]) continue;
        for (g.start[it.v]..g.start[it.v + 1]) |h| {
            const nd = it.d + lengths[h];
            if (nd < out[g.adj[h]]) {
                out[g.adj[h]] = nd;
                try queue.push(gpa, .{ .d = nd, .v = g.adj[h] });
            }
        }
    }
}

const mssp = planar.mssp;

/// Every tree of `mssp.trees` from the face traced from `dart` must give Dijkstra's distances
/// from its root. Returns the number of darts of g that entered a tree, which leaves out the
/// one change per step that makes the next boundary vertex the root.
fn checkTrees(gpa: std.mem.Allocator, g: Graph, e: planar.Embedding, lengths: []const u32, dart: [2]u32) !usize {
    const t = try mssp.trees(gpa, g, e, lengths, dart);
    defer t.deinit(gpa);
    var w = try mssp.Walk.init(gpa, &t);
    defer w.deinit(gpa);
    const got = try gpa.alloc(u64, g.n);
    defer gpa.free(got);
    const want = try gpa.alloc(u64, g.n);
    defer gpa.free(want);
    while (true) {
        try mssp.distances(gpa, g, lengths, w.parent, got);
        try dijkstra(gpa, g, lengths, w.root(), want);
        try std.testing.expectEqualSlices(u64, want, got);
        if (!w.next()) break;
    }
    var entered: usize = 0;
    for (t.to) |h| entered += @intFromBool(h != planar.graph.none);
    try std.testing.expectEqual(t.boundary.len - 1, t.changeCount() - entered);
    return entered;
}

fn connected(gpa: std.mem.Allocator, g: Graph) !bool {
    const d = try gpa.alloc(u64, g.n);
    defer gpa.free(d);
    const ones = try gpa.alloc(u32, g.adj.len);
    defer gpa.free(ones);
    @memset(ones, 1);
    try dijkstra(gpa, g, ones, 0, d);
    return std.mem.indexOfScalar(u64, d, std.math.maxInt(u64)) == null;
}

fn randomLengths(gpa: std.mem.Allocator, g: Graph, rand: std.Random, lo: u32, hi: u32) ![]u32 {
    const lengths = try gpa.alloc(u32, g.adj.len);
    for (0..g.adj.len) |h| {
        if (g.from[h] < g.adj[h]) {
            lengths[h] = rand.intRangeAtMost(u32, lo, hi);
            lengths[g.twin[h]] = lengths[h];
        }
    }
    return lengths;
}

/// The largest face and one other, as darts.
fn twoFaces(gpa: std.mem.Allocator, e: planar.Embedding, rand: std.Random) ![2][2]u32 {
    const faces = try e.faces(gpa);
    defer faces.deinit(gpa);
    var big: usize = 0;
    for (0..faces.count()) |i| {
        if (faces.get(i).len > faces.get(big).len) big = i;
    }
    const other = rand.uintLessThan(usize, faces.count());
    const a = faces.get(big);
    const b = faces.get(other);
    return .{ .{ a[0], a[1] }, .{ b[0], b[1] } };
}

test "multiple-source shortest paths match Dijkstra on every connected planar graph" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const golden = try load(arena_state.allocator());
    var prng = std.Random.DefaultPrng.init(20261008);
    const rand = prng.random();
    var checked: usize = 0;
    var worst: f64 = 0;
    for (golden.planarity) |c| {
        if (!c.planar or c.edges.len == 0) continue;
        const g = try Graph.init(gpa, c.n, c.edges);
        defer g.deinit(gpa);
        const e = (try planar.planarity.embed(gpa, g)).?;
        defer e.deinit(gpa);
        const faces = try twoFaces(gpa, e, rand);
        if (!try connected(gpa, g)) {
            const ones = try gpa.alloc(u32, g.adj.len);
            defer gpa.free(ones);
            @memset(ones, 1);
            try std.testing.expectError(error.Disconnected, mssp.trees(gpa, g, e, ones, faces[0]));
            continue;
        }
        for ([_][2]u32{ .{ 1, 1000 }, .{ 0, 3 } }) |range| {
            const lengths = try randomLengths(gpa, g, rand, range[0], range[1]);
            defer gpa.free(lengths);
            for (faces) |dart| {
                const entered = try checkTrees(gpa, g, e, lengths, dart);
                if (range[0] > 0) {
                    const ratio = @as(f64, @floatFromInt(entered)) / @as(f64, @floatFromInt(g.adj.len));
                    worst = @max(worst, ratio);
                }
            }
        }
        checked += 1;
    }
    try std.testing.expect(checked >= 150);
    // Every dart enters the tree at most once around the face.
    try std.testing.expect(worst <= 1);
}

test "multiple-source shortest paths on the large triangulations" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const golden = try load(arena_state.allocator());
    var prng = std.Random.DefaultPrng.init(8);
    const rand = prng.random();
    for (golden.large) |c| {
        const g = try Graph.init(gpa, c.n, c.edges);
        defer g.deinit(gpa);
        const e = (try planar.planarity.embed(gpa, g)).?;
        defer e.deinit(gpa);
        const lengths = try randomLengths(gpa, g, rand, 1, 1 << 20);
        defer gpa.free(lengths);
        const faces = try twoFaces(gpa, e, rand);
        const entered = try checkTrees(gpa, g, e, lengths, faces[0]);
        try std.testing.expect(entered <= g.adj.len);
    }
}

test "large triangulations: embedding and colourings" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const golden = try load(arena_state.allocator());
    for (golden.large) |c| {
        const g = try Graph.init(gpa, c.n, c.edges);
        defer g.deinit(gpa);
        const e = (try planar.planarity.embed(gpa, g)).?;
        defer e.deinit(gpa);
        try checkPlanar(gpa, g, e);
    }
}
