//! Combinatorial embeddings (rotation systems).
//!
//! An embedding lists the neighbours of every vertex in cyclic order. Position `i` in
//! `rotation` is the dart v -> rotation[i] for the vertex v whose block
//! `start[v]..start[v + 1]` contains `i`, and `rev[i]` is the position of the opposite dart.
//! Faces are traced by following a dart u -> v with the dart from v to the neighbour after u
//! in v's rotation. The embedding is planar exactly when Euler's formula
//! V - E + F = 2 holds on every connected component, that is, when the genus is 0.

const std = @import("std");
const Graph = @import("graph.zig").Graph;
const none = @import("graph.zig").none;

pub const Embedding = struct {
    start: []u32,
    rotation: []u32,
    rev: []u32,

    pub fn deinit(e: Embedding, gpa: std.mem.Allocator) void {
        gpa.free(e.start);
        gpa.free(e.rotation);
        gpa.free(e.rev);
    }

    pub fn vertexCount(e: Embedding) u32 {
        return @intCast(e.start.len - 1);
    }

    /// The neighbours of v in cyclic order.
    pub fn neighbors(e: Embedding, v: u32) []const u32 {
        return e.rotation[e.start[v]..e.start[v + 1]];
    }

    fn vertexOf(e: Embedding, i: u32) u32 {
        return e.rotation[e.rev[i]];
    }

    /// The dart that follows dart `i` around its face.
    pub fn nextDart(e: Embedding, i: u32) u32 {
        const j = e.rev[i];
        const w = e.rotation[i];
        return if (j + 1 == e.start[w + 1]) e.start[w] else j + 1;
    }

    /// Builds an embedding of `g` from each vertex's neighbours in cyclic order.
    pub fn fromRotation(gpa: std.mem.Allocator, g: Graph, order: []const []const u32) !Embedding {
        if (order.len != g.n) return error.WrongVertexCount;
        const start = try gpa.dupe(u32, g.start);
        errdefer gpa.free(start);
        const rotation = try gpa.alloc(u32, g.adj.len);
        errdefer gpa.free(rotation);
        const rev = try gpa.alloc(u32, g.adj.len);
        errdefer gpa.free(rev);
        const pos = try gpa.alloc(u32, g.adj.len);
        defer gpa.free(pos);
        @memset(pos, none);
        for (order, 0..) |list, v| {
            if (list.len != g.degree(@intCast(v))) return error.NotARotation;
            for (list, start[v]..) |w, i| {
                const h = g.halfEdge(@intCast(v), w) orelse return error.NotARotation;
                if (pos[h] != none) return error.NotARotation;
                pos[h] = @intCast(i);
                rotation[i] = w;
            }
        }
        for (0..g.adj.len) |h| rev[pos[h]] = pos[g.twin[h]];
        return .{ .start = start, .rotation = rotation, .rev = rev };
    }

    /// Faces as vertex cycles: face `f` is `vertices[start[f]..start[f + 1]]`, listing the
    /// tail of each dart in order. Isolated vertices have no darts and no traced face.
    pub const Faces = struct {
        start: []u32,
        vertices: []u32,

        pub fn deinit(f: Faces, gpa: std.mem.Allocator) void {
            gpa.free(f.start);
            gpa.free(f.vertices);
        }

        pub fn count(f: Faces) usize {
            return f.start.len - 1;
        }

        pub fn get(f: Faces, i: usize) []const u32 {
            return f.vertices[f.start[i]..f.start[i + 1]];
        }
    };

    pub fn faces(e: Embedding, gpa: std.mem.Allocator) !Faces {
        const seen = try gpa.alloc(bool, e.rotation.len);
        defer gpa.free(seen);
        @memset(seen, false);
        var start: std.ArrayList(u32) = .empty;
        errdefer start.deinit(gpa);
        const vertices = try gpa.alloc(u32, e.rotation.len);
        errdefer gpa.free(vertices);
        try start.append(gpa, 0);
        var k: u32 = 0;
        for (0..e.rotation.len) |first| {
            if (seen[first]) continue;
            var i: u32 = @intCast(first);
            while (!seen[i]) : (i = e.nextDart(i)) {
                seen[i] = true;
                vertices[k] = e.vertexOf(i);
                k += 1;
            }
            try start.append(gpa, k);
        }
        return .{ .start = try start.toOwnedSlice(gpa), .vertices = vertices };
    }

    pub fn faceCount(e: Embedding, gpa: std.mem.Allocator) !usize {
        const seen = try gpa.alloc(bool, e.rotation.len);
        defer gpa.free(seen);
        @memset(seen, false);
        var count: usize = 0;
        for (0..e.rotation.len) |first| {
            if (seen[first]) continue;
            var i: u32 = @intCast(first);
            while (!seen[i]) : (i = e.nextDart(i)) seen[i] = true;
            count += 1;
        }
        return count;
    }

    /// The total genus over all components: sum of (2 - V + E - F) / 2. Zero means planar.
    pub fn genus(e: Embedding, gpa: std.mem.Allocator) !usize {
        const n = e.vertexCount();
        const parent = try gpa.alloc(u32, n);
        defer gpa.free(parent);
        for (parent, 0..) |*p, v| p.* = @intCast(v);
        for (0..n) |v| {
            for (e.neighbors(@intCast(v))) |w| {
                const a = find(parent, @intCast(v));
                const b = find(parent, w);
                if (a != b) parent[a] = b;
            }
        }
        var components: usize = 0;
        var isolated: usize = 0;
        for (0..n) |v| {
            if (find(parent, @intCast(v)) == v) components += 1;
            if (e.start[v] == e.start[v + 1]) isolated += 1;
        }
        const f = try e.faceCount(gpa) + isolated;
        const edges = e.rotation.len / 2;
        // Euler: V - E + F = 2C - 2 genus.
        const twice = 2 * components + edges;
        std.debug.assert(twice >= n + f and (twice - n - f) % 2 == 0);
        return (twice - n - f) / 2;
    }
};

