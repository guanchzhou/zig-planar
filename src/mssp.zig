//! Multiple-source shortest paths in planar graphs (Klein 2005).
//!
//! `trees` takes a planar embedding, a nonnegative length for every dart and one face, and
//! returns a shortest-path tree rooted at every vertex of that face, in O(n log n) time. The
//! answer is stored compactly: the tree for the first boundary vertex, then for each later
//! boundary vertex only the vertices whose parent changes. Klein shows that every dart enters
//! the tree at most once as the root goes around the face, so there are O(n) changes in total.
//!
//! The source moves around the face continuously. A vertex `x` is placed inside the face and
//! joined to every corner of it by a spoke; moving from boundary vertex i to i + 1 lengthens
//! spoke i from 0 and shortens spoke i + 1 to 0. Vertices whose shortest path still uses spoke
//! i are red, the others blue. Only darts from blue to red get tighter, and they lie on one
//! path in the dual tree of the non-tree edges, which is kept in a link-cut tree. Each change
//! of parent is one search of that path for its tightest dart.
//!
//! The correctness argument followed here is Klein's simplified analysis, arXiv:2610.02371.

const std = @import("std");
const graph = @import("graph.zig");
const Graph = graph.Graph;
const Embedding = @import("embedding.zig").Embedding;
const linkcut = @import("linkcut.zig");

const none = graph.none;
const inf = linkcut.inf;

/// Lengths may add up to at most this, so that every slack fits in an i64.
pub const max_total_length: u64 = 1 << 58;

pub const Trees = struct {
    /// The vertices of the boundary face in order, starting at the tail of the given dart. A
    /// vertex that the face visits more than once appears more than once.
    boundary: []u32,
    /// The tree rooted at `boundary[0]`: the half-edge into every vertex from its parent, or
    /// `none` at the root.
    parent: []u32,
    /// Moving the root from `boundary[i]` to `boundary[i + 1]` gives `vertex[j]` the parent
    /// half-edge `to[j]` (`none` for the new root) for j in `step[i]..step[i + 1]`.
    step: []u32,
    vertex: []u32,
    to: []u32,

    pub fn deinit(t: Trees, gpa: std.mem.Allocator) void {
        gpa.free(t.boundary);
        gpa.free(t.parent);
        gpa.free(t.step);
        gpa.free(t.vertex);
        gpa.free(t.to);
    }

    /// The total number of parent changes over all steps.
    pub fn changeCount(t: Trees) usize {
        return t.vertex.len;
    }
};

/// The trees of `Trees` one root at a time, each as a parent array.
pub const Walk = struct {
    trees: *const Trees,
    index: usize = 0,
    parent: []u32,

    pub fn init(gpa: std.mem.Allocator, t: *const Trees) !Walk {
        return .{ .trees = t, .parent = try gpa.dupe(u32, t.parent) };
    }

    pub fn deinit(w: Walk, gpa: std.mem.Allocator) void {
        gpa.free(w.parent);
    }

    pub fn root(w: Walk) u32 {
        return w.trees.boundary[w.index];
    }

    /// Moves to the next boundary vertex. Returns false after the last one.
    pub fn next(w: *Walk) bool {
        const t = w.trees;
        if (w.index + 1 >= t.boundary.len) return false;
        for (t.step[w.index]..t.step[w.index + 1]) |j| w.parent[t.vertex[j]] = t.to[j];
        w.index += 1;
        return true;
    }
};

/// Distances from the root of the tree given by `parent` (half-edges of `g`, `none` at the
/// root), using the dart lengths `lengths`. Returns `error.NotATree` if following parents
/// loops or a half-edge does not lead into its vertex.
pub fn distances(gpa: std.mem.Allocator, g: Graph, lengths: []const u32, parent: []const u32, out: []u64) !void {
    const state = try gpa.alloc(u8, g.n);
    defer gpa.free(state);
    @memset(state, 0);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    for (0..g.n) |s| {
        var v: u32 = @intCast(s);
        stack.clearRetainingCapacity();
        while (state[v] == 0) {
            state[v] = 1;
            const h = parent[v];
            if (h == none) {
                out[v] = 0;
                state[v] = 2;
                break;
            }
            if (h >= g.adj.len or g.adj[h] != v) return error.NotATree;
            try stack.append(gpa, v);
            v = g.from[h];
        }
        if (state[v] == 1) return error.NotATree;
        while (stack.pop()) |w| {
            out[w] = out[g.from[parent[w]]] + lengths[parent[w]];
            state[w] = 2;
        }
    }
}

