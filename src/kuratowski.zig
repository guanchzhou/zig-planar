//! Kuratowski subgraphs: the certificate that a graph is not planar.
//!
//! Every non-planar graph contains a subdivision of K5 or K3,3 (Kuratowski 1930). `find`
//! deletes each edge in turn and keeps it deleted when the rest is still non-planar; what
//! remains is a minimal non-planar subgraph, which is such a subdivision. This runs one
//! planarity test per edge, so it takes O(m^2) time. `classify` checks a certificate without
//! any planarity test: it smooths away vertices of degree 2 and compares what is left with
//! K5 and K3,3.

const std = @import("std");
const graph_mod = @import("graph.zig");
const Graph = graph_mod.Graph;
const Edge = graph_mod.Edge;
const none = graph_mod.none;
const planarity = @import("planarity.zig");

pub const Kind = enum {
    k5,
    k33,

    pub fn name(k: Kind) []const u8 {
        return switch (k) {
            .k5 => "K5",
            .k33 => "K3,3",
        };
    }
};

/// The edges of a Kuratowski subgraph of `g`, sorted, or null when `g` is planar. Memory stays
/// O(n + m) whatever `gpa` is: each trial graph lives in an arena that is reset between trials.
pub fn find(gpa: std.mem.Allocator, g: Graph) !?[]Edge {
    if (try planarity.isPlanar(gpa, g)) return null;
    const all = try g.edgeList(gpa);
    defer gpa.free(all);
    var keep: std.ArrayList(Edge) = .empty;
    errdefer keep.deinit(gpa);
    try keep.appendSlice(gpa, all);
    var trial: std.heap.ArenaAllocator = .init(gpa);
    defer trial.deinit();
    const planar_max = 3 * @as(usize, g.n) -| 6;
    var i: usize = 0;
    while (i < keep.items.len) {
        const removed = keep.orderedRemove(i);
        if (keep.items.len > planar_max) continue;
        _ = trial.reset(.retain_capacity);
        const rest = try Graph.init(trial.allocator(), g.n, keep.items);
        if (try planarity.isPlanar(trial.allocator(), rest)) {
            try keep.insert(gpa, i, removed);
            i += 1;
        }
    }
    return try keep.toOwnedSlice(gpa);
}

/// K5 or K3,3 when `edges` form a subdivision of it, otherwise null.
pub fn classify(gpa: std.mem.Allocator, n: u32, edges: []const Edge) !?Kind {
    const g = try Graph.init(gpa, n, edges);
    defer g.deinit(gpa);
    if (g.edgeCount() != edges.len) return null;

    var branch: std.ArrayList(u32) = .empty;
    defer branch.deinit(gpa);
    for (0..n) |v| switch (g.degree(@intCast(v))) {
        0, 2 => {},
        3, 4 => try branch.append(gpa, @intCast(v)),
        else => return null,
    };
    const kind: Kind = switch (branch.items.len) {
        5 => .k5,
        6 => .k33,
        else => return null,
    };
    const want_degree: u32 = if (kind == .k5) 4 else 3;
    const index = try gpa.alloc(u32, n);
    defer gpa.free(index);
    @memset(index, none);
    for (branch.items, 0..) |v, i| {
        if (g.degree(v) != want_degree) return null;
        index[v] = @intCast(i);
    }

    // Follow each path of degree-2 vertices from every branch vertex to the next one.
    const used = try gpa.alloc(bool, g.adj.len);
    defer gpa.free(used);
    @memset(used, false);
    var adjacent: [6][6]bool = @splat(@splat(false));
    var paths: usize = 0;
    for (branch.items) |b| {
        for (g.start[b]..g.start[b + 1]) |first| {
            if (used[first]) continue;
            var h: u32 = @intCast(first);
            while (true) {
                used[h] = true;
                used[g.twin[h]] = true;
                const w = g.adj[h];
                if (index[w] != none) break;
                const s = g.start[w];
                h = if (g.adj[s] == g.from[h]) s + 1 else s;
            }
            const x = index[b];
            const y = index[g.adj[h]];
            if (x == y or adjacent[x][y]) return null;
            adjacent[x][y] = true;
            adjacent[y][x] = true;
            paths += 1;
        }
    }
    for (used) |u| if (!u) return null;

    switch (kind) {
        .k5 => if (paths != 10) return null,
        .k33 => {
            if (paths != 9) return null;
            // Two-colour the six branch vertices; K3,3 is the only 3-regular bipartite option.
            var colour: [6]i8 = @splat(-1);
            colour[0] = 0;
            var changed = true;
            while (changed) {
                changed = false;
                for (0..6) |x| for (0..6) |y| {
                    if (!adjacent[x][y] or colour[x] < 0) continue;
                    if (colour[y] == colour[x]) return null;
                    if (colour[y] < 0) {
                        colour[y] = 1 - colour[x];
                        changed = true;
                    }
                };
            }
            for (colour) |c| if (c < 0) return null;
        },
    }
    return kind;
}

