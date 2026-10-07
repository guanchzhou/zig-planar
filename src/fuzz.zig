//! Fuzz targets checking properties that must hold for every input. `zig build test` runs every
//! input in `src/fuzz-corpus/`; `zig build test --fuzz` explores further. Copy any input that
//! finds a bug back into the corpus.

const std = @import("std");
const graph = @import("graph.zig");
const planarity = @import("planarity.zig");
const kuratowski = @import("kuratowski.zig");
const color = @import("color.zig");
const Smith = std.testing.Smith;

const corpus = [_][]const u8{
    @embedFile("fuzz-corpus/00"),
    @embedFile("fuzz-corpus/01"),
    @embedFile("fuzz-corpus/02"),
    @embedFile("fuzz-corpus/03"),
    @embedFile("fuzz-corpus/04"),
    @embedFile("fuzz-corpus/05"),
};

const max_n = 14;
const max_edges = 40;

fn upTo(smith: *Smith, lo: usize, hi: usize) u32 {
    return smith.valueRangeAtMost(u32, @intCast(lo), @intCast(hi));
}

/// Every answer carries a certificate: a genus-0 embedding, or a Kuratowski subdivision.
/// Planar graphs also get proper 5- and 4-colourings.
fn certified(_: void, smith: *Smith) anyerror!void {
    const gpa = std.testing.allocator;
    const n = upTo(smith, 1, max_n);
    var buf: [max_edges]graph.Edge = undefined;
    const m = upTo(smith, 0, max_edges);
    for (buf[0..m]) |*e| e.* = .{ upTo(smith, 0, n - 1), upTo(smith, 0, n - 1) };
    const g = try graph.Graph.init(gpa, n, buf[0..m]);
    defer g.deinit(gpa);

    if (try planarity.embed(gpa, g)) |e| {
        defer e.deinit(gpa);
        try std.testing.expectEqual(0, try e.genus(gpa));
        const c5 = try color.five(gpa, g);
        defer gpa.free(c5);
        try std.testing.expect(color.isProper(g, c5, 5));
        const c4 = try color.four(gpa, g, .{});
        defer gpa.free(c4);
        try std.testing.expect(color.isProper(g, c4, 4));
    } else {
        const cert = (try kuratowski.find(gpa, g)).?;
        defer gpa.free(cert);
        for (cert) |edge| try std.testing.expect(g.halfEdge(edge[0], edge[1]) != null);
        try std.testing.expect(try kuratowski.classify(gpa, n, cert) != null);
    }
}

test "fuzz: planarity answers are certified and colourings are proper" {
    try std.testing.fuzz({}, certified, .{ .corpus = &corpus });
}

/// Smallest-last order: a permutation in which no vertex has more than `degeneracy`
/// later neighbours, and greedy colouring uses at most degeneracy + 1 colours.
fn degeneracy(_: void, smith: *Smith) anyerror!void {
    const gpa = std.testing.allocator;
    const n = upTo(smith, 1, max_n);
    var buf: [max_edges]graph.Edge = undefined;
    const m = upTo(smith, 0, max_edges);
    for (buf[0..m]) |*e| e.* = .{ upTo(smith, 0, n - 1), upTo(smith, 0, n - 1) };
    const g = try graph.Graph.init(gpa, n, buf[0..m]);
    defer g.deinit(gpa);

    var prng = std.Random.DefaultPrng.init(smith.value(u64));
    const order = try color.smallestLast(gpa, g, prng.random());
    defer order.deinit(gpa);
    var position: [max_n]u32 = @splat(graph.none);
    for (order.vertices, 0..) |v, i| {
        try std.testing.expectEqual(graph.none, position[v]);
        position[v] = @intCast(i);
    }
    for (order.vertices, 0..) |v, i| {
        var later: u32 = 0;
        for (g.neighbors(v)) |u| later += @intFromBool(position[u] > i);
        try std.testing.expect(later <= order.degeneracy);
    }
    const colors = try color.greedy(gpa, g);
    defer gpa.free(colors);
    try std.testing.expect(color.isProper(g, colors, @intCast(order.degeneracy + 1)));
}

test "fuzz: smallest-last order and greedy colouring" {
    try std.testing.fuzz({}, degeneracy, .{ .corpus = &corpus });
}
