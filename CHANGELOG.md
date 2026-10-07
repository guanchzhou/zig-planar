# Changelog

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
