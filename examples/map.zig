const std = @import("std");
const planar = @import("planar");

const Country = enum { argentina, bolivia, brazil, chile, colombia, ecuador, french_guiana, guyana, paraguay, peru, suriname, uruguay, venezuela };

fn border(a: Country, b: Country) planar.Edge {
    return .{ @backingInt(a), @backingInt(b) };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    // Land borders of mainland South America. Argentina, Bolivia, Brazil and Paraguay all
    // border each other, so three colours are not enough.
    const borders = [_]planar.Edge{
        border(.argentina, .bolivia),      border(.argentina, .brazil),     border(.argentina, .chile),
        border(.argentina, .paraguay),     border(.argentina, .uruguay),    border(.bolivia, .brazil),
        border(.bolivia, .chile),          border(.bolivia, .paraguay),     border(.bolivia, .peru),
        border(.brazil, .colombia),        border(.brazil, .french_guiana), border(.brazil, .guyana),
        border(.brazil, .paraguay),        border(.brazil, .peru),          border(.brazil, .suriname),
        border(.brazil, .uruguay),         border(.brazil, .venezuela),     border(.chile, .peru),
        border(.colombia, .ecuador),       border(.colombia, .peru),        border(.colombia, .venezuela),
        border(.ecuador, .peru),           border(.guyana, .suriname),      border(.guyana, .venezuela),
        border(.suriname, .french_guiana),
    };
    const n = std.enums.values(Country).len;
    const g = try planar.Graph.init(gpa, n, &borders);
    defer g.deinit(gpa);

    const e = (try planar.planarity.embed(gpa, g)).?;
    defer e.deinit(gpa);
    std.debug.assert(try e.genus(gpa) == 0);

    const colors = try planar.color.four(gpa, g, .{});
    defer gpa.free(colors);
    std.debug.assert(planar.color.isProper(g, colors, 4));
    std.debug.assert(planar.color.count(colors) == 4);

    // A graph that is not a map: the Petersen graph contains a subdivided K3,3.
    const petersen = try planar.Graph.init(gpa, 10, &.{
        .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 3, 4 }, .{ 4, 0 },
        .{ 0, 5 }, .{ 1, 6 }, .{ 2, 7 }, .{ 3, 8 }, .{ 4, 9 },
        .{ 5, 7 }, .{ 7, 9 }, .{ 9, 6 }, .{ 6, 8 }, .{ 8, 5 },
    });
    defer petersen.deinit(gpa);
    const cert = (try planar.kuratowski.find(gpa, petersen)).?;
    defer gpa.free(cert);
    std.debug.assert(try planar.kuratowski.classify(gpa, 10, cert) == .k33);
}
