//! The left-right planarity test with embedding (de Fraysseix and Rosenstiehl; Brandes 2009).
//!
//! Three depth-first passes: orientation (heights, low points, nesting depths), testing
//! (conflict pairs of return edges) and embedding (signs of the edges, then the cyclic orders).
//! The passes are iterative, so the depth of the graph is limited by memory, not by the stack.
//! Time and memory are linear in the size of the graph.

const std = @import("std");
const graph_mod = @import("graph.zig");
const Graph = graph_mod.Graph;
const none = graph_mod.none;
const Embedding = @import("embedding.zig").Embedding;

/// A planar embedding of `g`, or null when `g` is not planar.
pub fn embed(gpa: std.mem.Allocator, g: Graph) !?Embedding {
    var s = try State.init(gpa, g);
    defer s.deinit();
    return s.run();
}

pub fn isPlanar(gpa: std.mem.Allocator, g: Graph) !bool {
    const e = try embed(gpa, g) orelse return false;
    e.deinit(gpa);
    return true;
}

const Interval = struct {
    low: u32 = none,
    high: u32 = none,

    fn empty(i: Interval) bool {
        return i.low == none and i.high == none;
    }
};

const Pair = struct {
    left: Interval = .{},
    right: Interval = .{},

    fn swap(p: *Pair) void {
        std.mem.swap(Interval, &p.left, &p.right);
    }
};

