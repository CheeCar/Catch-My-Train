#!/usr/bin/env python3
"""Generate the county outlines of the metro areas, area_counties.bin, from the US Census Bureau's cartographic boundary file.

The app tells which metro area and which region a place is in by the county it is in (areas.json lists each area's counties;
Connecticut's are its planning regions). Standard library and curl only.

Usage (inside the CatchMyTrain folder; FOLDER is any empty folder outside the project, about 20 MB):
    python3 -I tools/generate_areas.py get FOLDER    # downloads cb_2023_us_county_500k.zip from www2.census.gov and unpacks it
    python3 -I tools/generate_areas.py make FOLDER   # writes Packages/CatchCore/Sources/TransitCore/Resources/area_counties.bin
                                                      # and tools/area-county-names.json (for tools/generate_area_docs.py)
    python3 -I tools/generate_areas.py check         # checks the service area for holes with the area_counties.bin there is

`make` also reads a copy of the same file that was unpacked into FOLDER some other way (cb_2023_us_county_500k.shp and .dbf).
The Census Bureau's boundary files are in the public domain.

What is kept: every county areas.json names, in an area or under "outside", its outline simplified with the Douglas-Peucker
algorithm to about 20 meters. "outside" is the counties in no area that the service area's boxes (ServiceArea.boxes in
TransitSystems.swift, read from there) reach into: a place in one is outside the service area. `make` checks that the list is
exactly those counties, so a box that grows into another county stops it until the county is put in an area or in the list.
The cartographic boundary file's outlines follow the shore, so piers and the water between two counties are in neither; the
app takes the nearest county there (TransitCore, CountyMap).

The service area has no holes (rule 6 in docs/metro-areas.md): a part of the areas' counties that the boxes leave out between
parts of the service area, even with no stop nearby, is taken in by widening a box to the county or state line. `make` and
`check` look for such parts on a grid of about 1 km: every connected part of the areas' counties outside the boxes, and the
cells around it. A part at the service area's outer edge borders on the sea, on counties in no area or on land beyond them. A
part is a hole when its border is at least 70% service area, or when at least half of it lies between two parts of the service
area along a row or a column of the grid (a notch the boxes leave at a state line or the sea, with service area on both sides);
a hole stops `make` (nothing is written) or `check`, naming where it is.

area_counties.bin: "CMTC", a version byte (1), then unsigned LEB128 numbers: the number of counties; for each county its FIPS
code as a number, the number of rings, and for each ring the number of points, then each point as zigzag-encoded differences
from the ring's previous point (the first from 0, 0) of longitude and latitude in units of 0.00001 degree. Rings are closed
(the last point repeats the first). Holes are rings too: a point is in a county when it is inside an odd number of its rings.
"""
import json, math, os, struct, subprocess, sys, zipfile

YEAR = 2023
NAME = "cb_%d_us_county_500k" % YEAR
URL = "https://www2.census.gov/geo/tiger/GENZ%d/shp/%s.zip" % (YEAR, NAME)
TOL_M = 20.0
HERE = os.path.dirname(os.path.abspath(__file__))
RES = os.path.join(HERE, "..", "Packages", "CatchCore", "Sources", "TransitCore", "Resources")
AREAS = os.path.join(RES, "areas.json")
OUT = os.path.join(RES, "area_counties.bin")
NAMES = os.path.join(HERE, "area-county-names.json")
STATES = {"09": "CT", "10": "DE", "23": "ME", "24": "MD", "25": "MA", "33": "NH", "34": "NJ", "36": "NY", "42": "PA", "44": "RI", "50": "VT"}


def counties_in_areas():
    data = json.load(open(AREAS, encoding="utf-8"))
    out = []
    for area in data["areas"]:
        for region in area["regions"]:
            out += region["counties"]
    if len(out) != len(set(out)):
        sys.exit("a county is listed twice in areas.json")
    return set(out)


def counties_outside():
    out = json.load(open(AREAS, encoding="utf-8")).get("outside", [])
    if len(out) != len(set(out)):
        sys.exit("a county is listed twice in areas.json's \"outside\"")
    return set(out)


