#!/usr/bin/env python3
"""Generate the built-in water areas, water.bin, from the US Census Bureau's TIGER/Line AREAWATER (public domain).

The app uses them to tell when the straight line from the starting place to a station crosses a river or a bay, so a
straight-line walk estimate can't be trusted (WaterMap.swift). Standard library and curl only.

Usage (inside the CatchMyTrain folder; FOLDER is any empty folder outside the project, about 50 MB):
    python3 -I tools/generate_water.py plan FOLDER   # picks the counties of the service area and the newest TIGER year
    python3 -I tools/generate_water.py get FOLDER    # downloads one AREAWATER zip per county from www2.census.gov
    python3 -I tools/generate_water.py make FOLDER   # keeps 0.1 km² and up, simplifies to about 15 m: FOLDER/out/cmt-water.json
    python3 -I tools/generate_water.py pack FOLDER   # writes Packages/CatchCore/Sources/TransitCore/Resources/water.bin

What is kept: rivers, bays, the sea and canals of 0.1 km² or more, and lakes and reservoirs (MTFCC H2030, H2040) of 1 km² or
more (walking around a smaller one costs a few minutes at most). Outlines are simplified with the Douglas-Peucker algorithm to
about 15 meters. The service area is ServiceArea.boxes in TransitSystems.swift, read from there (see service_boxes).

water.bin: "CMTW", a version byte (1), then unsigned LEB128 numbers: the number of shapes; for each shape the number of rings;
for each ring the number of points, then each point as zigzag-encoded differences from the ring's previous point (the first
from 0, 0) of longitude and latitude in units of 0.00001 degree. Rings are closed (the last point repeats the first).
"""
import hashlib, json, math, os, struct, subprocess, sys, zipfile

STATES = {"09", "10", "24", "25", "33", "34", "36", "42", "44"}  # CT, DE, MD, MA, NH, NJ, NY, PA, RI
MIN_AREA = 100_000.0  # m² of water (AWATER)
MIN_LAKE_AREA = 1_000_000.0  # m², lakes and reservoirs
LAKES = {"H2030", "H2040"}
TOL_M = 15.0
YEARS = [2027, 2026, 2025, 2024]
BASE = "https://www2.census.gov/geo/tiger"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Packages", "CatchCore", "Sources", "TransitCore",
                   "Resources", "water.bin")


def curl(args):
    return subprocess.run(["curl", "-sS", "-L", "--fail", "--retry", "3"] + args, capture_output=True)


def head_size(url):
    r = curl(["-I", url])
    if r.returncode != 0:
        return None
    size = None
    for line in r.stdout.decode("latin-1").splitlines():
        if line.lower().startswith("content-length:"):
            size = int(line.split(":")[1].strip())
    return size


def service_boxes():
    """ServiceArea.boxes in TransitSystems.swift as (lat min, lat max, lon min, lon max), read the way
    tools/generate_area_docs.py reads them, so the water kept follows the service area when a box changes"""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import generate_area_docs
    return [(lat0, lat1, lon0, lon1) for lon0, lon1, lat0, lat1 in generate_area_docs.service_boxes()]


BOXES = service_boxes()


def boxes_hit(minx, miny, maxx, maxy):
    return any(miny <= la1 and maxy >= la0 and minx <= lo1 and maxx >= lo0 for la0, la1, lo0, lo1 in BOXES)


def read_dbf(data):
    n = struct.unpack("<I", data[4:8])[0]
    hlen, rlen = struct.unpack("<HH", data[8:12])
    fields, pos = [], 32
    while data[pos] != 0x0D:
        fields.append((data[pos:pos + 11].split(b"\0")[0].decode(), data[pos + 16]))
        pos += 32
    rows = []
    for i in range(n):
        rec = data[hlen + i * rlen: hlen + (i + 1) * rlen]
        row, p = {}, 1
        for name, flen in fields:
            row[name] = rec[p:p + flen].decode("utf-8", "replace").strip()
            p += flen
        rows.append(row)
    return rows


def read_shp(data):
    """(bbox, rings) for each record; rings are lists of (lon, lat)"""
    pos = 100
    while pos < len(data):
        clen = struct.unpack(">i", data[pos + 4:pos + 8])[0] * 2
        c = data[pos + 8:pos + 8 + clen]
        pos += 8 + clen
        if struct.unpack("<i", c[0:4])[0] == 0:
            yield None, []
            continue
        bbox = struct.unpack("<4d", c[4:36])
        nparts, npts = struct.unpack("<2i", c[36:44])
        parts = list(struct.unpack("<%di" % nparts, c[44:44 + 4 * nparts])) + [npts]
        pts = struct.unpack("<%dd" % (2 * npts), c[44 + 4 * nparts:44 + 4 * nparts + 16 * npts])
        yield bbox, [[(pts[2 * j], pts[2 * j + 1]) for j in range(parts[k], parts[k + 1])] for k in range(nparts)]


def zip_member(z, suffix):
    for name in z.namelist():
        if name.lower().endswith(suffix):
            return z.read(name)
    raise SystemExit("no " + suffix + " in zip")


def simplify(ring, tol_m):
    """Douglas-Peucker in local meters; [] when nothing with an area is left"""
    if len(ring) < 5:
        return ring
    lat0 = math.radians(ring[0][1])
    kx, ky = 111320.0 * math.cos(lat0), 110540.0
    xy = [(p[0] * kx, p[1] * ky) for p in ring]
    keep = [False] * len(ring)
    keep[0] = keep[-1] = True
    stack = [(0, len(ring) - 1)]
    while stack:
        a, b = stack.pop()
        if b - a <= 1:
            continue
        (ax, ay), (bx, by) = xy[a], xy[b]
        dx, dy = bx - ax, by - ay
        length = math.hypot(dx, dy)
        best, bi = -1.0, -1
        for i in range(a + 1, b):
            px, py = xy[i]
            d = abs(dx * (ay - py) - dy * (ax - px)) / length if length > 0 else math.hypot(px - ax, py - ay)
            if d > best:
                best, bi = d, i
        if best > tol_m:
            keep[bi] = True
            stack += [(a, bi), (bi, b)]
    out = [p for p, k in zip(ring, keep) if k]
    return out if len(out) >= 4 else []


