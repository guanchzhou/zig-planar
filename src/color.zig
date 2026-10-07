//! Vertex colourings of planar graphs.
//!
//! - `greedy`: smallest-last order (Matula and Beck 1983), at most degeneracy + 1 colours,
//!   so at most 6 on a planar graph. Works on any graph.
//! - `five`: 5 colours on every planar graph, by Kempe chains (Heawood 1890).
//! - `four`: 4 colours on planar graphs. The Four Colour Theorem guarantees that one exists,
//!   but this is not the near-linear algorithm of Inoue et al. (2026): it colours in
//!   smallest-last order, frees a colour with bounded Kempe-chain search when all four are
//!   taken, retries with shuffled orders, and finally runs an exact search with a step limit.
//!   Every colouring it returns is proper; it can stop with `error.SearchLimit`.
//!
//! Colours are 0-based. `uncolored` marks a vertex without a colour.

const std = @import("std");
const graph_mod = @import("graph.zig");
const Graph = graph_mod.Graph;
const none = graph_mod.none;
const planarity = @import("planarity.zig");

pub const uncolored: u8 = std.math.maxInt(u8);

/// True when every vertex has a colour below `k` and no edge joins two equal colours.
pub fn isProper(g: Graph, colors: []const u8, k: u8) bool {
    if (colors.len != g.n) return false;
    for (colors) |c| if (c >= k) return false;
    for (g.adj, g.from) |v, u| if (colors[u] == colors[v]) return false;
    return true;
}

pub fn count(colors: []const u8) u8 {
    var k: u8 = 0;
    for (colors) |c| {
        if (c != uncolored) k = @max(k, c + 1);
    }
    return k;
}

pub const Order = struct {
    /// Vertices in removal order: each has at most `degeneracy` neighbours after it.
    vertices: []u32,
    degeneracy: u32,

    pub fn deinit(o: Order, gpa: std.mem.Allocator) void {
        gpa.free(o.vertices);
    }
};

/// Repeatedly removes a vertex of least remaining degree, in O(n + m) time. With `random`,
/// ties are broken differently from run to run.
pub fn smallestLast(gpa: std.mem.Allocator, g: Graph, random: ?std.Random) !Order {
    const n: usize = g.n;
    const deg = try gpa.alloc(u32, n);
    defer gpa.free(deg);
    const next = try gpa.alloc(u32, n);
    defer gpa.free(next);
    const prev = try gpa.alloc(u32, n);
    defer gpa.free(prev);
    const removed = try gpa.alloc(bool, n);
    defer gpa.free(removed);
    var max_deg: u32 = 0;
    for (0..n) |v| max_deg = @max(max_deg, g.degree(@intCast(v)));
    const head = try gpa.alloc(u32, @as(usize, max_deg) + 1);
    defer gpa.free(head);
    @memset(head, none);
    @memset(removed, false);

    const insertion = try gpa.alloc(u32, n);
    defer gpa.free(insertion);
    for (insertion, 0..) |*x, v| x.* = @intCast(v);
    if (random) |r| r.shuffle(u32, insertion);

    const Buckets = struct {
        head: []u32,
        next: []u32,
        prev: []u32,
        fn push(b: @This(), d: u32, v: u32) void {
            b.prev[v] = none;
            b.next[v] = b.head[d];
            if (b.head[d] != none) b.prev[b.head[d]] = v;
            b.head[d] = v;
        }
        fn unlink(b: @This(), d: u32, v: u32) void {
            if (b.prev[v] != none) b.next[b.prev[v]] = b.next[v] else b.head[d] = b.next[v];
            if (b.next[v] != none) b.prev[b.next[v]] = b.prev[v];
        }
    };
    const b: Buckets = .{ .head = head, .next = next, .prev = prev };
    var i = n;
    while (i > 0) {
        i -= 1;
        const v = insertion[i];
        deg[v] = g.degree(v);
        b.push(deg[v], v);
    }

    const vertices = try gpa.alloc(u32, n);
    errdefer gpa.free(vertices);
    var degeneracy: u32 = 0;
    var d: u32 = 0;
    for (vertices) |*out| {
        while (head[d] == none) d += 1;
        const v = head[d];
        b.unlink(d, v);
        removed[v] = true;
        out.* = v;
        degeneracy = @max(degeneracy, d);
        for (g.neighbors(v)) |u| {
            if (removed[u]) continue;
            b.unlink(deg[u], u);
            deg[u] -= 1;
            b.push(deg[u], u);
        }
        d -|= 1;
    }
    return .{ .vertices = vertices, .degeneracy = degeneracy };
}