const State = struct {
    gpa: std.mem.Allocator,
    g: Graph,
    // Per vertex.
    height: []u32,
    parent_edge: []u32,
    it: []u32,
    returning: []bool,
    ord_start: []u32,
    left_ref: []u32,
    right_ref: []u32,
    first: []u32,
    // Per half-edge.
    oriented: []bool,
    lowpt: []u32,
    lowpt2: []u32,
    nesting: []i64,
    ref: []u32,
    side: []i8,
    lowpt_edge: []u32,
    stack_bottom: []u32,
    ord: []u32,
    cw: []u32,
    ccw: []u32,
    // Stacks.
    conflicts: std.ArrayList(Pair) = .empty,
    dfs: std.ArrayList(u32) = .empty,
    chain: std.ArrayList(u32) = .empty,
    roots: std.ArrayList(u32) = .empty,

    fn init(gpa: std.mem.Allocator, g: Graph) !State {
        const n: usize = g.n;
        const m2 = g.adj.len;
        var s: State = undefined;
        s.gpa = gpa;
        s.g = g;
        s.conflicts = .empty;
        s.dfs = .empty;
        s.chain = .empty;
        s.roots = .empty;
        inline for (.{ "height", "parent_edge", "it", "left_ref", "right_ref", "first" }) |name| {
            @field(s, name) = try gpa.alloc(u32, n);
        }
        s.returning = try gpa.alloc(bool, n);
        s.ord_start = try gpa.alloc(u32, n + 1);
        s.oriented = try gpa.alloc(bool, m2);
        inline for (.{ "lowpt", "lowpt2", "ref", "lowpt_edge", "stack_bottom", "ord", "cw", "ccw" }) |name| {
            @field(s, name) = try gpa.alloc(u32, m2);
        }
        s.nesting = try gpa.alloc(i64, m2);
        s.side = try gpa.alloc(i8, m2);
        @memset(s.height, none);
        @memset(s.parent_edge, none);
        @memset(s.it, 0);
        @memset(s.returning, false);
        @memset(s.first, none);
        @memset(s.oriented, false);
        @memset(s.ref, none);
        @memset(s.side, 1);
        @memset(s.lowpt_edge, none);
        return s;
    }

    fn deinit(s: *State) void {
        const gpa = s.gpa;
        inline for (.{
            "height",     "parent_edge",  "it",    "returning", "ord_start", "left_ref", "right_ref",
            "first",      "oriented",     "lowpt", "lowpt2",    "nesting",   "ref",      "side",
            "lowpt_edge", "stack_bottom", "ord",   "cw",        "ccw",
        }) |name| gpa.free(@field(s, name));
        s.conflicts.deinit(gpa);
        s.dfs.deinit(gpa);
        s.chain.deinit(gpa);
        s.roots.deinit(gpa);
    }

    fn run(s: *State) !?Embedding {
        const g = s.g;
        if (g.n > 2 and g.edgeCount() > 3 * @as(usize, g.n) - 6) return null;

        for (0..g.n) |v| {
            if (s.height[v] != none) continue;
            try s.roots.append(s.gpa, @intCast(v));
            try s.orientation(@intCast(v));
        }

        s.buildOrder();
        s.sortOrder();
        @memset(s.it, 0);
        @memset(s.returning, false);
        for (s.roots.items) |r| if (!try s.testing(r)) return null;

        for (0..g.adj.len) |h| {
            if (s.oriented[h]) s.nesting[h] *= try s.sign(@intCast(h));
        }
        s.sortOrder();
        for (0..g.n) |v| {
            var prev: u32 = none;
            for (s.ord[s.ord_start[v]..s.ord_start[v + 1]]) |h| {
                s.addCw(@intCast(v), h, prev);
                prev = h;
            }
        }
        @memset(s.it, 0);
        for (s.roots.items) |r| try s.embedding(r);
        return try s.result();
    }

    fn orientation(s: *State, root: u32) !void {
        const g = s.g;
        s.height[root] = 0;
        try s.dfs.append(s.gpa, root);
        while (s.dfs.items.len > 0) {
            const v = s.dfs.items[s.dfs.items.len - 1];
            if (s.it[v] == g.degree(v)) {
                _ = s.dfs.pop();
                continue;
            }
            const h = g.start[v] + s.it[v];
            const w = g.adj[h];
            if (s.returning[v]) {
                s.returning[v] = false;
            } else {
                if (s.oriented[h] or s.oriented[g.twin[h]]) {
                    s.it[v] += 1;
                    continue;
                }
                s.oriented[h] = true;
                s.lowpt[h] = s.height[v];
                s.lowpt2[h] = s.height[v];
                if (s.height[w] == none) {
                    s.parent_edge[w] = h;
                    s.height[w] = s.height[v] + 1;
                    s.returning[v] = true;
                    try s.dfs.append(s.gpa, w);
                    continue;
                }
                s.lowpt[h] = s.height[w];
            }
            s.nesting[h] = 2 * @as(i64, s.lowpt[h]) + @intFromBool(s.lowpt2[h] < s.height[v]);
            const e = s.parent_edge[v];
            if (e != none) {
                if (s.lowpt[h] < s.lowpt[e]) {
                    s.lowpt2[e] = @min(s.lowpt[e], s.lowpt2[h]);
                    s.lowpt[e] = s.lowpt[h];
                } else if (s.lowpt[h] > s.lowpt[e]) {
                    s.lowpt2[e] = @min(s.lowpt2[e], s.lowpt[h]);
                } else {
                    s.lowpt2[e] = @min(s.lowpt2[e], s.lowpt2[h]);
                }
            }
            s.it[v] += 1;
        }
    }

    /// Outgoing oriented half-edges of each vertex, in `ord[ord_start[v]..ord_start[v + 1]]`.
    fn buildOrder(s: *State) void {
        const g = s.g;
        var k: u32 = 0;
        for (0..g.n) |v| {
            s.ord_start[v] = k;
            for (g.start[v]..g.start[v + 1]) |h| {
                if (!s.oriented[h]) continue;
                s.ord[k] = @intCast(h);
                k += 1;
            }
        }
        s.ord_start[g.n] = k;
    }

    fn sortOrder(s: *State) void {
        for (0..s.g.n) |v| {
            std.mem.sort(u32, s.ord[s.ord_start[v]..s.ord_start[v + 1]], s.nesting, struct {
                fn less(nesting: []const i64, a: u32, b: u32) bool {
                    return nesting[a] < nesting[b];
                }
            }.less);
        }
    }

    fn top(s: *State) ?*Pair {
        if (s.conflicts.items.len == 0) return null;
        return &s.conflicts.items[s.conflicts.items.len - 1];
    }

    fn conflicting(s: *const State, i: Interval, b: u32) bool {
        return !i.empty() and s.lowpt[i.high] > s.lowpt[b];
    }

    fn lowest(s: *const State, p: Pair) u32 {
        if (p.left.empty()) return s.lowpt[p.right.low];
        if (p.right.empty()) return s.lowpt[p.left.low];
        return @min(s.lowpt[p.left.low], s.lowpt[p.right.low]);
    }

    fn setRef(s: *State, e: u32, to: u32) void {
        if (e != none) s.ref[e] = to;
    }

    fn testing(s: *State, root: u32) !bool {
        const g = s.g;
        try s.dfs.append(s.gpa, root);
        while (s.dfs.items.len > 0) {
            const v = s.dfs.items[s.dfs.items.len - 1];
            const e = s.parent_edge[v];
            const at = s.ord_start[v] + s.it[v];
            if (at == s.ord_start[v + 1]) {
                if (e != none) s.removeBackEdges(e);
                _ = s.dfs.pop();
                continue;
            }
            const ei = s.ord[at];
            const w = g.adj[ei];
            if (s.returning[v]) {
                s.returning[v] = false;
            } else {
                s.stack_bottom[ei] = @intCast(s.conflicts.items.len);
                if (ei == s.parent_edge[w]) {
                    s.returning[v] = true;
                    try s.dfs.append(s.gpa, w);
                    continue;
                }
                s.lowpt_edge[ei] = ei;
                try s.conflicts.append(s.gpa, .{ .right = .{ .low = ei, .high = ei } });
            }
            if (s.lowpt[ei] < s.height[v]) {
                if (s.it[v] == 0) {
                    s.lowpt_edge[e] = s.lowpt_edge[ei];
                } else if (!try s.addConstraints(ei, e)) {
                    return false;
                }
            }
            s.it[v] += 1;
        }
        return true;
    }

    fn addConstraints(s: *State, ei: u32, e: u32) !bool {
        var p: Pair = .{};
        while (true) {
            var q = s.conflicts.pop().?;
            if (!q.left.empty()) q.swap();
            if (!q.left.empty()) return false;
            if (s.lowpt[q.right.low] > s.lowpt[e]) {
                if (p.right.empty()) p.right = q.right else s.setRef(p.right.low, q.right.high);
                p.right.low = q.right.low;
            } else {
                s.setRef(q.right.low, s.lowpt_edge[e]);
            }
            if (s.conflicts.items.len == s.stack_bottom[ei]) break;
        }
        while (s.top()) |t| {
            if (!(s.conflicting(t.left, ei) or s.conflicting(t.right, ei))) break;
            var q = s.conflicts.pop().?;
            if (s.conflicting(q.right, ei)) q.swap();
            if (s.conflicting(q.right, ei)) return false;
            s.setRef(p.right.low, q.right.high);
            if (q.right.low != none) p.right.low = q.right.low;
            if (p.left.empty()) p.left = q.left else s.setRef(p.left.low, q.left.high);
            p.left.low = q.left.low;
        }
        if (!(p.left.empty() and p.right.empty())) try s.conflicts.append(s.gpa, p);
        return true;
    }

    fn removeBackEdges(s: *State, e: u32) void {
        const g = s.g;
        const u = g.from[e];
        while (s.top()) |t| {
            if (s.lowest(t.*) != s.height[u]) break;
            const p = s.conflicts.pop().?;
            if (p.left.low != none) s.side[p.left.low] = -1;
        }
        if (s.top()) |p| {
            while (p.left.high != none and g.adj[p.left.high] == u) p.left.high = s.ref[p.left.high];
            if (p.left.high == none and p.left.low != none) {
                s.ref[p.left.low] = p.right.low;
                s.side[p.left.low] = -1;
                p.left.low = none;
            }
            while (p.right.high != none and g.adj[p.right.high] == u) p.right.high = s.ref[p.right.high];
            if (p.right.high == none and p.right.low != none) {
                s.ref[p.right.low] = p.left.low;
                s.side[p.right.low] = -1;
                p.right.low = none;
            }
        }
        if (s.lowpt[e] < s.height[u]) {
            const t = s.top() orelse return;
            const hl = t.left.high;
            const hr = t.right.high;
            s.ref[e] = if (hl != none and (hr == none or s.lowpt[hl] > s.lowpt[hr])) hl else hr;
        }
    }

    /// Resolves the side of `e` through its chain of references.
    fn sign(s: *State, e: u32) !i8 {
        s.chain.clearRetainingCapacity();
        var x = e;
        while (s.ref[x] != none) {
            try s.chain.append(s.gpa, x);
            x = s.ref[x];
        }
        var i = s.chain.items.len;
        while (i > 0) {
            i -= 1;
            const y = s.chain.items[i];
            s.side[y] *= s.side[s.ref[y]];
            s.ref[y] = none;
        }
        return s.side[e];
    }

    fn addCw(s: *State, v: u32, h: u32, ref: u32) void {
        if (ref == none) {
            s.cw[h] = h;
            s.ccw[h] = h;
            s.first[v] = h;
            return;
        }
        const next = s.cw[ref];
        s.cw[ref] = h;
        s.cw[h] = next;
        s.ccw[next] = h;
        s.ccw[h] = ref;
    }

    fn addCcw(s: *State, v: u32, h: u32, ref: u32) void {
        if (ref == none) return s.addCw(v, h, none);
        s.addCw(v, h, s.ccw[ref]);
        if (ref == s.first[v]) s.first[v] = h;
    }

    fn embedding(s: *State, root: u32) !void {
        const g = s.g;
        try s.dfs.append(s.gpa, root);
        while (s.dfs.items.len > 0) {
            const v = s.dfs.items[s.dfs.items.len - 1];
            const at = s.ord_start[v] + s.it[v];
            if (at == s.ord_start[v + 1]) {
                _ = s.dfs.pop();
                continue;
            }
            s.it[v] += 1;
            const ei = s.ord[at];
            const w = g.adj[ei];
            const back = g.twin[ei];
            if (ei == s.parent_edge[w]) {
                s.addCcw(w, back, s.first[w]);
                s.left_ref[v] = ei;
                s.right_ref[v] = ei;
                try s.dfs.append(s.gpa, w);
            } else if (s.side[ei] == 1) {
                s.addCw(w, back, s.right_ref[w]);
            } else {
                s.addCcw(w, back, s.left_ref[w]);
                s.left_ref[w] = back;
            }
        }
    }

    fn result(s: *State) !Embedding {
        const g = s.g;
        const gpa = s.gpa;
        const start = try gpa.dupe(u32, g.start);
        errdefer gpa.free(start);
        const rotation = try gpa.alloc(u32, g.adj.len);
        errdefer gpa.free(rotation);
        const rev = try gpa.alloc(u32, g.adj.len);
        errdefer gpa.free(rev);
        // `pos` reuses `stack_bottom`: the position of each half-edge in the rotation.
        const pos = s.stack_bottom;
        for (0..g.n) |v| {
            const f = s.first[v];
            if (f == none) continue;
            var h = f;
            var i = start[v];
            while (true) {
                rotation[i] = g.adj[h];
                pos[h] = i;
                i += 1;
                h = s.cw[h];
                if (h == f) break;
            }
            std.debug.assert(i == start[v + 1]);
        }
        for (0..g.adj.len) |h| rev[pos[h]] = pos[g.twin[h]];
        return .{ .start = start, .rotation = rotation, .rev = rev };
    }
};

