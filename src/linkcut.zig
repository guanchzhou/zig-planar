//! Link-cut trees (Sleator and Tarjan 1983) with two values on every node, one for each
//! direction along a path.
//!
//! After `path(u, v)`, value 0 of each node on the path is the one that points from `u`
//! towards `v`, and value 1 points back. The path can be searched for its smallest value in
//! either direction and shifted by different amounts in the two directions. `evert` reverses a
//! path, which swaps the two values. Each value carries an item that moves with it. Values
//! equal to `inf` are never shifted.

const std = @import("std");

pub const none: u32 = std.math.maxInt(u32);
pub const inf: i64 = std.math.maxInt(i64);

pub const Node = struct {
    child: [2]u32 = .{ none, none },
    up: u32 = none,
    flip: bool = false,
    val: [2]i64 = .{ inf, inf },
    item: [2]u32 = .{ none, none },
    min: [2]i64 = .{ inf, inf },
    arg: [2]u32 = .{ none, none },
    add: [2]i64 = .{ 0, 0 },
};

pub const Forest = struct {
    nodes: []Node,
    stack: []u32,

    /// `n` nodes, each a tree of its own.
    pub fn init(gpa: std.mem.Allocator, n: usize) !Forest {
        const nodes = try gpa.alloc(Node, n);
        errdefer gpa.free(nodes);
        @memset(nodes, .{});
        return .{ .nodes = nodes, .stack = try gpa.alloc(u32, n) };
    }

    pub fn deinit(f: Forest, gpa: std.mem.Allocator) void {
        gpa.free(f.nodes);
        gpa.free(f.stack);
    }

    fn isRoot(f: Forest, x: u32) bool {
        const p = f.nodes[x].up;
        return p == none or (f.nodes[p].child[0] != x and f.nodes[p].child[1] != x);
    }

    fn reverse(f: Forest, x: u32) void {
        if (x == none) return;
        const a = &f.nodes[x];
        std.mem.swap(u32, &a.child[0], &a.child[1]);
        std.mem.swap(i64, &a.val[0], &a.val[1]);
        std.mem.swap(u32, &a.item[0], &a.item[1]);
        std.mem.swap(i64, &a.min[0], &a.min[1]);
        std.mem.swap(u32, &a.arg[0], &a.arg[1]);
        std.mem.swap(i64, &a.add[0], &a.add[1]);
        a.flip = !a.flip;
    }

    /// Adds `by` to every value in the splay subtree of `x`, lazily.
    pub fn shift(f: Forest, x: u32, by: [2]i64) void {
        if (x == none) return;
        const a = &f.nodes[x];
        for (0..2) |d| {
            if (a.val[d] != inf) a.val[d] += by[d];
            if (a.min[d] != inf) a.min[d] += by[d];
            a.add[d] += by[d];
        }
    }

    fn push(f: Forest, x: u32) void {
        const a = &f.nodes[x];
        if (a.flip) {
            f.reverse(a.child[0]);
            f.reverse(a.child[1]);
            a.flip = false;
        }
        if (a.add[0] != 0 or a.add[1] != 0) {
            f.shift(a.child[0], a.add);
            f.shift(a.child[1], a.add);
            a.add = .{ 0, 0 };
        }
    }

    /// Recomputes the minima of `x` from its own values and its children. Call after changing
    /// `val` on a node that `access` or `splay` has just made a splay root.
    pub fn refresh(f: Forest, x: u32) void {
        const a = &f.nodes[x];
        for (0..2) |d| {
            a.min[d] = a.val[d];
            a.arg[d] = if (a.val[d] != inf) x else none;
            for (a.child) |c| {
                if (c != none and f.nodes[c].min[d] < a.min[d]) {
                    a.min[d] = f.nodes[c].min[d];
                    a.arg[d] = f.nodes[c].arg[d];
                }
            }
        }
    }

    fn rotate(f: Forest, x: u32) void {
        const p = f.nodes[x].up;
        const g = f.nodes[p].up;
        const side: usize = @intFromBool(f.nodes[p].child[1] == x);
        const b = f.nodes[x].child[1 - side];
        if (!f.isRoot(p)) {
            const gs: usize = @intFromBool(f.nodes[g].child[1] == p);
            f.nodes[g].child[gs] = x;
        }
        f.nodes[x].up = g;
        f.nodes[x].child[1 - side] = p;
        f.nodes[p].up = x;
        f.nodes[p].child[side] = b;
        if (b != none) f.nodes[b].up = p;
        f.refresh(p);
        f.refresh(x);
    }

    /// Makes `x` the root of its splay tree, with every pending update above it applied.
    pub fn splay(f: Forest, x: u32) void {
        var top: usize = 0;
        var y = x;
        f.stack[top] = y;
        top += 1;
        while (!f.isRoot(y)) {
            y = f.nodes[y].up;
            f.stack[top] = y;
            top += 1;
        }
        while (top > 0) {
            top -= 1;
            f.push(f.stack[top]);
        }
        while (!f.isRoot(x)) {
            const p = f.nodes[x].up;
            if (!f.isRoot(p)) {
                const g = f.nodes[p].up;
                const straight = (f.nodes[g].child[0] == p) == (f.nodes[p].child[0] == x);
                f.rotate(if (straight) p else x);
            }
            f.rotate(x);
        }
    }

    /// Puts the path from the root of x's tree to `x` in one splay tree, rooted at `x`.
    pub fn access(f: Forest, x: u32) void {
        var last: u32 = none;
        var y = x;
        while (y != none) {
            f.splay(y);
            f.nodes[y].child[1] = last;
            f.refresh(y);
            last = y;
            y = f.nodes[y].up;
        }
        f.splay(x);
    }

    /// Makes `x` the root of its tree.
    pub fn evert(f: Forest, x: u32) void {
        f.access(x);
        f.reverse(x);
    }

    /// Joins the tree of `x` below `y`. They must be in different trees.
    pub fn link(f: Forest, x: u32, y: u32) void {
        f.evert(x);
        f.nodes[x].up = y;
    }

    /// Removes the edge between adjacent nodes `x` and `y`.
    pub fn cut(f: Forest, x: u32, y: u32) void {
        f.evert(x);
        f.access(y);
        std.debug.assert(f.nodes[y].child[0] == x and f.nodes[x].child[1] == none);
        f.nodes[y].child[0] = none;
        f.nodes[x].up = none;
        f.refresh(y);
    }

    /// The splay root holding the path from `u` to `v`, in that order.
    pub fn path(f: Forest, u: u32, v: u32) u32 {
        f.evert(u);
        f.access(v);
        return v;
    }
};