fn usedMask(g: Graph, colors: []const u8, v: u32) u32 {
    var mask: u32 = 0;
    for (g.neighbors(v)) |u| {
        if (colors[u] != uncolored) mask |= @as(u32, 1) << @intCast(colors[u]);
    }
    return mask;
}

fn lowestFree(mask: u32, k: u8) ?u8 {
    const c = @ctz(~mask);
    return if (c < k) @intCast(c) else null;
}

/// Smallest-last greedy colouring of any graph, with at most degeneracy + 1 colours.
pub fn greedy(gpa: std.mem.Allocator, g: Graph) ![]u8 {
    const order = try smallestLast(gpa, g, null);
    defer order.deinit(gpa);
    const colors = try gpa.alloc(u8, g.n);
    @memset(colors, uncolored);
    var i = order.vertices.len;
    while (i > 0) {
        i -= 1;
        const v = order.vertices[i];
        colors[v] = lowestFree(usedMask(g, colors, v), 32).?;
    }
    return colors;
}

/// Chain sizes tried in turn. A small chain that frees a colour is as good as a large one, and
/// two-colour chains in a large triangulation often span most of the graph.
const budgets = [_]usize{ 64, 4096, std.math.maxInt(usize) };

const Chain = enum { reaches, misses, too_big };

/// Kempe chains: the connected pieces of the subgraph coloured with two given colours.
const Kempe = struct {
    g: Graph,
    colors: []u8,
    stamp: []u32,
    epoch: u32 = 0,

    fn init(gpa: std.mem.Allocator, g: Graph, colors: []u8) !Kempe {
        const stamp = try gpa.alloc(u32, g.n);
        @memset(stamp, 0);
        return .{ .g = g, .colors = colors, .stamp = stamp };
    }

    fn deinit(k: *Kempe, gpa: std.mem.Allocator) void {
        gpa.free(k.stamp);
    }

    /// Collects the a/b chain through `from` into `out`. Stops early when the chain reaches
    /// `to` or grows past `limit` vertices; only a chain that `misses` is complete.
    fn chain(k: *Kempe, gpa: std.mem.Allocator, from: u32, a: u8, b: u8, to: u32, limit: usize, out: *std.ArrayList(u32)) !Chain {
        k.epoch += 1;
        out.clearRetainingCapacity();
        try out.append(gpa, from);
        k.stamp[from] = k.epoch;
        var i: usize = 0;
        while (i < out.items.len) : (i += 1) {
            for (k.g.neighbors(out.items[i])) |u| {
                const c = k.colors[u];
                if (k.stamp[u] == k.epoch or (c != a and c != b)) continue;
                if (u == to) return .reaches;
                if (out.items.len == limit) return .too_big;
                k.stamp[u] = k.epoch;
                try out.append(gpa, u);
            }
        }
        return .misses;
    }

    fn flip(k: *Kempe, members: []const u32, a: u8, b: u8) void {
        for (members) |v| k.colors[v] = if (k.colors[v] == a) b else a;
    }
};

/// A 5-colouring of a planar graph, or `error.NotPlanar`.
pub fn five(gpa: std.mem.Allocator, g: Graph) ![]u8 {
    if (!try planarity.isPlanar(gpa, g)) return error.NotPlanar;
    const order = try smallestLast(gpa, g, null);
    defer order.deinit(gpa);
    std.debug.assert(order.degeneracy <= 5);
    const colors = try gpa.alloc(u8, g.n);
    errdefer gpa.free(colors);
    @memset(colors, uncolored);
    var kempe = try Kempe.init(gpa, g, colors);
    defer kempe.deinit(gpa);
    var members: std.ArrayList(u32) = .empty;
    defer members.deinit(gpa);

    var i = order.vertices.len;
    while (i > 0) {
        i -= 1;
        const v = order.vertices[i];
        if (lowestFree(usedMask(g, colors, v), 5)) |c| {
            colors[v] = c;
            continue;
        }
        // Five coloured neighbours with five different colours. In the cyclic order
        // v1..v5 around v, either the 1/3 chain from v1 misses v3 or the 2/4 chain from
        // v2 misses v4, so some pair can be separated.
        var nbrs: [5]u32 = undefined;
        var k: usize = 0;
        for (g.neighbors(v)) |u| if (colors[u] != uncolored) {
            nbrs[k] = u;
            k += 1;
        };
        std.debug.assert(k == 5);
        colors[v] = search: for (budgets) |limit| {
            for (0..5) |x| for (x + 1..5) |y| {
                const a = colors[nbrs[x]];
                const b = colors[nbrs[y]];
                if (try kempe.chain(gpa, nbrs[x], a, b, nbrs[y], limit, &members) != .misses) continue;
                kempe.flip(members.items, a, b);
                break :search a;
            };
        } else unreachable;
    }
    return colors;
}

