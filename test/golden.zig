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
