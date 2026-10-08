"""Render docs/shortest-paths.gif from the output of the zig-planar command line.

Run from the repository root after `zig build`:

    uv run --with numpy --with scipy --with matplotlib python docs/shortest-paths.py
"""

import io
import json
import subprocess
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from matplotlib.tri import Triangulation
from PIL import Image
from scipy.sparse import csr_matrix
from scipy.sparse.csgraph import dijkstra
from scipy.spatial import Delaunay

ROOT = Path(__file__).resolve().parent.parent
EXE = ROOT / "zig-out" / "bin" / "zig-planar"
OUT = ROOT / "docs" / "shortest-paths.gif"

RING = 16
INNER = 90
SCALE = 1000
INK = "#24292f"
MUTED = "#57606a"
FAINT = "#d0d7de"
ROOT_COLOUR = "#f28e2b"
CHANGE = "#e15759"


def points(seed):
    """A ring of evenly spaced points around well-spread points inside the disk."""
    rng = np.random.default_rng(seed)
    angles = 2 * np.pi * np.arange(RING) / RING
    ring = np.column_stack([np.cos(angles), np.sin(angles)])
    inner = []
    while len(inner) < INNER:
        p = rng.uniform(-0.9, 0.9, 2)
        if np.hypot(*p) < 0.9 and all(np.hypot(*(p - q)) > 0.13 for q in inner):
            inner.append(p)
    return np.vstack([ring, inner])


def run(command, payload):
    out = subprocess.run([str(EXE), command], input=json.dumps(payload), capture_output=True, text=True, check=True)
    return json.loads(out.stdout)


def trees(parent, steps):
    """The parent array for every root, replayed from the first tree and the changes."""
    current = list(parent)
    out = [list(current)]
    for step in steps:
        for v, p in step:
            current[v] = p
        out.append(list(current))
    return out


def distances(parent, length):
    dist = [None] * len(parent)

    def walk(v):
        if dist[v] is None:
            p = parent[v]
            dist[v] = 0 if p is None else walk(p) + length[(p, v)]
        return dist[v]

    for v in range(len(parent)):
        walk(v)
    return dist


def frame(pts, tri, edges, parent, dist, root, changed, title, body, command):
    fig = plt.figure(figsize=(7.2, 5.4), dpi=100)
    fig.patch.set_facecolor("white")
    ax = fig.add_axes([0.03, 0.25, 0.94, 0.73])
    ax.set_xlim(-1.75, 1.75)
    ax.set_ylim(-1.06, 1.06)
    ax.set_aspect("equal")
    ax.axis("off")
    if dist is not None:
        ax.tripcolor(tri, dist, shading="gouraud", cmap="YlGnBu", vmin=0, vmax=2.4 * SCALE, alpha=0.55, zorder=1)
    for u, v in edges:
        ax.plot(*zip(pts[u], pts[v]), color=FAINT, linewidth=0.8, zorder=2)
    if parent is not None:
        for v, p in enumerate(parent):
            if p is not None:
                hot = v in changed
                ax.plot(*zip(pts[p], pts[v]), color=CHANGE if hot else INK,
                        linewidth=2.6 if hot else 1.5, zorder=4 if hot else 3, solid_capstyle="round")
    hot = sorted(changed)
    ax.scatter(pts[:, 0], pts[:, 1], s=9, color=INK, zorder=5)
    if hot:
        ax.scatter(pts[hot, 0], pts[hot, 1], s=34, color=CHANGE, zorder=6)
    if root is not None:
        ax.scatter([pts[root, 0]], [pts[root, 1]], s=190, color=ROOT_COLOUR, edgecolor=INK, linewidth=1.4, zorder=7)
    fig.text(0.5, 0.185, title, ha="center", fontsize=15, fontweight="bold", color=INK)
    fig.text(0.5, 0.115, body, ha="center", fontsize=11.5, color=INK)
    fig.text(0.5, 0.045, command, ha="center", fontsize=10.5, family="monospace", color=MUTED)
    buf = io.BytesIO()
    fig.savefig(buf, format="png", facecolor="white")
    plt.close(fig)
    buf.seek(0)
    pixels = np.asarray(Image.open(buf).convert("RGB"), dtype=np.int32)
    flat = pixels.reshape(-1, 3)
    index = np.empty(len(flat), dtype=np.uint8)
    for start in range(0, len(flat), 1 << 16):
        chunk = flat[start:start + (1 << 16)]
        index[start:start + len(chunk)] = ((chunk[:, None, :] - PALETTE[None]) ** 2).sum(axis=2).argmin(axis=1)
    image = Image.fromarray(index.reshape(pixels.shape[:2]), mode="P")
    image.putpalette(PALETTE.astype(np.uint8).ravel().tolist())
    return image