/// The graph with the extra vertex x inside the boundary face. Darts of g keep their order
/// around each vertex; spoke j enters the j-th corner of the face, between the dart arriving
/// along the face and the dart leaving along it. x lists its spokes in decreasing order, so
/// the face of the dart leaving corner j is the triangle corner j, corner j + 1, x.
const Spoked = struct {
    x: u32,
    start: []u32,
    head: []u32,
    rev: []u32,
    /// The half-edge of g for a dart of g, `none` for a spoke.
    half: []u32,
    /// The dart of each position of the embedding.
    id: []u32,
    /// Spoke darts out of and into x, by corner.
    out: []u32,
    in: []u32,
    face: []u32,
    face_start: []u32,
    face_darts: []u32,
    edge: []u32,
    edge_count: u32,

    fn tail(s: Spoked, d: u32) u32 {
        return s.head[s.rev[d]];
    }

    fn next(s: Spoked, d: u32) u32 {
        const r = s.rev[d];
        const w = s.head[d];
        return if (r + 1 == s.start[w + 1]) s.start[w] else r + 1;
    }

    fn faceCount(s: Spoked) u32 {
        return @intCast(s.face_start.len - 1);
    }

    fn init(arena: std.mem.Allocator, g: Graph, e: Embedding, walk: []const u32) !Spoked {
        const n = g.n;
        const k: u32 = @intCast(walk.len);
        const darts = g.adj.len;
        const total = darts + 2 * @as(usize, k);
        const spoke_after = try arena.alloc(u32, darts);
        @memset(spoke_after, none);
        for (0..k) |j| spoke_after[e.rev[walk[(j + k - 1) % k]]] = @intCast(j);

        var s: Spoked = .{
            .x = n,
            .start = try arena.alloc(u32, @as(usize, n) + 2),
            .head = try arena.alloc(u32, total),
            .rev = try arena.alloc(u32, total),
            .half = try arena.alloc(u32, total),
            .id = try arena.alloc(u32, darts),
            .out = try arena.alloc(u32, k),
            .in = try arena.alloc(u32, k),
            .face = try arena.alloc(u32, total),
            .face_start = undefined,
            .face_darts = try arena.alloc(u32, total),
            .edge = try arena.alloc(u32, total),
            .edge_count = 0,
        };
        const id = s.id;
        const corner = try arena.alloc(u32, k);
        var c: u32 = 0;
        for (0..n) |v| {
            s.start[v] = c;
            for (e.start[v]..e.start[v + 1]) |q| {
                id[q] = c;
                s.head[c] = e.rotation[q];
                s.half[c] = g.halfEdge(@intCast(v), e.rotation[q]) orelse return error.WrongEmbedding;
                c += 1;
                const j = spoke_after[q];
                if (j != none) {
                    s.in[j] = c;
                    corner[j] = @intCast(v);
                    s.head[c] = s.x;
                    s.half[c] = none;
                    c += 1;
                }
            }
        }
        s.start[n] = c;
        for (0..k) |i| {
            const j = k - 1 - @as(u32, @intCast(i));
            s.out[j] = c;
            s.head[c] = corner[j];
            s.half[c] = none;
            c += 1;
        }
        s.start[n + 1] = c;
        for (0..n) |v| {
            for (e.start[v]..e.start[v + 1]) |q| s.rev[id[q]] = id[e.rev[q]];
        }
        for (s.in, s.out) |a, b| {
            s.rev[a] = b;
            s.rev[b] = a;
        }

        @memset(s.face, none);
        var starts: std.ArrayList(u32) = .empty;
        try starts.append(arena, 0);
        var traced: u32 = 0;
        var faces: u32 = 0;
        for (0..total) |i| {
            if (s.face[i] != none) continue;
            var d: u32 = @intCast(i);
            while (s.face[d] == none) : (d = s.next(d)) {
                s.face[d] = faces;
                s.face_darts[traced] = d;
                traced += 1;
            }
            try starts.append(arena, traced);
            faces += 1;
        }
        s.face_start = starts.items;

        @memset(s.edge, none);
        for (0..total) |i| {
            if (s.edge[i] != none) continue;
            s.edge[i] = s.edge_count;
            s.edge[s.rev[i]] = s.edge_count;
            s.edge_count += 1;
        }
        return s;
    }
};

