# Changelog

## Unreleased

- `mssp`: Klein's multiple-source shortest paths. `trees` returns a
  shortest-path tree rooted at every vertex of one face in O(n log n) time,
  as one tree plus the parent changes between consecutive roots. `Walk`
  replays them, and `distances` reads distances off any tree. Lengths are per
  half-edge, so the two directions of an edge may differ.
- A link-cut tree with two values per node, one for each direction along a
  path, holds the dual tree of the non-tree edges.
- The `zig-planar paths` command, with optional edge lengths and a
  `"distances"` flag.
- Golden tests compare every tree with Dijkstra on the connected planar
  graphs and the large triangulations; a fuzz target compares with
  Bellman-Ford using different lengths in the two directions.
- `docs/shortest-paths.gif`, rendered from real `zig-planar paths` output by
  `docs/shortest-paths.py`, which checks every tree against Dijkstra.

## 0.1.0 - 2026-10-07

- First release: `graph`, `planarity`, `embedding`, `kuratowski` and `color`.
- The left-right planarity test returns a combinatorial embedding, and the
  genus of an embedding can be checked by tracing its faces.
- Non-planar graphs get a K5 or K3,3 subdivision, checked without any
  planarity test.
- Smallest-last greedy colouring, a guaranteed Kempe-chain 5-colouring and a
  4-colouring with an exact fallback.
- Agrees with networkx on 435 graphs; fuzz targets require a certificate for
  every planarity answer.
- The `zig-planar` command runs `planar` and `color` on JSON from stdin.