pub const FourOptions = struct {
    /// Kempe-chain swaps tried in sequence before a vertex counts as stuck.
    depth: u8 = 3,
    /// Further passes with shuffled smallest-last orders after the first one gets stuck.
    restarts: u32 = 16,
    seed: u64 = 0x9e3779b97f4a7c15,
    /// Colour assignments allowed in the exact search that runs when every pass gets stuck.
    search_limit: u64 = 10_000_000,
    /// When set, receives how the colouring was found.
    stats: ?*FourStats = null,
};

pub const FourStats = struct {
    /// Kempe passes run, including the one that succeeded.
    passes: u32 = 0,
    /// Assignments made by the exact search; 0 when a Kempe pass succeeded.
    exact_steps: u64 = 0,
};

/// A 4-colouring of a planar graph, or `error.NotPlanar`, or `error.SearchLimit`.
pub fn four(gpa: std.mem.Allocator, g: Graph, options: FourOptions) ![]u8 {
    if (!try planarity.isPlanar(gpa, g)) return error.NotPlanar;
    const colors = try gpa.alloc(u8, g.n);
    errdefer gpa.free(colors);
    var stats: FourStats = .{};
    defer if (options.stats) |s| {
        s.* = stats;
    };
    var prng = std.Random.DefaultPrng.init(options.seed);
    while (stats.passes <= options.restarts) {
        const order = try smallestLast(gpa, g, if (stats.passes == 0) null else prng.random());
        defer order.deinit(gpa);
        stats.passes += 1;
        if (try kempePass(gpa, g, order.vertices, colors, options.depth)) return colors;
    }
    stats.exact_steps = try exact(gpa, g, colors, 4, options.search_limit);
    return colors;
}

fn kempePass(gpa: std.mem.Allocator, g: Graph, order: []const u32, colors: []u8, depth: u8) !bool {
    @memset(colors, uncolored);
    const levels = try gpa.alloc(std.ArrayList(u32), depth);
    for (levels) |*l| l.* = .empty;
    var search: Search = .{ .g = g, .kempe = Kempe.init(gpa, g, colors) catch |e| {
        gpa.free(levels);
        return e;
    }, .levels = levels };
    defer search.deinit(gpa);
    var i = order.len;
    while (i > 0) {
        i -= 1;
        const v = order[i];
        colors[v] = lowestFree(usedMask(g, colors, v), 4) orelse found: {
            for (budgets) |limit| for (1..@as(usize, depth) + 1) |d| {
                search.limit = limit;
                search.depth = d;
                if (try search.free(gpa, v, 0)) break :found lowestFree(usedMask(g, colors, v), 4).?;
            };
            return false;
        };
    }
    return true;
}

/// Depth-limited search over Kempe-chain swaps until some colour is missing around `v`.
const Search = struct {
    g: Graph,
    kempe: Kempe,
    levels: []std.ArrayList(u32),
    depth: usize = 0,
    limit: usize = 0,

    fn deinit(s: *Search, gpa: std.mem.Allocator) void {
        for (s.levels) |*l| l.deinit(gpa);
        gpa.free(s.levels);
        s.kempe.deinit(gpa);
    }

    fn free(s: *Search, gpa: std.mem.Allocator, v: u32, level: usize) !bool {
        const colors = s.kempe.colors;
        if (lowestFree(usedMask(s.g, colors, v), 4) != null) return true;
        if (level == s.depth) return false;
        const members = &s.levels[level];
        for (s.g.neighbors(v)) |u| {
            const a = colors[u];
            if (a == uncolored) continue;
            for (0..4) |bi| {
                const b: u8 = @intCast(bi);
                if (b == a) continue;
                if (try s.kempe.chain(gpa, u, a, b, none, s.limit, members) == .too_big) continue;
                s.kempe.flip(members.items, a, b);
                if (try s.free(gpa, v, level + 1)) return true;
                s.kempe.flip(members.items, a, b);
            }
        }
        return false;
    }
};