/// Shortest-path trees rooted at every vertex of one face of the planar embedding `e` of `g`.
/// `lengths[h]` is the length of half-edge h (from `g.from[h]` to `g.adj[h]`); give both
/// half-edges of an edge the same length for an undirected graph. The face is the one traced
/// from the dart `boundary[0] -> boundary[1]`, as in `Embedding.faces`. The graph must be
/// connected.
pub fn trees(gpa: std.mem.Allocator, g: Graph, e: Embedding, lengths: []const u32, boundary: [2]u32) !Trees {
    if (lengths.len != g.adj.len) return error.WrongLengthCount;
    if (e.vertexCount() != g.n or e.rotation.len != g.adj.len) return error.WrongEmbedding;
    if (boundary[0] >= g.n or boundary[1] >= g.n) return error.NotAnEdge;
    if (try e.genus(gpa) != 0) return error.NotPlanar;
    var total: u64 = 0;
    for (lengths) |l| total += l;
    if (total > max_total_length) return error.LengthOverflow;
    // Longer than any path in g.
    const big: i64 = @intCast(total + 1);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const n = g.n;

    const first: u32 = for (e.start[boundary[0]]..e.start[boundary[0] + 1]) |q| {
        if (e.rotation[q] == boundary[1]) break @intCast(q);
    } else return error.NotAnEdge;
    var walk: std.ArrayList(u32) = .empty;
    var d: u32 = first;
    while (true) {
        try walk.append(arena, d);
        d = e.nextDart(d);
        if (d == first) break;
    }
    const k: u32 = @intCast(walk.items.len);

    const s = try Spoked.init(arena, g, e, walk.items);
    const x = s.x;
    const nf = s.faceCount();
    const len = struct {
        fn of(sp: Spoked, lens: []const u32, dart: u32) i64 {
            return lens[sp.half[dart]];
        }
    }.of;

    // The first tree: Dijkstra from corner 0, hung from x by spoke 0.
    const b0 = s.head[s.out[0]];
    const dist = try arena.alloc(u64, n);
    @memset(dist, std.math.maxInt(u64));
    const par = try arena.alloc(u32, n);
    {
        const Item = struct { d: u64, v: u32 };
        var queue: std.PriorityQueue(Item, void, struct {
            fn order(_: void, a: Item, b: Item) std.math.Order {
                return std.math.order(a.d, b.d);
            }
        }.order) = .empty;
        try queue.push(arena, .{ .d = 0, .v = b0 });
        dist[b0] = 0;
        while (queue.pop()) |it| {
            if (it.d != dist[it.v]) continue;
            for (s.start[it.v]..s.start[it.v + 1]) |i| {
                if (s.half[i] == none) continue;
                const w = s.head[i];
                const nd = it.d + lengths[s.half[i]];
                if (nd < dist[w]) {
                    dist[w] = nd;
                    par[w] = @intCast(i);
                    try queue.push(arena, .{ .d = nd, .v = w });
                }
            }
        }
    }
    for (dist) |dv| if (dv == std.math.maxInt(u64)) return error.Disconnected;
    par[b0] = s.out[0];

    const in_tree = try arena.alloc(bool, s.edge_count);
    @memset(in_tree, false);
    for (par) |pd| in_tree[s.edge[pd]] = true;
    const first_parent = try gpa.alloc(u32, n);
    errdefer gpa.free(first_parent);
    for (par, first_parent) |pd, *fp| fp.* = s.half[pd];

    // The slack of dart u -> v is dist(u) + length - dist(v): zero on tree darts, never
    // negative. Darts into x never help, and every spoke but spoke 0 starts infinitely long.
    var f = try linkcut.Forest.init(gpa, @as(usize, nf) + s.edge_count);
    defer f.deinit(gpa);
    {
        const slack = struct {
            fn of(sp: Spoked, lens: []const u32, ds: []const u64, dart: u32) i64 {
                if (sp.head[dart] == sp.x or sp.half[dart] == none) return inf;
                return @as(i64, @intCast(ds[sp.tail(dart)])) + lens[sp.half[dart]] - @as(i64, @intCast(ds[sp.head[dart]]));
            }
        }.of;
        // The non-tree edges cross between faces as a spanning tree of the dual. Hang it from
        // face 0; an edge node's value 0 is the dart pointing into the face below it.
        const seen = try arena.alloc(bool, nf);
        @memset(seen, false);
        const linked = try arena.alloc(bool, s.edge_count);
        @memset(linked, false);
        var queue: std.ArrayList(u32) = .empty;
        try queue.append(arena, 0);
        seen[0] = true;
        var qi: usize = 0;
        while (qi < queue.items.len) : (qi += 1) {
            const a = queue.items[qi];
            for (s.face_darts[s.face_start[a]..s.face_start[a + 1]]) |dart| {
                const ed = s.edge[dart];
                if (in_tree[ed] or linked[ed]) continue;
                const back = s.rev[dart];
                const b = s.face[back];
                std.debug.assert(!seen[b]);
                linked[ed] = true;
                seen[b] = true;
                const node = nf + ed;
                f.nodes[node].val = .{ slack(s, lengths, dist, back), slack(s, lengths, dist, dart) };
                f.nodes[node].item = .{ back, dart };
                f.refresh(node);
                f.nodes[node].up = a;
                f.nodes[b].up = node;
                try queue.append(arena, b);
            }
        }
        std.debug.assert(queue.items.len == nf);
    }

    const Slacks = struct {
        f: linkcut.Forest,
        s: Spoked,

        // After evert(face[d]) and access, the edge node's predecessor on the path is face[d],
        // so the slack of non-tree dart d is value 1.
        fn node(c: @This(), dart: u32) u32 {
            const at = c.s.faceCount() + c.s.edge[dart];
            c.f.evert(c.s.face[dart]);
            c.f.access(at);
            std.debug.assert(c.f.nodes[at].item[1] == dart);
            return at;
        }

        fn get(c: @This(), dart: u32) i64 {
            return c.f.nodes[c.node(dart)].val[1];
        }

        fn set(c: @This(), dart: u32, value: i64) void {
            const at = c.node(dart);
            c.f.nodes[at].val[1] = value;
            c.f.refresh(at);
        }
    };
    const slacks: Slacks = .{ .f = f, .s = s };

    var step: std.ArrayList(u32) = .empty;
    defer step.deinit(gpa);
    var vertex: std.ArrayList(u32) = .empty;
    defer vertex.deinit(gpa);
    var to: std.ArrayList(u32) = .empty;
    defer to.deinit(gpa);
    try step.append(gpa, 0);

    for (0..k - 1) |i| {
        const here = s.head[s.out[i]];
        std.debug.assert(par[here] == s.out[i]);
        if (i > 0) slacks.set(s.out[i - 1], inf);
        // Spoke i + 1 becomes `big` long. The boundary dart from corner i gives the distance
        // to corner i + 1 from its slack, since corner i is at distance 0.
        const dart = s.id[walk.items[i]];
        const tight = in_tree[s.edge[dart]];
        std.debug.assert(!tight or par[s.head[dart]] == dart);
        const to_next = len(s, lengths, dart) - (if (tight) 0 else slacks.get(dart));
        slacks.set(s.out[i + 1], big - to_next);

        // Over the step spoke i grows from 0 to big and spoke i + 1 shrinks to 0, which takes
        // 2 * big off every blue-to-red slack and adds it to the reverse darts.
        var elapsed: i64 = 0;
        while (true) {
            const r = f.path(s.face[s.out[i]], s.face[s.out[i + 1]]);
            const m = f.nodes[r].min[0];
            const left = 2 * big - elapsed;
            if (m == inf or m >= left) {
                f.shift(r, .{ -left, left });
                break;
            }
            const at = f.nodes[r].arg[0];
            f.shift(r, .{ -m, m });
            elapsed += m;
            f.splay(at);
            std.debug.assert(f.nodes[at].val[0] == 0);
            const a = f.nodes[at].item[0];

            // Dart a now gives its head v a shortest path through blue. It replaces v's parent
            // dart, which leaves the tree tight.
            const v = s.head[a];
            const old = par[v];
            f.cut(at, s.face[a]);
            f.cut(at, s.face[s.rev[a]]);
            in_tree[s.edge[a]] = true;
            in_tree[s.edge[old]] = false;
            par[v] = a;

            const back = s.rev[old];
            const out = nf + s.edge[old];
            f.nodes[out] = .{};
            f.link(out, s.face[back]);
            f.access(out);
            f.nodes[out].val = .{ 0, if (s.head[back] == x) inf else len(s, lengths, old) + len(s, lengths, back) };
            f.nodes[out].item = .{ old, back };
            f.refresh(out);
            f.link(s.face[old], out);

            try vertex.append(gpa, v);
            try to.append(gpa, s.half[a]);
        }
        try step.append(gpa, @intCast(vertex.items.len));
    }

    const corners = try gpa.alloc(u32, k);
    errdefer gpa.free(corners);
    for (corners, s.out) |*cv, o| cv.* = s.head[o];
    const steps = try step.toOwnedSlice(gpa);
    errdefer gpa.free(steps);
    const vertices = try vertex.toOwnedSlice(gpa);
    errdefer gpa.free(vertices);
    return .{
        .boundary = corners,
        .parent = first_parent,
        .step = steps,
        .vertex = vertices,
        .to = try to.toOwnedSlice(gpa),
    };
}

