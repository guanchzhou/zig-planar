//! zig-planar: planarity, embeddings and colourings of planar graphs.
//!
//! - `graph`: simple undirected graphs in compressed-sparse-row form.
//! - `planarity`: the left-right planarity test with a combinatorial embedding.
//! - `embedding`: rotation systems, faces and genus.
//! - `kuratowski`: K5 and K3,3 subdivisions that certify a graph is not planar.
//! - `color`: smallest-last, Kempe-chain 5-colouring and 4-colouring.
//! - `mssp`: shortest-path trees rooted at every vertex of one face (Klein's algorithm).

const std = @import("std");

pub const graph = @import("graph.zig");
pub const planarity = @import("planarity.zig");
pub const embedding = @import("embedding.zig");
pub const kuratowski = @import("kuratowski.zig");
pub const color = @import("color.zig");
pub const mssp = @import("mssp.zig");

pub const Graph = graph.Graph;
pub const Edge = graph.Edge;
pub const Embedding = embedding.Embedding;

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(graph);
    std.testing.refAllDecls(planarity);
    std.testing.refAllDecls(embedding);
    std.testing.refAllDecls(kuratowski);
    std.testing.refAllDecls(color);
    std.testing.refAllDecls(mssp);
    _ = @import("linkcut.zig");
    _ = @import("fuzz.zig");
}