const Naive = struct {
    // Edge nodes are n..n+n-1 joining face a[e] and face b[e]; to[e][x] is the value pointing
    // into face x, which is value 0 when a path crosses from the other face into x.
    a: []u32,
    b: []u32,
    to_a: []i64,
    to_b: []i64,
    live: []bool,
};

fn naivePath(gpa: std.mem.Allocator, n: u32, nv: Naive, u: u32, v: u32) !?[]u32 {
    const prev = try gpa.alloc(u32, n);
    defer gpa.free(prev);
    @memset(prev, none);
    var queue: std.ArrayList(u32) = .empty;
    defer queue.deinit(gpa);
    try queue.append(gpa, u);
    prev[u] = u;
    var i: usize = 0;
    while (i < queue.items.len) : (i += 1) {
        const x = queue.items[i];
        for (nv.live, 0..) |live, e| {
            if (!live) continue;
            const y = if (nv.a[e] == x) nv.b[e] else if (nv.b[e] == x) nv.a[e] else continue;
            if (prev[y] != none) continue;
            prev[y] = @intCast(e);
            try queue.append(gpa, y);
        }
    }
    if (prev[v] == none) return null;
    var edges: std.ArrayList(u32) = .empty;
    errdefer edges.deinit(gpa);
    var x = v;
    while (x != u) {
        const e = prev[x];
        try edges.append(gpa, e);
        x = if (nv.a[e] == x) nv.b[e] else nv.a[e];
    }
    std.mem.reverse(u32, edges.items);
    return try edges.toOwnedSlice(gpa);
}

test "random links, cuts, path minima and shifts agree with a naive forest" {
    const gpa = std.testing.allocator;
    const n = 24;
    var f = try Forest.init(gpa, 2 * n);
    defer f.deinit(gpa);
    var a: [n]u32 = undefined;
    var b: [n]u32 = undefined;
    var to_a: [n]i64 = undefined;
    var to_b: [n]i64 = undefined;
    var live: [n]bool = @splat(false);
    const nv: Naive = .{ .a = &a, .b = &b, .to_a = &to_a, .to_b = &to_b, .live = &live };
    var prng = std.Random.DefaultPrng.init(7);
    const rand = prng.random();

    for (0..4000) |_| {
        const u = rand.uintLessThan(u32, n);
        const v = rand.uintLessThan(u32, n);
        const edges = try naivePath(gpa, n, nv, u, v);
        if (edges == null) {
            const e = for (0..n) |e| {
                if (!live[e]) break e;
            } else continue;
            live[e] = true;
            a[e] = u;
            b[e] = v;
            to_a[e] = rand.intRangeAtMost(i64, 0, 50);
            to_b[e] = rand.intRangeAtMost(i64, 0, 50);
            const x: u32 = @intCast(n + e);
            f.nodes[x] = .{};
            f.link(x, u);
            f.access(x);
            f.nodes[x].val = .{ to_b[e], to_a[e] };
            f.nodes[x].item = .{ v, u };
            f.refresh(x);
            f.link(v, x);
            continue;
        }
        defer gpa.free(edges.?);
        if (u == v) continue;
        const r = f.path(u, v);
        var want: i64 = inf;
        var face = u;
        for (edges.?) |e| {
            const into = if (a[e] == face) b[e] else a[e];
            want = @min(want, if (into == b[e]) to_b[e] else to_a[e]);
            face = into;
        }
        try std.testing.expectEqual(want, f.nodes[r].min[0]);
        const at = f.nodes[r].arg[0];
        f.splay(at);
        try std.testing.expectEqual(want, f.nodes[at].val[0]);

        switch (rand.uintLessThan(u8, 3)) {
            0 => {
                const s0 = rand.intRangeAtMost(i64, -5, 20);
                const s1 = rand.intRangeAtMost(i64, -5, 20);
                const r2 = f.path(u, v);
                f.shift(r2, .{ s0, s1 });
                face = u;
                for (edges.?) |e| {
                    const into = if (a[e] == face) b[e] else a[e];
                    if (into == b[e]) {
                        to_b[e] += s0;
                        to_a[e] += s1;
                    } else {
                        to_a[e] += s0;
                        to_b[e] += s1;
                    }
                    face = into;
                }
            },
            1 => {
                const e = edges.?[rand.uintLessThan(usize, edges.?.len)];
                const x: u32 = @intCast(n + e);
                f.cut(x, a[e]);
                f.cut(x, b[e]);
                live[e] = false;
            },
            else => {},
        }
    }
}