fn bellmanFord(g: Graph, lengths: []const u32, source: u32, out: []u64) void {
    @memset(out, std.math.maxInt(u64));
    out[source] = 0;
    for (0..g.n) |_| {
        for (g.from, g.adj, lengths) |u, v, l| {
            if (out[u] != std.math.maxInt(u64) and out[u] + l < out[v]) out[v] = out[u] + l;
        }
    }
}

fn expectShortest(gpa: std.mem.Allocator, g: Graph, lengths: []const u32, t: *const Trees) !void {
    var w = try Walk.init(gpa, t);
    defer w.deinit(gpa);
    const got = try gpa.alloc(u64, g.n);
    defer gpa.free(got);
    const want = try gpa.alloc(u64, g.n);
    defer gpa.free(want);
    while (true) {
        try std.testing.expectEqual(none, w.parent[w.root()]);
        try distances(gpa, g, lengths, w.parent, got);
        bellmanFord(g, lengths, w.root(), want);
        try std.testing.expectEqualSlices(u64, want, got);
        if (!w.next()) break;
    }
}

const planarity = @import("planarity.zig");

fn expectEveryFace(gpa: std.mem.Allocator, g: Graph, lengths: []const u32) !void {
    const e = (try planarity.embed(gpa, g)).?;
    defer e.deinit(gpa);
    const faces = try e.faces(gpa);
    defer faces.deinit(gpa);
    for (0..faces.count()) |i| {
        const cycle = faces.get(i);
        const t = try trees(gpa, g, e, lengths, .{ cycle[0], cycle[1] });
        defer t.deinit(gpa);
        try std.testing.expectEqualSlices(u32, cycle, t.boundary);
        try expectShortest(gpa, g, lengths, &t);
    }
}