def reaches(rings, boxes):
    """Whether a county's outline (rings of (lon, lat)) reaches into any of the boxes (lon0, lon1, lat0, lat1): one of its
    edges crosses a box, or a box lies inside it"""
    def crosses(a, b, box):
        x0, x1, y0, y1 = box
        t0, t1 = 0.0, 1.0
        for p, q in ((a[0] - b[0], a[0] - x0), (b[0] - a[0], x1 - a[0]), (a[1] - b[1], a[1] - y0), (b[1] - a[1], y1 - a[1])):
            if p == 0:
                if q < 0:
                    return False
                continue
            t = q / p
            if p < 0:
                t0 = max(t0, t)
            else:
                t1 = min(t1, t)
            if t0 > t1:
                return False
        return True
    xs = [p[0] for r in rings for p in r]
    ys = [p[1] for r in rings for p in r]
    for box in boxes:
        if box[0] > max(xs) or min(xs) > box[1] or box[2] > max(ys) or min(ys) > box[3]:
            continue
        if any(crosses(a, b, box) for r in rings for a, b in zip(r, r[1:])):
            return True
        x, y, inside = (box[0] + box[1]) / 2, (box[2] + box[3]) / 2, False
        for r in rings:
            for (ax, ay), (bx, by) in zip(r, r[1:]):
                if (ay > y) != (by > y) and x < ax + (y - ay) * (bx - ax) / (by - ay):
                    inside = not inside
        if inside:
            return True
    return False


HOLE_STEP = 0.01   # degrees: the hole check's grid, about 1 km
HOLE_SHARE = 0.7   # a part left out whose border is at least this much service area is a hole
HOLE_BETWEEN = 0.5  # ... and so is one at least this much of which lies between two parts of the service area


def in_boxes(lon, lat, boxes):
    return any(b[0] <= lon <= b[1] and b[2] <= lat <= b[3] for b in boxes)


def between(cells, state):
    """The cells of a part left out (cells: (row, column) pairs of the grid; state: as in holes) that lie between two parts of
    the service area: along their row or their column, the part's run of cells there has service area at both ends. A notch
    the boxes leave at a state line or the sea, with service area on both sides, is one; a part at the outer edge isn't"""
    rows, cols = len(state), len(state[0])
    def served(a, b):
        return 0 <= a < rows and 0 <= b < cols and state[a][b] == 1
    def runs(values):
        values = sorted(values)
        start = values[0]
        for x, y in zip(values, values[1:] + [None]):
            if y != x + 1:
                yield start, x
                start = y
    by_row, by_col = {}, {}
    for a, b in cells:
        by_row.setdefault(a, []).append(b)
        by_col.setdefault(b, []).append(a)
    found = set()
    for a, bs in by_row.items():
        for b0, b1 in runs(bs):
            if served(a, b0 - 1) and served(a, b1 + 1):
                found.update((a, b) for b in range(b0, b1 + 1))
    for b, rs in by_col.items():
        for a0, a1 in runs(rs):
            if served(a0 - 1, b) and served(a1 + 1, b):
                found.update((a, b) for a in range(a0, a1 + 1))
    return found


def holes(outlines, listed, boxes, step=HOLE_STEP, share=HOLE_SHARE, between_share=HOLE_BETWEEN):
    """The holes in the service area (see the note at the top): for each, its size in km², its south, north, west and east
    edges and its counties. outlines: county code -> rings of (lon, lat); listed: the codes of the areas' counties; boxes:
    (lon0, lon1, lat0, lat1)"""
    lat0, lat1 = min(b[2] for b in boxes) - 0.3, max(b[3] for b in boxes) + 0.3
    lon0, lon1 = min(b[0] for b in boxes) - 0.3, max(b[1] for b in boxes) + 0.3
    rows, cols = int((lat1 - lat0) / step) + 1, int((lon1 - lon0) / step) + 1
    lats = [lat0 + (i + 0.5) * step for i in range(rows)]
    lons = [lon0 + (j + 0.5) * step for j in range(cols)]
    # Each cell's county: along each row of cell centers, between pairs of crossings of the county's rings (so a hole in a
    # county, a ring inside its outline, isn't the county's)
    county = [[None] * cols for _ in range(rows)]
    for code, rings in outlines.items():
        crossings = {}
        for ring in rings:
            for (x1, y1), (x2, y2) in zip(ring, ring[1:]):
                if y1 == y2:
                    continue
                first = max(0, math.ceil((min(y1, y2) - lat0) / step - 0.5))
                last = min(rows - 1, math.floor((max(y1, y2) - lat0) / step - 0.5))
                for i in range(first, last + 1):
                    if (y1 > lats[i]) != (y2 > lats[i]):
                        crossings.setdefault(i, []).append(x1 + (lats[i] - y1) * (x2 - x1) / (y2 - y1))
        for i, xs in crossings.items():
            xs.sort()
            for a, b in zip(xs[0::2], xs[1::2]):
                for j in range(max(0, math.ceil((a - lon0) / step - 0.5)), min(cols - 1, math.floor((b - lon0) / step - 0.5)) + 1):
                    county[i][j] = code
    # 1: in the service area; 0: an area's county, outside the boxes; None: anything else (the sea, a county in no area)
    state = [[(1 if in_boxes(lons[j], lats[i], boxes) else 0) if county[i][j] in listed else None for j in range(cols)]
             for i in range(rows)]
    found, seen = [], set()
    for i in range(rows):
        for j in range(cols):
            if state[i][j] != 0 or (i, j) in seen:
                continue
            seen.add((i, j))
            stack, cells, border, served = [(i, j)], [], 0, 0
            while stack:
                a, b = stack.pop()
                cells.append((a, b))
                for x, y in ((a + 1, b), (a - 1, b), (a, b + 1), (a, b - 1)):
                    inside = 0 <= x < rows and 0 <= y < cols
                    if inside and state[x][y] == 0:
                        if (x, y) not in seen:
                            seen.add((x, y))
                            stack.append((x, y))
                        continue
                    border += 1
                    if inside and state[x][y] == 1:
                        served += 1
            if served >= share * border or len(between(cells, state)) >= between_share * len(cells):
                km2 = sum((step * 111.0) ** 2 * math.cos(math.radians(lats[a])) for a, _ in cells)
                found.append((km2, min(lats[a] for a, _ in cells), max(lats[a] for a, _ in cells),
                              min(lons[b] for _, b in cells), max(lons[b] for _, b in cells),
                              sorted({county[a][b] for a, b in cells})))
    return sorted(found, reverse=True)


