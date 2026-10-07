"""Writes test/golden.json from networkx, independently of the Zig code.

planarity: graphs of many shapes with networkx's answer to "is it planar?".
large: big planar triangulations for the colouring tests.

Run: uv run --with networkx --with scipy --with numpy python test/reference.py
"""

import itertools
import json
import pathlib

import networkx as nx
import numpy as np
from scipy.spatial import Delaunay

rng = np.random.default_rng(20261007)


def relabel(g):
    nodes = list(g.nodes)
    perm = rng.permutation(len(nodes))
    return nx.relabel_nodes(g, {v: int(perm[i]) for i, v in enumerate(nodes)})


def delaunay(n):
    pts = rng.random((n, 2))
    g = nx.Graph()
    g.add_nodes_from(range(n))
    for s in Delaunay(pts).simplices:
        for a, b in itertools.combinations(s, 2):
            g.add_edge(int(a), int(b))
    return g


def icosphere(freq):
    phi = (1 + 5**0.5) / 2
    verts = [(-1, phi, 0), (1, phi, 0), (-1, -phi, 0), (1, -phi, 0),
             (0, -1, phi), (0, 1, phi), (0, -1, -phi), (0, 1, -phi),
             (phi, 0, -1), (phi, 0, 1), (-phi, 0, -1), (-phi, 0, 1)]
    faces = [(0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11),
             (1, 5, 9), (5, 11, 4), (11, 10, 2), (10, 7, 6), (7, 1, 8),
             (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9),
             (4, 9, 5), (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1)]
    index = {}
    g = nx.Graph()

    def vertex(key):
        if key not in index:
            index[key] = len(index)
        return index[key]

    for a, b, c in faces:
        pa, pb, pc = (np.array(verts[i], dtype=float) for i in (a, b, c))
        grid = {}
        for i in range(freq + 1):
            for j in range(freq + 1 - i):
                p = (pa * (freq - i - j) + pb * i + pc * j) / freq
                grid[i, j] = vertex(tuple(np.round(p / np.linalg.norm(p), 9)))
        for i in range(freq + 1):
            for j in range(freq + 1 - i):
                for di, dj in ((1, 0), (0, 1), (-1, 1)):
                    if (i + di, j + dj) in grid:
                        g.add_edge(grid[i, j], grid[i + di, j + dj])
    return g


def case(g):
    g = relabel(g)
    planar, _ = nx.check_planarity(g)
    edges = sorted([min(u, v), max(u, v)] for u, v in g.edges if u != v)
    return {"n": g.number_of_nodes(), "edges": edges, "planar": bool(planar)}


def add_random_edges(g, k):
    g = g.copy()
    missing = list(nx.non_edges(g))
    for i in rng.permutation(len(missing))[:k]:
        g.add_edge(*missing[i])
    return g


def remove_random_edges(g, k):
    g = g.copy()
    edges = list(g.edges)
    for i in rng.permutation(len(edges))[:k]:
        g.remove_edge(*edges[i])
    return g


cases = []
named = [
    nx.empty_graph(0), nx.empty_graph(1), nx.empty_graph(5), nx.path_graph(2),
    nx.complete_graph(3), nx.complete_graph(4), nx.complete_graph(5), nx.complete_graph(6),
    nx.complete_bipartite_graph(3, 3), nx.complete_bipartite_graph(2, 7),
    nx.complete_bipartite_graph(3, 4), nx.petersen_graph(), nx.hypercube_graph(3),
    nx.hypercube_graph(4), nx.wheel_graph(9), nx.star_graph(12), nx.cycle_graph(20),
    nx.grid_2d_graph(7, 9), nx.triangular_lattice_graph(5, 6), nx.dodecahedral_graph(),
    nx.icosahedral_graph(), nx.octahedral_graph(), nx.heawood_graph(), nx.moebius_kantor_graph(),
    nx.disjoint_union(nx.complete_graph(4), nx.complete_bipartite_graph(3, 3)),
    nx.disjoint_union(nx.icosahedral_graph(), nx.grid_2d_graph(3, 3)),
    nx.circular_ladder_graph(8), nx.ladder_graph(10), nx.barbell_graph(4, 3),
]
for k in (1, 2, 3):
    sub = nx.Graph()
    for u, v in nx.complete_graph(5).edges:
        nx.add_path(sub, [u, ("s", u, v, 0)] + [("s", u, v, i) for i in range(1, k)] + [v])
    named.append(sub)
    sub = nx.Graph()
    for u, v in nx.complete_bipartite_graph(3, 3).edges:
        nx.add_path(sub, [u] + [("t", u, v, i) for i in range(k)] + [v])
    named.append(sub)
cases += [case(g) for g in named]

for _ in range(80):
    n = int(rng.integers(4, 150))
    t = delaunay(n)
    cases.append(case(t))
    cases.append(case(remove_random_edges(t, int(rng.integers(1, max(2, t.number_of_edges() // 3))))))
    cases.append(case(add_random_edges(t, int(rng.integers(1, 4)))))

for _ in range(120):
    n = int(rng.integers(5, 60))
    m = int(rng.integers(n - 1, 3 * n))
    cases.append(case(nx.gnm_random_graph(n, m, seed=int(rng.integers(1 << 31)))))

for _ in range(40):
    n = int(rng.integers(5, 80))
    tree = nx.random_labeled_tree(n, seed=int(rng.integers(1 << 31)))
    cases.append(case(add_random_edges(tree, int(rng.integers(0, 2 * n)))))

large = []
for n in (2000, 5000):
    large.append(case(delaunay(n)))
large.append(case(icosphere(10)))
assert all(c["planar"] for c in large)

out = pathlib.Path(__file__).with_name("golden.json")
out.write_text(json.dumps({"planarity": cases, "large": large}, separators=(",", ":")) + "\n")
planar = sum(c["planar"] for c in cases)
print(f"{len(cases)} planarity cases ({planar} planar), {len(large)} large, networkx {nx.__version__}")