/// Exact backtracking search in DSATUR order (Brélaz 1979), with a limit on assignments.
fn exact(gpa: std.mem.Allocator, g: Graph, colors: []u8, k: u8, limit: u64) !u64 {
    @memset(colors, uncolored);
    const seen = try gpa.alloc([4]u32, g.n);
    defer gpa.free(seen);
    @memset(seen, @splat(0));
    const Frame = struct { v: u32, next: u8 };
    var frames: std.ArrayList(Frame) = .empty;
    defer frames.deinit(gpa);
    var steps: u64 = 0;

    outer: while (true) {
        var best: u32 = none;
        var best_sat: u32 = 0;
        var best_deg: u32 = 0;
        for (0..g.n) |vi| {
            const v: u32 = @intCast(vi);
            if (colors[v] != uncolored) continue;
            var sat: u32 = 0;
            for (seen[v][0..k]) |x| sat += @intFromBool(x > 0);
            if (best == none or sat > best_sat or (sat == best_sat and g.degree(v) > best_deg)) {
                best = v;
                best_sat = sat;
                best_deg = g.degree(v);
            }
        }
        if (best == none) return steps;
        try frames.append(gpa, .{ .v = best, .next = 0 });
        while (frames.items.len > 0) {
            const f = &frames.items[frames.items.len - 1];
            var c = f.next;
            while (c < k and seen[f.v][c] > 0) c += 1;
            if (c < k) {
                steps += 1;
                if (steps > limit) return error.SearchLimit;
                colors[f.v] = c;
                for (g.neighbors(f.v)) |u| seen[u][c] += 1;
                f.next = c + 1;
                continue :outer;
            }
            _ = frames.pop();
            if (frames.items.len == 0) return error.NotColorable;
            const p = frames.items[frames.items.len - 1].v;
            for (g.neighbors(p)) |u| seen[u][colors[p]] -= 1;
            colors[p] = uncolored;
        }
    }
}

fn icosahedron(gpa: std.mem.Allocator) !Graph {
    return Graph.init(gpa, 12, &.{
        .{ 0, 1 },  .{ 0, 2 },  .{ 0, 3 },  .{ 0, 4 },  .{ 0, 5 },
        .{ 1, 2 },  .{ 2, 3 },  .{ 3, 4 },  .{ 4, 5 },  .{ 5, 1 },
        .{ 1, 6 },  .{ 2, 6 },  .{ 2, 7 },  .{ 3, 7 },  .{ 3, 8 },
        .{ 4, 8 },  .{ 4, 9 },  .{ 5, 9 },  .{ 5, 10 }, .{ 1, 10 },
        .{ 6, 7 },  .{ 7, 8 },  .{ 8, 9 },  .{ 9, 10 }, .{ 10, 6 },
        .{ 11, 6 }, .{ 11, 7 }, .{ 11, 8 }, .{ 11, 9 }, .{ 11, 10 },
    });
}

test "icosahedron: greedy, five and four colourings" {
    const gpa = std.testing.allocator;
    const g = try icosahedron(gpa);
    defer g.deinit(gpa);
    const order = try smallestLast(gpa, g, null);
    defer order.deinit(gpa);
    try std.testing.expectEqual(5, order.degeneracy);

    const c6 = try greedy(gpa, g);
    defer gpa.free(c6);
    try std.testing.expect(isProper(g, c6, 6));
    const c5 = try five(gpa, g);
    defer gpa.free(c5);
    try std.testing.expect(isProper(g, c5, 5));
    const c4 = try four(gpa, g, .{});
    defer gpa.free(c4);
    try std.testing.expect(isProper(g, c4, 4));
}

test "the exact search alone 4-colours the icosahedron" {
    const gpa = std.testing.allocator;
    const g = try icosahedron(gpa);
    defer g.deinit(gpa);
    const colors = try gpa.alloc(u8, g.n);
    defer gpa.free(colors);
    _ = try exact(gpa, g, colors, 4, 1_000_000);
    try std.testing.expect(isProper(g, colors, 4));
    try std.testing.expectError(error.NotColorable, exact(gpa, g, colors, 3, 1_000_000));
}

test "non-planar input is refused" {
    const gpa = std.testing.allocator;
    var edges: [10]graph_mod.Edge = undefined;
    var k: usize = 0;
    for (0..5) |i| for (i + 1..5) |j| {
        edges[k] = .{ @intCast(i), @intCast(j) };
        k += 1;
    };
    const g = try Graph.init(gpa, 5, &edges);
    defer g.deinit(gpa);
    try std.testing.expectError(error.NotPlanar, five(gpa, g));
    try std.testing.expectError(error.NotPlanar, four(gpa, g, .{}));
}