def hole_report(found, county_names):
    """The message for holes found (see holes); county_names: each county's code -> its name and state"""
    lines = ["about %d km² at %.2f° to %.2f° N, %.2f° to %.2f° W, in %s" % (
        round(km2), south, north, -west, -east, ", ".join("%s %s" % (c, county_names.get(c, "")) for c in counties))
        for km2, south, north, west, east, counties in found]
    return ("the service area has a hole (rule 6 in docs/metro-areas.md): widen a box in ServiceArea.boxes over it to the "
            "county or state line\n- " + "\n- ".join(lines))


def check():
    """Checks the service area for holes with the area_counties.bin there is (no download)"""
    sys.path.insert(0, HERE)
    import generate_area_docs
    names = json.load(open(NAMES, encoding="utf-8")) if os.path.exists(NAMES) else {}
    found = holes(generate_area_docs.read_county_outlines(), counties_in_areas(), generate_area_docs.service_boxes())
    if found:
        sys.exit(hole_report(found, names))
    print("no holes in the service area")


def read_dbf(path):
    f = open(path, "rb").read()
    count = struct.unpack("<I", f[4:8])[0]
    head, size = struct.unpack("<HH", f[8:12])
    fields, i = [], 32
    while f[i] != 0x0D:
        fields.append((f[i:i + 11].split(b"\0")[0].decode(), f[i + 16]))
        i += 32
    rows = []
    for n in range(count):
        rec, pos, row = f[head + n * size: head + (n + 1) * size], 1, {}
        for name, length in fields:
            row[name] = rec[pos:pos + length].decode("latin-1").strip()
            pos += length
        rows.append(row)
    return rows


def read_shp(path):
    """Polygons (shape type 5) as lists of rings of (lon, lat)"""
    f = open(path, "rb").read()
    pos, shapes = 100, []
    while pos < len(f):
        length = struct.unpack(">i", f[pos + 4:pos + 8])[0] * 2
        rec = f[pos + 8:pos + 8 + length]
        pos += 8 + length
        kind = struct.unpack("<i", rec[:4])[0]
        if kind == 0:
            shapes.append([])
            continue
        if kind != 5:
            sys.exit("not a polygon file (shape type %d)" % kind)
        parts, points = struct.unpack("<ii", rec[36:44])
        starts = list(struct.unpack("<%di" % parts, rec[44:44 + 4 * parts])) + [points]
        base = 44 + 4 * parts
        xy = struct.unpack("<%dd" % (2 * points), rec[base:base + 16 * points])
        shapes.append([[(xy[2 * k], xy[2 * k + 1]) for k in range(starts[p], starts[p + 1])] for p in range(parts)])
    return shapes


def simplify(ring, tol_m):
    """Douglas-Peucker on a closed ring, in meters (local flat projection)"""
    if len(ring) < 5:
        return ring
    lat0 = sum(p[1] for p in ring) / len(ring)
    kx, ky = 111320.0 * math.cos(math.radians(lat0)), 110540.0
    pts = [(p[0] * kx, p[1] * ky) for p in ring]
    keep = [False] * len(pts)
    keep[0] = keep[-1] = True
    # Split the closed ring at its farthest point from the start, so both halves are open lines
    far = max(range(len(pts)), key=lambda k: (pts[k][0] - pts[0][0]) ** 2 + (pts[k][1] - pts[0][1]) ** 2)
    keep[far] = True
    stack = [(0, far), (far, len(pts) - 1)]
    while stack:
        a, b = stack.pop()
        if b - a < 2:
            continue
        ax, ay = pts[a]
        bx, by = pts[b]
        dx, dy = bx - ax, by - ay
        norm = math.hypot(dx, dy)
        best, idx = -1.0, -1
        for k in range(a + 1, b):
            px, py = pts[k]
            d = abs(dy * (px - ax) - dx * (py - ay)) / norm if norm else math.hypot(px - ax, py - ay)
            if d > best:
                best, idx = d, k
        if best > tol_m:
            keep[idx] = True
            stack += [(a, idx), (idx, b)]
    out = [p for p, k in zip(ring, keep) if k]
    return out if len(out) >= 4 else ring