fn expectRandomLengths(n: u32, edges: []const graph.Edge, seed: u64, max_len: u32) !void {
    const gpa = std.testing.allocator;
    const g = try Graph.init(gpa, n, edges);
    defer g.deinit(gpa);
    const lengths = try gpa.alloc(u32, g.adj.len);
    defer gpa.free(lengths);
    var prng = std.Random.DefaultPrng.init(seed);
    for (0..g.adj.len) |h| {
        if (g.from[h] < g.adj[h]) {
            lengths[h] = prng.random().uintAtMost(u32, max_len);
            lengths[g.twin[h]] = lengths[h];
        }
    }
    try expectEveryFace(gpa, g, lengths);
}

test "a square with one diagonal, from every face" {
    try expectRandomLengths(4, &.{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 3, 0 }, .{ 0, 2 } }, 1, 9);
}

test "a single edge" {
    try expectRandomLengths(2, &.{.{ 0, 1 }}, 2, 5);
}

test "a tree, whose only face visits vertices more than once" {
    try expectRandomLengths(6, &.{ .{ 0, 1 }, .{ 1, 2 }, .{ 1, 3 }, .{ 3, 4 }, .{ 3, 5 } }, 3, 7);
}

test "a grid with distinct, equal and zero lengths" {
    const gpa = std.testing.allocator;
    var edges: std.ArrayList(graph.Edge) = .empty;
    defer edges.deinit(gpa);
    const w = 6;
    const h = 5;
    for (0..h) |r| {
        for (0..w) |col| {
            const v: u32 = @intCast(r * w + col);
            if (col + 1 < w) try edges.append(gpa, .{ v, v + 1 });
            if (r + 1 < h) try edges.append(gpa, .{ v, v + w });
        }
    }
    try expectRandomLengths(w * h, edges.items, 4, 20);
    try expectRandomLengths(w * h, edges.items, 5, 1);
    try expectRandomLengths(w * h, edges.items, 6, 0);
}