fn complete(gpa: std.mem.Allocator, n: u32) !Graph {
    var edges: std.ArrayList(graph_mod.Edge) = .empty;
    defer edges.deinit(gpa);
    for (0..n) |i| for (i + 1..n) |j| try edges.append(gpa, .{ @intCast(i), @intCast(j) });
    return Graph.init(gpa, n, edges.items);
}

test "K4 is planar and K5 is not" {
    const gpa = std.testing.allocator;
    const k4 = try complete(gpa, 4);
    defer k4.deinit(gpa);
    const e = (try embed(gpa, k4)).?;
    defer e.deinit(gpa);
    try std.testing.expectEqual(0, try e.genus(gpa));
    try std.testing.expectEqual(4, try e.faceCount(gpa));

    const k5 = try complete(gpa, 5);
    defer k5.deinit(gpa);
    try std.testing.expect(!try isPlanar(gpa, k5));
}

test "K3,3 is not planar; K3,3 minus an edge is" {
    const gpa = std.testing.allocator;
    var edges: [9]graph_mod.Edge = undefined;
    for (0..3) |i| for (0..3) |j| {
        edges[3 * i + j] = .{ @intCast(i), @intCast(3 + j) };
    };
    const k33 = try Graph.init(gpa, 6, &edges);
    defer k33.deinit(gpa);
    try std.testing.expect(!try isPlanar(gpa, k33));
    const minus = try Graph.init(gpa, 6, edges[1..]);
    defer minus.deinit(gpa);
    const e = (try embed(gpa, minus)).?;
    defer e.deinit(gpa);
    try std.testing.expectEqual(0, try e.genus(gpa));
}

test "a long path does not exhaust the stack" {
    const gpa = std.testing.allocator;
    const n = 200_000;
    const edges = try gpa.alloc(graph_mod.Edge, n - 1);
    defer gpa.free(edges);
    for (edges, 0..) |*e, i| e.* = .{ @intCast(i), @intCast(i + 1) };
    const g = try Graph.init(gpa, n, edges);
    defer g.deinit(gpa);
    const e = (try embed(gpa, g)).?;
    defer e.deinit(gpa);
    try std.testing.expectEqual(0, try e.genus(gpa));
}