def leb(n, out):
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return


def zig(n):
    return (n << 1) ^ (n >> 63)


def get(folder):
    os.makedirs(folder, exist_ok=True)
    dest = os.path.join(folder, NAME + ".zip")
    r = subprocess.run(["curl", "-sS", "-L", "--fail", "--retry", "3", "-o", dest, URL], capture_output=True, text=True)
    if r.returncode:
        sys.exit("download failed: " + r.stderr.strip())
    with zipfile.ZipFile(dest) as z:
        for ext in ("shp", "dbf"):
            z.extract("%s.%s" % (NAME, ext), folder)
    print("got", dest)


def make(folder):
    listed, outside = counties_in_areas(), counties_outside()
    if listed & outside:
        sys.exit("in an area and in \"outside\" too: " + ", ".join(sorted(listed & outside)))
    wanted = listed | outside
    sys.path.insert(0, HERE)
    import generate_area_docs
    boxes = generate_area_docs.service_boxes()
    rows = read_dbf(os.path.join(folder, NAME + ".dbf"))
    shapes = read_shp(os.path.join(folder, NAME + ".shp"))
    if len(rows) != len(shapes):
        sys.exit("the .dbf and .shp files don't match")
    found, reached = {}, set()
    for row, rings in zip(rows, shapes):
        if rings and reaches(rings, boxes):
            reached.add(row["GEOID"])
        if row["GEOID"] in wanted:
            found[row["GEOID"]] = (row.get("NAMELSAD", ""), row.get("STUSPS") or STATES.get(row["STATEFP"], row["STATEFP"]), rings)
    missing = sorted(wanted - set(found))
    if missing:
        sys.exit("not in the boundary file: " + ", ".join(missing))
    problems = ["the boxes reach %s, which is in no area and not in \"outside\"" % c for c in sorted(reached - wanted)]
    problems += ["%s is in \"outside\", but the boxes don't reach it" % c for c in sorted(outside - reached)]
    problems += ["%s is in an area, but the boxes don't reach it" % c for c in sorted(listed - reached)]
    if problems:
        sys.exit("areas.json doesn't match ServiceArea.boxes:\n- " + "\n- ".join(problems))
    simplified = {geoid: [simplify(r, TOL_M) for r in found[geoid][2]] for geoid in sorted(found)}
    gaps = holes(simplified, listed, boxes)
    if gaps:
        sys.exit(hole_report(gaps, {geoid: "%s, %s" % (found[geoid][0], found[geoid][1]) for geoid in found}))
    out = bytearray(b"CMTC\x01")
    leb(len(found), out)
    points = 0
    for geoid in sorted(found):
        name, state, rings = found[geoid]
        kept = simplified[geoid]
        leb(int(geoid), out)
        leb(len(kept), out)
        for ring in kept:
            leb(len(ring), out)
            px = py = 0
            for lon, lat in ring:
                x, y = round(lon * 100000), round(lat * 100000)
                leb(zig(x - px), out)
                leb(zig(y - py), out)
                px, py = x, y
            points += len(ring)
        print("%s %s, %s: %d rings, %d points%s" % (geoid, name, state, len(kept), sum(len(r) for r in kept),
                                                   " (outside)" if geoid in outside else ""))
    open(OUT, "wb").write(bytes(out))
    names = {geoid: "%s, %s" % (found[geoid][0], found[geoid][1]) for geoid in sorted(listed)}
    open(NAMES, "w", encoding="utf-8").write(json.dumps(names, indent=1, ensure_ascii=False) + "\n")
    print("wrote %s: %d counties (%d outside), %d points, %d bytes" % (os.path.normpath(OUT), len(found), len(outside), points, len(out)))


if __name__ == "__main__":
    if sys.argv[1:] == ["check"]:
        check()
    elif len(sys.argv) == 3 and sys.argv[1] in ("get", "make"):
        {"get": get, "make": make}[sys.argv[1]](sys.argv[2])
    else:
        sys.exit(__doc__)
