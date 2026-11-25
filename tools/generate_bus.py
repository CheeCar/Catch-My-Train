#!/usr/bin/env python3
"""Generate the app's bundled bus data from MTA's official static bus GTFS.

Usage (in the CatchMyTrain folder): first download the 6 bus data packages (free, no key needed)
    for b in bx b m q si busco; do curl -O https://rrgtfsfeeds.s3.amazonaws.com/gtfs_$b.zip; done
    python3 tools/generate_bus.py gtfs_bx.zip gtfs_b.zip gtfs_m.zip gtfs_q.zip gtfs_si.zip gtfs_busco.zip

Produces two files (Packages/CatchCore/Sources/TransitCore/Resources/):
- bus_stops.json: each bus stop (stop ID, name, coordinates) and the routes + directions through it; each route's color, both directions' terminals, and whether it's express.
- bus_map.json: the bus map (one direction's path per route, Douglas-Peucker simplified to about 15 m).
"""
import csv, io, json, os, re, sys, zipfile
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(__file__))
from generate_map import simplify  # noqa: E402

SMALL = {"of", "and", "via", "to", "the", "at"}
KEEP_UPPER = {"SBS", "JFK", "LIRR", "CUNY", "NYC", "MTA", "US", "VA", "LGA", "PATH", "II", "III", "IV", "SI", "UPS"}


def nice(name):
    """'WILLIS AV/E 138 ST' → 'Willis Av / E 138 St'"""
    name = re.sub(r"\s*/\s*", " / ", name.strip())
    words = []
    for i, w in enumerate(name.split()):
        if w.upper() in KEEP_UPPER:
            words.append(w.upper())
        elif re.match(r"^\d+(ST|ND|RD|TH)$", w, re.I):
            words.append(w.lower())
        elif i > 0 and w.lower() in SMALL:
            words.append(w.lower())
        else:
            words.append("-".join(p[:1].upper() + p[1:].lower() for p in w.split("-")))
    return " ".join(words)


def headsign(h):
    h = re.sub(r"^\+?\s*(SELECT BUS|LIMITED|LTD|EXPRESS)\s+", "", h.strip(), flags=re.I)
    h = re.split(r"\s+via\s+", h, flags=re.I)[0]
    return nice(h)


def is_express(route_id, short):
    if route_id.endswith("+") or "SBS" in short.upper():
        return True
    return bool(re.match(r"^(BXM|BM|QM|SIM|X)\d", route_id.upper()))


def main(paths):
    routes, stops = {}, {}
    route_dir_headsigns = defaultdict(Counter)
    stop_routes = defaultdict(set)
    shapes_for = defaultdict(Counter)  # (route, dir) -> shape counts
    shape_points = {}
    version = ""
    for path in paths:
        z = zipfile.ZipFile(path)

        def rows(name):
            return csv.DictReader(io.TextIOWrapper(z.open(name), encoding="utf-8-sig"))

        for r in rows("routes.txt"):
            routes.setdefault(r["route_id"], {
                "name": r["route_short_name"] or r["route_id"],
                "color": (r.get("route_color") or "0039A6").upper(),
                "express": is_express(r["route_id"], r["route_short_name"] or ""),
                "agency": r["agency_id"],
            })
        for s in rows("stops.txt"):
            # Generic nodes and boarding areas (location_type 3, 4) aren't stops and may have no coordinates; rows whose coordinates
            # can't be read are skipped too (the app's monthly rebuild does the same, see BusStaticBuilder)
            if (s.get("location_type") or "").strip() in ("3", "4"):
                continue
            try:
                lat, lon = float(s["stop_lat"]), float(s["stop_lon"])
            except (TypeError, ValueError):
                continue
            stops.setdefault(s["stop_id"], (nice(s["stop_name"]), round(lat, 5), round(lon, 5)))
        trip_rd = {}
        for t in rows("trips.txt"):
            d = t.get("direction_id") or "0"
            trip_rd[t["trip_id"]] = (t["route_id"], d)
            route_dir_headsigns[(t["route_id"], d)][headsign(t.get("trip_headsign", ""))] += 1
            if t.get("shape_id"):
                shapes_for[(t["route_id"], d)][t["shape_id"]] += 1
        for st in rows("stop_times.txt"):
            rd = trip_rd.get(st["trip_id"])
            if rd:
                stop_routes[st["stop_id"]].add(rd)
        wanted = {c.most_common(1)[0][0] for c in shapes_for.values()}
        for r in rows("shapes.txt"):
            if r["shape_id"] in wanted:
                shape_points.setdefault(r["shape_id"], []).append(
                    (int(r["shape_pt_sequence"]), float(r["shape_pt_lat"]), float(r["shape_pt_lon"])))
        try:
            version = max(version, next(rows("feed_info.txt")).get("feed_version", ""))
        except Exception:
            pass

    route_out = {}
    for rid, info in routes.items():
        hs = {d: route_dir_headsigns[(rid, d)].most_common(1)[0][0]
              for d in ("0", "1") if route_dir_headsigns[(rid, d)]}
        if not hs:
            continue
        route_out[rid] = {"name": info["name"], "color": info["color"], "express": info["express"],
                          "agency": info["agency"], "headsigns": hs}
    stop_out = []
    for sid in sorted(stop_routes):
        if sid not in stops:
            continue
        name, lat, lon = stops[sid]
        rds = sorted(f"{r}|{d}" for r, d in stop_routes[sid] if r in route_out)
        if rds:
            stop_out.append([sid, name, lat, lon, rds])
    # Never replace the bundled files with empty data (e.g. the wrong zips)
    if not route_out or not stop_out:
        sys.exit("No routes or stops found: the bundled files were not changed.")
    write("bus_stops.json", {"source": "MTA bus static GTFS (rrgtfsfeeds gtfs_bx/b/m/q/si/busco.zip)", "feedVersion": version,
                             "routes": route_out, "stops": stop_out}, ensure_ascii=False)

    # Map: for each route take the most common direction-0 path (the other direction mostly overlaps, so it isn't drawn twice)
    map_routes = []
    for rid in sorted(route_out):
        lines = []
        c = shapes_for.get((rid, "0")) or shapes_for.get((rid, "1"))
        if c:
            sid = c.most_common(1)[0][0]
            pts = sorted(shape_points.get(sid, []))
            line = simplify([(a, b) for _, a, b in pts], 0.00015)
            if len(line) >= 2:
                lines.append([[round(a, 5), round(b, 5)] for a, b in line])
        if lines:
            map_routes.append({"route": rid, "color": route_out[rid]["color"], "lines": lines})
    write("bus_map.json", {"source": "MTA bus static GTFS", "feedVersion": version, "stations": [], "routes": map_routes})
    print(len(route_out), "routes", len(stop_out), "stops", sum(len(l) for r in map_routes for l in r["lines"]), "map points")


OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Packages", "CatchCore", "Sources", "TransitCore", "Resources")


def write(name, data, ensure_ascii=True):
    """Write a temp file next to the bundled one, then swap it in, so a failed run never leaves a half-written file."""
    path = os.path.join(OUT_DIR, name)
    with open(path + ".tmp", "w") as f:
        json.dump(data, f, separators=(",", ":"), ensure_ascii=ensure_ascii)
    os.replace(path + ".tmp", path)


if __name__ == "__main__":
    if len(sys.argv) != 7:
        sys.exit(__doc__)
    main(sys.argv[1:])