fn find(parent: []u32, v: u32) u32 {
    var x = v;
    while (parent[x] != x) {
        parent[x] = parent[parent[x]];
        x = parent[x];
    }
    return x;
}

test "the two rotations of K4: planar and toroidal" {
    const gpa = std.testing.allocator;
    const g = try Graph.init(gpa, 4, &.{ .{ 0, 1 }, .{ 0, 2 }, .{ 0, 3 }, .{ 1, 2 }, .{ 1, 3 }, .{ 2, 3 } });
    defer g.deinit(gpa);
    const planar = try Embedding.fromRotation(gpa, g, &.{ &.{ 1, 2, 3 }, &.{ 0, 3, 2 }, &.{ 0, 1, 3 }, &.{ 0, 2, 1 } });
    defer planar.deinit(gpa);
    try std.testing.expectEqual(4, try planar.faceCount(gpa));
    try std.testing.expectEqual(0, try planar.genus(gpa));
    const torus = try Embedding.fromRotation(gpa, g, &.{ &.{ 1, 2, 3 }, &.{ 0, 2, 3 }, &.{ 0, 1, 3 }, &.{ 0, 1, 2 } });
    defer torus.deinit(gpa);
    try std.testing.expectEqual(1, try torus.genus(gpa));
}

test "isolated vertices and separate components" {
    const gpa = std.testing.allocator;
    const g = try Graph.init(gpa, 5, &.{ .{ 0, 1 }, .{ 2, 3 } });
    defer g.deinit(gpa);
    const e = try Embedding.fromRotation(gpa, g, &.{ &.{1}, &.{0}, &.{3}, &.{2}, &.{} });
    defer e.deinit(gpa);
    try std.testing.expectEqual(0, try e.genus(gpa));
    const f = try e.faces(gpa);
    defer f.deinit(gpa);
    try std.testing.expectEqual(2, f.count());
    try std.testing.expectEqualSlices(u32, &.{ 0, 1 }, f.get(0));
}