test "Petersen graph contains a K3,3 subdivision" {
    const gpa = std.testing.allocator;
    const edges = [_]Edge{
        .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 3, 4 }, .{ 4, 0 },
        .{ 0, 5 }, .{ 1, 6 }, .{ 2, 7 }, .{ 3, 8 }, .{ 4, 9 },
        .{ 5, 7 }, .{ 7, 9 }, .{ 9, 6 }, .{ 6, 8 }, .{ 8, 5 },
    };
    const g = try Graph.init(gpa, 10, &edges);
    defer g.deinit(gpa);
    const cert = (try find(gpa, g)).?;
    defer gpa.free(cert);
    try std.testing.expectEqual(.k33, (try classify(gpa, 10, cert)).?);
}

test "a subdivided K5 is recognised; a cycle is not a certificate" {
    const gpa = std.testing.allocator;
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(gpa);
    var next: u32 = 5;
    for (0..5) |i| for (i + 1..5) |j| {
        try edges.append(gpa, .{ @intCast(i), next });
        try edges.append(gpa, .{ next, @intCast(j) });
        next += 1;
    };
    try std.testing.expectEqual(.k5, (try classify(gpa, next, edges.items)).?);
    try std.testing.expectEqual(null, try classify(gpa, 3, &.{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 0 } }));
}

/// A `side` by `side` grid with one diagonal per square, which is planar with 3n - 6 - O(side)
/// edges, plus a disjoint K3,3.
fn gridWithK33(gpa: std.mem.Allocator, side: u32) !Graph {
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(gpa);
    for (0..side) |r| for (0..side) |c| {
        const v: u32 = @intCast(r * side + c);
        if (c + 1 < side) try edges.append(gpa, .{ v, v + 1 });
        if (r + 1 < side) try edges.append(gpa, .{ v, v + side });
        if (c + 1 < side and r + 1 < side) try edges.append(gpa, .{ v, v + side + 1 });
    };
    const b = side * side;
    for (0..3) |x| for (3..6) |y| try edges.append(gpa, .{ b + @as(u32, @intCast(x)), b + @as(u32, @intCast(y)) });
    return Graph.init(gpa, b + 6, edges.items);
}

test "find keeps memory linear when given an arena" {
    const gpa = std.testing.allocator;
    const g = try gridWithK33(gpa, 12);
    defer g.deinit(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const cert = (try find(arena.allocator(), g)).?;
    try std.testing.expectEqual(Kind.k33, (try classify(gpa, g.n, cert)).?);
    try std.testing.expect(arena.queryCapacity() < 512 * 1024);
}

fn findAlloc(gpa: std.mem.Allocator) !void {
    const g = try gridWithK33(gpa, 3);
    defer g.deinit(gpa);
    const cert = (try find(gpa, g)).?;
    gpa.free(cert);
}

test "find frees everything on allocation failure" {
    // Whether the trial arena grows in place depends on the backing allocator's state, so the
    // number of allocations varies between runs and `checkAllAllocationFailures` cannot be used.
    var i: usize = 0;
    while (true) : (i += 1) {
        var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = i });
        findAlloc(failing.allocator()) catch |e| switch (e) {
            error.OutOfMemory => {
                try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
                continue;
            },
            else => return e,
        };
        if (!failing.has_induced_failure) break;
    }
    try std.testing.expect(i > 0);
}