def palette():
    """One palette for every frame, so the root and the changes keep their exact colours."""
    def rgb(c):
        return np.array(matplotlib.colors.to_rgb(c))

    white = np.ones(3)
    shades = [rgb(c) for c in ("white", INK, MUTED, FAINT, ROOT_COLOUR, CHANGE)]
    for c in (INK, MUTED, FAINT, ROOT_COLOUR, CHANGE):
        shades += [white + t * (rgb(c) - white) for t in np.linspace(0.1, 0.9, 12)]
    shades += [white + 0.55 * (np.array(plt.get_cmap("YlGnBu")(t)[:3]) - white) for t in np.linspace(0, 1, 120)]
    return np.round(255 * np.array(shades)).astype(np.int32)


PALETTE = palette()


def main():
    pts = points(3)
    n = len(pts)
    tri = Triangulation(pts[:, 0], pts[:, 1], Delaunay(pts).simplices)
    edges = sorted({tuple(sorted(map(int, e))) for e in tri.edges})
    length = {}
    for u, v in edges:
        length[(u, v)] = length[(v, u)] = int(round(SCALE * np.hypot(*(pts[u] - pts[v]))))

    weighted = [[u, v, length[(u, v)]] for u, v in edges]
    for boundary in ([0, 1], [1, 0]):
        result = run("paths", {"n": n, "edges": weighted, "boundary": boundary, "distances": True})
        if len(result["boundary"]) == RING:
            break
    assert sorted(result["boundary"]) == list(range(RING))
    roots = result["boundary"]
    all_trees = trees(result["parent"], result["steps"])

    rows, cols, vals = zip(*[(u, v, length[(u, v)]) for u, v in edges])
    graph = csr_matrix((vals, (rows, cols)), shape=(n, n))
    expected = dijkstra(graph, directed=False, indices=roots)
    all_dist = []
    for i, parent in enumerate(all_trees):
        assert parent[roots[i]] is None
        dist = distances(parent, length)
        assert dist == [int(d) for d in expected[i]] == result["distances"][i]
        all_dist.append(dist)

    total = sum(len(step) for step in result["steps"])
    darts = 2 * len(edges)
    assert total <= darts
    frames, durations = [], []

    def add(ms, *args):
        frames.append(frame(pts, tri, edges, *args))
        durations.append(ms)

    add(3000, None, None, None, set(), "Shortest paths from every outer vertex",
        f"{n} vertices, {len(edges)} edges, each as long as it is drawn.",
        f"{RING} outer roots: {RING} runs of Dijkstra, or one run of Klein's algorithm?")
    add(2600, all_trees[0], all_dist[0], roots[0], set(), "One shortest-path tree to start",
        "Dijkstra from the first root. Shading shows the distance from it.",
        'zig-planar paths  ->  "parent"')
    seen = 0
    for i, step in enumerate(result["steps"], start=1):
        changed = {v for v, _ in step}
        seen += len(step)
        add(750, all_trees[i], all_dist[i], roots[i], changed, f"Root {i + 1} of {RING}",
            f"{len(step)} vertices take a new parent (red). The rest of the tree stays.",
            f'"steps": {seen} parent changes so far, never more than {darts} darts')
    durations[-1] = 1600
    add(4200, all_trees[-1], all_dist[-1], roots[-1], set(), f"{RING} trees for the price of one",
        f"{total} parent changes in all: each dart enters the tree at most once (Klein, 2005).",
        "Every tree checked against Dijkstra from its root.")

    frames[0].save(OUT, save_all=True, append_images=frames[1:], duration=durations, loop=0, optimize=True, disposal=1)
    print(f"{n} vertices, {len(edges)} edges, {total} changes, {len(frames)} frames, {OUT.stat().st_size // 1024} KB")


if __name__ == "__main__":
    main()
