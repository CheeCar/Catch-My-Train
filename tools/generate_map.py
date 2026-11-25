#!/usr/bin/env python3
"""Generate the built-in subway map lines, subway_map.json, from MTA's official static GTFS.

Usage (inside the CatchMyTrain folder):
    curl -O https://rrgtfsfeeds.s3.amazonaws.com/gtfs_subway.zip
    python3 tools/generate_map.py gtfs_subway.zip

Same approach as SubwayMapBuilder in the app (the app checks for updates itself once a month, from the 1st, New York time):
- each route takes all the shapes it uses, keeping only northbound (N) ones so no segment is drawn twice;
- polylines are simplified with the Douglas-Peucker algorithm to a tolerance of about 8 meters, coordinates kept to 5 decimal places;
- colors come from routes.txt, stations (stop ID, name, coordinates) from stops.txt.
"""
import csv, io, json, os, sys, zipfile

TOLERANCE = 0.00008  # degrees, about 8 meters


def simplify(points, tol=TOLERANCE):
    if len(points) < 3:
        return points
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        a, b = stack.pop()
        (ay, ax), (by, bx) = points[a], points[b]
        dx, dy = bx - ax, by - ay
        norm = (dx * dx + dy * dy) ** 0.5
        best, idx = 0.0, -1
        for i in range(a + 1, b):
            py, px = points[i]
            if norm == 0:
                d = ((px - ax) ** 2 + (py - ay) ** 2) ** 0.5
            else:
                d = abs(dy * px - dx * py + bx * ay - by * ax) / norm
            if d > best:
                best, idx = d, i
        if best > tol and idx > 0:
            keep[idx] = True
            stack.append((a, idx))
            stack.append((idx, b))
    return [p for p, k in zip(points, keep) if k]


def build(z):
    def rows(name):
        return csv.DictReader(io.TextIOWrapper(z.open(name), encoding="utf-8-sig"))

    colors = {r["route_id"]: r["route_color"] or "808183" for r in rows("routes.txt")}
    shape_route = {}
    for t in rows("trips.txt"):
        if t.get("shape_id"):
            shape_route.setdefault(t["shape_id"], t["route_id"])
    pts = {}
    for r in rows("shapes.txt"):
        sid = r["shape_id"]
        if sid not in shape_route or ".N" not in sid:
            continue
        pts.setdefault(sid, []).append((int(r["shape_pt_sequence"]), float(r["shape_pt_lat"]), float(r["shape_pt_lon"])))
    routes = {}
    for sid, p in sorted(pts.items()):
        p.sort()
        line = simplify([(lat, lon) for _, lat, lon in p])
        routes.setdefault(shape_route[sid], []).append([[round(a, 5), round(b, 5)] for a, b in line])
    stations = [[s["stop_id"], s["stop_name"], round(float(s["stop_lat"]), 5), round(float(s["stop_lon"]), 5)]
                for s in rows("stops.txt") if s.get("location_type") == "1"]
    version = ""
    try:
        version = next(rows("feed_info.txt")).get("feed_version", "")
    except Exception:
        pass
    return {
        "source": "MTA static GTFS (rrgtfsfeeds gtfs_subway.zip)",
        "feedVersion": version,
        "stations": stations,
        "routes": [{"route": r, "color": colors.get(r, "808183"), "lines": routes[r]} for r in sorted(routes)],
    }


if __name__ == "__main__":
    with zipfile.ZipFile(sys.argv[1]) as z:
        data = build(z)
    # Never replace the bundled file with empty data (e.g. the wrong zip)
    if not data["routes"] or not data["stations"]:
        sys.exit("No routes or stations found: subway_map.json was not changed.")
    out = "Packages/CatchCore/Sources/TransitCore/Resources/subway_map.json"
    # A temp file next to the bundled one, then swapped in, so a failed run never leaves a half-written file
    with open(out + ".tmp", "w") as f:
        json.dump(data, f, separators=(",", ":"))
    os.replace(out + ".tmp", out)
    n = sum(len(l) for r in data["routes"] for l in r["lines"])
    print(out, len(data["routes"]), "routes", sum(len(r["lines"]) for r in data["routes"]), "lines", n, "points")