def plan(folder):
    os.makedirs(folder, exist_ok=True)
    cfile = os.path.join(folder, "counties.zip")
    got = None
    for y in YEARS:
        url = "%s/GENZ%d/shp/cb_%d_us_county_5m.zip" % (BASE, y, y)
        if head_size(url) and curl(["-o", cfile, url]).returncode == 0:
            got = y
            break
    if not got:
        raise SystemExit("could not get the county outline file")
    z = zipfile.ZipFile(cfile)
    picks = sorted((row["GEOID"], row.get("NAME", ""), row.get("STUSPS", ""))
                   for row, (bbox, _) in zip(read_dbf(zip_member(z, ".dbf")), read_shp(zip_member(z, ".shp")))
                   if bbox and row.get("STATEFP") in STATES and boxes_hit(*bbox))
    year = next((y for y in YEARS
                 if head_size("%s/TIGER%d/AREAWATER/tl_%d_%s_areawater.zip" % (BASE, y, y, picks[0][0]))), None)
    if not year:
        raise SystemExit("no AREAWATER year found")
    files, total, missing = [], 0, []
    for geoid, name, st in picks:
        url = "%s/TIGER%d/AREAWATER/tl_%d_%s_areawater.zip" % (BASE, year, year, geoid)
        s = head_size(url)
        if s is None:
            missing.append(geoid)
            continue
        files.append({"geoid": geoid, "name": name, "state": st, "url": url, "size": s})
        total += s
    json.dump({"year": year, "county_year": got, "files": files, "missing": missing},
              open(os.path.join(folder, "plan.json"), "w"), indent=1)
    print("TIGER year", year, "| counties", len(picks), "| files", len(files), "| missing", missing)
    print("total download %.1f MB" % (total / 1e6))


def get(folder):
    p = json.load(open(os.path.join(folder, "plan.json")))
    raw = os.path.join(folder, "raw")
    os.makedirs(raw, exist_ok=True)
    sums = []
    for f in p["files"]:
        dest = os.path.join(raw, f["url"].rsplit("/", 1)[1])
        if not (os.path.exists(dest) and os.path.getsize(dest) == f["size"]):
            r = curl(["-o", dest, f["url"]])
            if r.returncode != 0:
                print("FAILED", f["geoid"], r.stderr.decode()[:200])
                continue
        sums.append("%s  %s" % (hashlib.sha256(open(dest, "rb").read()).hexdigest(), os.path.basename(dest)))
    open(os.path.join(folder, "raw-sha256.txt"), "w").write("\n".join(sums) + "\n")
    print("downloaded", len(sums), "of", len(p["files"]))


def make(folder):
    p = json.load(open(os.path.join(folder, "plan.json")))
    feats, seen = [], set()
    for f in p["files"]:
        path = os.path.join(folder, "raw", f["url"].rsplit("/", 1)[1])
        if not os.path.exists(path):
            print("missing", f["geoid"])
            continue
        z = zipfile.ZipFile(path)
        for row, (bbox, rings) in zip(read_dbf(zip_member(z, ".dbf")), read_shp(zip_member(z, ".shp"))):
            area = float(row.get("AWATER") or 0)
            if not bbox or area < MIN_AREA or not boxes_hit(*bbox) or row.get("HYDROID", "") in seen:
                continue
            seen.add(row.get("HYDROID", ""))
            out = [[round(v, 5) for pt in s for v in pt] for s in (simplify(r, TOL_M) for r in rings) if s]
            if out:
                feats.append({"id": row.get("HYDROID", ""), "n": row.get("FULLNAME", ""), "m": row.get("MTFCC", ""),
                              "a": round(area), "c": f["geoid"], "r": out})
    os.makedirs(os.path.join(folder, "out"), exist_ok=True)
    doc = {"source": "US Census Bureau TIGER/Line %d AREAWATER (public domain)" % p["year"],
           "min_area_m2": MIN_AREA, "tolerance_m": TOL_M, "features": feats}
    json.dump(doc, open(os.path.join(folder, "out", "cmt-water.json"), "w"), separators=(",", ":"))
    print("kept", len(feats), "shapes")


def varint(n, out):
    while n >= 0x80:
        out.append((n & 0x7F) | 0x80)
        n >>= 7
    out.append(n)


def pack(folder):
    doc = json.load(open(os.path.join(folder, "out", "cmt-water.json")))
    shapes = [f for f in doc["features"] if f["m"] not in LAKES or f["a"] >= MIN_LAKE_AREA]
    out = bytearray(b"CMTW\x01")
    varint(len(shapes), out)
    points = 0
    for f in shapes:
        varint(len(f["r"]), out)
        for r in f["r"]:
            varint(len(r) // 2, out)
            px = py = 0
            for i in range(0, len(r), 2):
                x, y = round(r[i] * 1e5), round(r[i + 1] * 1e5)
                for d in (x - px, y - py):
                    varint((d << 1) ^ (d >> 63), out)
                px, py = x, y
                points += 1
    open(OUT, "wb").write(bytes(out))
    print("shapes", len(shapes), "| points", points, "| water.bin %d bytes" % len(out))


if __name__ == "__main__":
    {"plan": plan, "get": get, "make": make, "pack": pack}[sys.argv[1]](sys.argv[2])
