"""Render docs/four-colours.gif from the output of the zig-planar command line.

Run from the repository root after `zig build`:

    uv run --with numpy --with scipy --with matplotlib python docs/four-colours.py
"""

import io
import json
import subprocess
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from matplotlib.patches import Polygon
from PIL import Image
from scipy.spatial import Voronoi

ROOT = Path(__file__).resolve().parent.parent
EXE = ROOT / "zig-out" / "bin" / "zig-planar"
OUT = ROOT / "docs" / "four-colours.gif"

W, H = 1.6, 1.0
REGIONS = 28
PALETTE = ["#4e79a7", "#f28e2b", "#59a14f", "#e15759"]
BLANK = "#e9e9ec"
INK = "#24292f"
MUTED = "#57606a"


def voronoi_map(seed):
    """Regions of a Voronoi diagram clipped to the W x H rectangle by mirroring."""
    rng = np.random.default_rng(seed)
    pts = rng.random((REGIONS, 2)) * [W, H]
    for _ in range(8):
        cells, edges = cells_and_edges(pts)
        pts = np.array([centroid(c) for c in cells])
    cells, edges = cells_and_edges(pts)
    return pts, cells, edges


def cells_and_edges(pts):
    mirrored = [pts]
    for axis, bound in ((0, 0.0), (0, W), (1, 0.0), (1, H)):
        m = pts.copy()
        m[:, axis] = 2 * bound - m[:, axis]
        mirrored.append(m)
    vor = Voronoi(np.vstack(mirrored))
    cells = [vor.vertices[vor.regions[vor.point_region[i]]] for i in range(len(pts))]
    edges = sorted({tuple(sorted(map(int, p))) for p in vor.ridge_points if p[0] < len(pts) and p[1] < len(pts)})
    return cells, edges


def centroid(poly):
    x, y = poly[:, 0], poly[:, 1]
    cross = x * np.roll(y, -1) - np.roll(x, -1) * y
    area = cross.sum() / 2
    return np.array([((x + np.roll(x, -1)) * cross).sum(), ((y + np.roll(y, -1)) * cross).sum()]) / (6 * area)


def colourable(n, edges, k):
    adj = [[] for _ in range(n)]
    for u, v in edges:
        adj[u].append(v)
        adj[v].append(u)
    order = sorted(range(n), key=lambda v: -len(adj[v]))
    colour = [-1] * n

    def place(i):
        if i == n:
            return True
        v = order[i]
        for c in range(k):
            if all(colour[w] != c for w in adj[v]):
                colour[v] = c
                if place(i + 1):
                    return True
        colour[v] = -1
        return False

    return place(0)


def run(command, payload):
    out = subprocess.run([str(EXE), command], input=json.dumps(payload), capture_output=True, text=True, check=True)
    return json.loads(out.stdout)


def frame(pts, cells, edges, colours, shown, graph, title, body, command):
    fig = plt.figure(figsize=(7.2, 5.4), dpi=100)
    fig.patch.set_facecolor("white")
    ax = fig.add_axes([0.03, 0.25, 0.94, 0.73])
    ax.set_xlim(-0.01, W + 0.01)
    ax.set_ylim(-0.01, H + 0.01)
    ax.set_aspect("equal")
    ax.axis("off")
    for i, cell in enumerate(cells):
        face = PALETTE[colours[i]] if i in shown else BLANK
        ax.add_patch(Polygon(cell, closed=True, facecolor=face, edgecolor="white", linewidth=2.2))
    if graph:
        for u, v in edges:
            ax.plot(*zip(pts[u], pts[v]), color=INK, linewidth=1.1, alpha=0.75, zorder=3)
        ax.scatter(pts[:, 0], pts[:, 1], s=28, color=INK, zorder=4)
    fig.text(0.5, 0.185, title, ha="center", fontsize=15, fontweight="bold", color=INK)
    fig.text(0.5, 0.115, body, ha="center", fontsize=11.5, color=INK)
    fig.text(0.5, 0.045, command, ha="center", fontsize=10.5, family="monospace", color=MUTED)
    buf = io.BytesIO()
    fig.savefig(buf, format="png", facecolor="white")
    plt.close(fig)
    buf.seek(0)
    return Image.open(buf).convert("RGB").quantize(colors=48, method=Image.Quantize.MEDIANCUT)


def main():
    seed = 1
    while True:
        pts, cells, edges = voronoi_map(seed)
        if not colourable(REGIONS, edges, 3):
            break
        seed += 1

    graph = {"n": REGIONS, "edges": [list(e) for e in edges]}
    planar = run("planar", graph)
    assert planar["planar"]
    result = run("color", {**graph, "method": "four"})
    colours = result["colors"]
    assert result["used"] == 4
    assert all(colours[u] != colours[v] for u, v in edges)

    order = sorted(range(REGIONS), key=lambda i: (pts[i][0] + 0.35 * pts[i][1]))
    frames, durations = [], []

    def add(image, ms):
        frames.append(image)
        durations.append(ms)

    def scene(shown, show_graph, title, body, command, ms):
        add(frame(pts, cells, edges, colours, shown, show_graph, title, body, command), ms)

    intro = "Colour any map so that regions sharing a border get different colours."
    scene(set(), False, "The four colour theorem", intro, "How many colours does it take?", 2800)
    scene(set(), True, "A map is a planar graph",
          "Each region is a vertex. Each shared border is an edge.",
          f'zig-planar planar  ->  "planar": {json.dumps(planar["planar"])}, with an embedding', 3200)
    shown = set()
    for i in order:
        shown.add(i)
        scene(set(shown), True, "Colouring the graph colours the map",
              "No two neighbours ever share a colour.",
              f'zig-planar color  {{"method": "four"}}  ->  "used": {result["used"]}', 140)
    durations[-1] = 1200
    scene(shown, False, "Four colours are always enough",
          "Every planar map needs at most four (Appel and Haken, 1976).",
          "This one needs all four: no 3-colouring exists.", 4200)

    frames[0].save(OUT, save_all=True, append_images=frames[1:], duration=durations, loop=0, optimize=True, disposal=1)
    print(f"seed {seed}: {REGIONS} regions, {len(edges)} borders, {len(frames)} frames, {OUT.stat().st_size // 1024} KB")


if __name__ == "__main__":
    main()
