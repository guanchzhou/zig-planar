//! Simple undirected graphs in compressed-sparse-row form.
//!
//! Each undirected edge {u, v} is stored as two half-edges, u -> v and v -> u. Half-edge `h`
//! goes from `from[h]` to `adj[h]`, and `twin[h]` is the opposite half-edge. The neighbours of
//! `v` are `adj[start[v]..start[v + 1]]`, sorted ascending. Self loops and repeated edges are
//! dropped when the graph is built.

const std = @import("std");

pub const none: u32 = std.math.maxInt(u32);

pub const Edge = [2]u32;

pub const Graph = struct {
    n: u32,
    start: []u32,
    adj: []u32,
    from: []u32,
    twin: []u32,

    pub fn init(gpa: std.mem.Allocator, n: u32, edges: []const Edge) !Graph {
        var keys: std.ArrayList(u64) = .empty;
        defer keys.deinit(gpa);
        try keys.ensureTotalCapacity(gpa, 2 * edges.len);
        for (edges) |e| {
            if (e[0] >= n or e[1] >= n) return error.NodeOutOfRange;
            if (e[0] == e[1]) continue;
            keys.appendAssumeCapacity(@as(u64, e[0]) << 32 | e[1]);
            keys.appendAssumeCapacity(@as(u64, e[1]) << 32 | e[0]);
        }
        std.mem.sort(u64, keys.items, {}, std.sort.asc(u64));
        var len: usize = 0;
        for (keys.items) |k| {
            if (len > 0 and keys.items[len - 1] == k) continue;
            keys.items[len] = k;
            len += 1;
        }
        const half = keys.items[0..len];

        const start = try gpa.alloc(u32, @as(usize, n) + 1);
        errdefer gpa.free(start);
        const adj = try gpa.alloc(u32, len);
        errdefer gpa.free(adj);
        const from = try gpa.alloc(u32, len);
        errdefer gpa.free(from);
        const twin = try gpa.alloc(u32, len);
        errdefer gpa.free(twin);

        @memset(start, 0);
        for (half, adj, from) |k, *a, *f| {
            f.* = @intCast(k >> 32);
            a.* = @truncate(k);
            start[f.* + 1] += 1;
        }
        for (1..start.len) |i| start[i] += start[i - 1];
        const g: Graph = .{ .n = n, .start = start, .adj = adj, .from = from, .twin = twin };
        for (0..len) |h| twin[h] = g.halfEdge(adj[h], from[h]).?;
        return g;
    }

    pub fn deinit(g: Graph, gpa: std.mem.Allocator) void {
        gpa.free(g.start);
        gpa.free(g.adj);
        gpa.free(g.from);
        gpa.free(g.twin);
    }

    pub fn edgeCount(g: Graph) usize {
        return g.adj.len / 2;
    }

    pub fn degree(g: Graph, v: u32) u32 {
        return g.start[v + 1] - g.start[v];
    }

    pub fn neighbors(g: Graph, v: u32) []const u32 {
        return g.adj[g.start[v]..g.start[v + 1]];
    }

    /// The half-edge u -> v, or null when u and v are not adjacent.
    pub fn halfEdge(g: Graph, u: u32, v: u32) ?u32 {
        const i = std.sort.binarySearch(u32, g.neighbors(u), v, struct {
            fn order(key: u32, x: u32) std.math.Order {
                return std.math.order(key, x);
            }
        }.order) orelse return null;
        return g.start[u] + @as(u32, @intCast(i));
    }

    /// Every edge once, as [u, v] with u < v, in ascending order.
    pub fn edgeList(g: Graph, gpa: std.mem.Allocator) ![]Edge {
        const out = try gpa.alloc(Edge, g.edgeCount());
        var i: usize = 0;
        for (g.adj, g.from) |v, u| {
            if (u < v) {
                out[i] = .{ u, v };
                i += 1;
            }
        }
        return out;
    }
};

test "self loops and repeated edges are dropped" {
    const gpa = std.testing.allocator;
    const g = try Graph.init(gpa, 4, &.{ .{ 0, 1 }, .{ 1, 0 }, .{ 2, 2 }, .{ 3, 1 }, .{ 0, 1 } });
    defer g.deinit(gpa);
    try std.testing.expectEqual(2, g.edgeCount());
    try std.testing.expectEqualSlices(u32, &.{ 0, 3 }, g.neighbors(1));
    try std.testing.expectEqual(0, g.degree(2));
    for (0..g.adj.len) |h| {
        try std.testing.expectEqual(g.from[h], g.adj[g.twin[h]]);
        try std.testing.expectEqual(h, g.twin[g.twin[h]]);
    }
    try std.testing.expectEqual(null, g.halfEdge(0, 3));
}

test "an edge outside the graph is rejected" {
    try std.testing.expectError(error.NodeOutOfRange, Graph.init(std.testing.allocator, 2, &.{.{ 0, 2 }}));
}
