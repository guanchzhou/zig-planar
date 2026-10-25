# Changelog

## 0.1.2 - 2026-10-25

- Fix a panic in `color.greedy` on graphs of degeneracy 32 or more, such as
  K33: the used-colour set is now a scratch array sized to the degeneracy, and
  `error.TooManyColors` is returned when more than 255 colours would be needed.
- `kuratowski.find` keeps memory O(n + m) even when given an arena: each trial
  graph lives in an internal arena reset between trials, and trials whose edge
  count exceeds 3n - 6 are skipped as certainly non-planar.
- `planarity.embed` rejects graphs with more than 3n - 6 edges before
  allocating.
- `Graph.init` returns `error.TooManyEdges` above `maxInt(u32) / 2` edges, since
  half-edges are numbered in `u32`.
- The command line rejects `n` above 2^24 (16,777,216) instead of attempting
  allocations of many gigabytes.

## 0.1.1 - 2026-10-20

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
- Prevent partial allocation leaks on OOM in `planarity.State.init`, deduplicate Kempe chain trials in `color.Search.free`, bound CLI `stdin` reads, and add GitHub Actions CI workflow.

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