test "different lengths in the two directions" {
    const gpa = std.testing.allocator;
    const g = try Graph.init(gpa, 5, &.{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 3, 4 }, .{ 4, 0 }, .{ 0, 2 }, .{ 0, 3 } });
    defer g.deinit(gpa);
    const lengths = try gpa.alloc(u32, g.adj.len);
    defer gpa.free(lengths);
    for (lengths, g.from, g.adj) |*l, u, v| l.* = if (u < v) 1 else 10 + u + v;
    try expectEveryFace(gpa, g, lengths);
}

test "errors: not an edge, disconnected, not planar" {
    const gpa = std.testing.allocator;
    const g = try Graph.init(gpa, 4, &.{ .{ 0, 1 }, .{ 2, 3 } });
    defer g.deinit(gpa);
    const e = (try planarity.embed(gpa, g)).?;
    defer e.deinit(gpa);
    const lengths: [4]u32 = @splat(1);
    try std.testing.expectError(error.NotAnEdge, trees(gpa, g, e, &lengths, .{ 0, 2 }));
    try std.testing.expectError(error.Disconnected, trees(gpa, g, e, &lengths, .{ 0, 1 }));

    const k4 = try Graph.init(gpa, 4, &.{ .{ 0, 1 }, .{ 0, 2 }, .{ 0, 3 }, .{ 1, 2 }, .{ 1, 3 }, .{ 2, 3 } });
    defer k4.deinit(gpa);
    const torus = try Embedding.fromRotation(gpa, k4, &.{ &.{ 1, 2, 3 }, &.{ 0, 2, 3 }, &.{ 0, 1, 3 }, &.{ 0, 1, 2 } });
    defer torus.deinit(gpa);
    const twelve: [12]u32 = @splat(1);
    try std.testing.expectError(error.NotPlanar, trees(gpa, k4, torus, &twelve, .{ 0, 1 }));
}
