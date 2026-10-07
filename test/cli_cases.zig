//! Command-line cases run by `zig build test-cli`. `stdout` is compared
//! exactly, `stderr` as a substring.

pub const Case = struct {
    name: []const u8,
    args: []const []const u8,
    stdin: ?[]const u8 = null,
    stdout: ?[]const u8 = null,
    stderr: ?[]const u8 = null,
    exit: u8 = 0,
};

pub const cases = [_]Case{
    .{
        .name = "planar: K4 with its faces",
        .args = &.{"planar"},
        .stdin = "{\"n\":4,\"edges\":[[0,1],[0,2],[0,3],[1,2],[1,3],[2,3]]}",
        .stdout = "{\"planar\":true,\"rotation\":[[1,3,2],[0,2,3],[1,0,3],[2,0,1]],\"faces\":[[0,1,2],[0,3,1],[0,2,3],[1,3,2]]}\n",
    },
    .{
        .name = "planar: K3,3 with a certificate",
        .args = &.{"planar"},
        .stdin = "{\"n\":6,\"edges\":[[0,3],[0,4],[0,5],[1,3],[1,4],[1,5],[2,3],[2,4],[2,5]],\"certificate\":true}",
        .stdout = "{\"planar\":false,\"kuratowski\":{\"kind\":\"K3,3\",\"edges\":[[0,3],[0,4],[0,5],[1,3],[1,4],[1,5],[2,3],[2,4],[2,5]]}}\n",
    },
    .{
        .name = "planar: K5 without a certificate",
        .args = &.{"planar"},
        .stdin = "{\"n\":5,\"edges\":[[0,1],[0,2],[0,3],[0,4],[1,2],[1,3],[1,4],[2,3],[2,4],[3,4]]}",
        .stdout = "{\"planar\":false}\n",
    },
    .{
        .name = "color: four on the octahedron",
        .args = &.{"color"},
        .stdin = "{\"n\":6,\"edges\":[[0,1],[0,2],[0,3],[0,4],[5,1],[5,2],[5,3],[5,4],[1,2],[2,3],[3,4],[4,1]]}",
        .stdout = "{\"colors\":[2,0,1,0,1,2],\"used\":3,\"passes\":1,\"exact_steps\":0}\n",
    },
    .{
        .name = "color: greedy on K5",
        .args = &.{"color"},
        .stdin = "{\"n\":5,\"edges\":[[0,1],[0,2],[0,3],[0,4],[1,2],[1,3],[1,4],[2,3],[2,4],[3,4]],\"method\":\"greedy\"}",
        .stdout = "{\"colors\":[4,0,1,2,3],\"used\":5}\n",
    },
    .{
        .name = "error: four on K5",
        .args = &.{"color"},
        .stdin = "{\"n\":5,\"edges\":[[0,1],[0,2],[0,3],[0,4],[1,2],[1,3],[1,4],[2,3],[2,4],[3,4]]}",
        .stderr = "the graph is not planar; four needs a planar graph",
        .exit = 1,
    },
    .{
        .name = "error: unknown method",
        .args = &.{"color"},
        .stdin = "{\"n\":1,\"edges\":[],\"method\":\"three\"}",
        .stderr = "method must be four, five or greedy, not three",
        .exit = 1,
    },
    .{
        .name = "error: edge outside the graph",
        .args = &.{"planar"},
        .stdin = "{\"n\":2,\"edges\":[[0,5]]}",
        .stderr = "edge 0: 5 is not a node index below 2",
        .exit = 1,
    },
    .{
        .name = "error: edge with three values",
        .args = &.{"planar"},
        .stdin = "{\"n\":3,\"edges\":[[0,1,2]]}",
        .stderr = "edge 0 has 3 values, expected 2",
        .exit = 1,
    },
    .{
        .name = "error: fractional node count",
        .args = &.{"planar"},
        .stdin = "{\"n\":2.5,\"edges\":[]}",
        .stderr = "n must be a whole number of nodes",
        .exit = 1,
    },
    .{
        .name = "error: truncated JSON",
        .args = &.{"color"},
        .stdin = "{",
        .stderr = "invalid input",
        .exit = 1,
    },
    .{
        .name = "error: unknown command",
        .args = &.{"bogus"},
        .stderr = "unknown command: bogus",
        .exit = 2,
    },
    .{
        .name = "error: no command prints usage",
        .args = &.{},
        .stderr = "usage: zig-planar COMMAND",
        .exit = 2,
    },
    .{
        .name = "help: exits 0",
        .args = &.{"--help"},
    },
};
