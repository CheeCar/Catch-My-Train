#!/usr/bin/env python3
"""Generates the app's built-in station data subway_stations.json from the official MTA static GTFS.

Usage (in the CatchMyTrain folder):
    curl -O https://rrgtfsfeeds.s3.amazonaws.com/gtfs_subway.zip
    python3 tools/generate_stations.py gtfs_subway.zip

Output: Packages/CatchCore/Sources/TransitCore/Resources/subway_stations.json
Each station has: GTFS station ID, name, coordinates, and for each route serving it the most common terminal in each direction (used as direction names).
In MTA static GTFS, direction_id 0 corresponds to the stop ID suffix N and 1 to S (this script checks that).

It also reads tools/data/mta_stations.psv (an extract of the official MTA "MTA Subway Stations" table) and adds:
- complex: complex ID. Stations in the same complex allow in-station transfers, e.g. 42 St-Bryant Pk and 5 Av;
- borough: the borough (M / Bx / Bk / Q / SI);
- northLabel / southLabel: direction names on station signs, e.g. "Uptown" "Manhattan".
"""
# Static GTFS occasionally lacks trips for a station in one direction (e.g. 7 line 52 St, 69 St northbound); fill in the terminal manually.
FILL = {(sid, r, "N"): "Flushing-Main St" for sid in ("710", "711", "713") for r in ("7", "7X")}

import csv, io, json, os, sys, zipfile
from collections import Counter, defaultdict

def rows(z, name):
    return csv.DictReader(io.TextIOWrapper(z.open(name), "utf-8-sig"))

def read_labels(path):
    """GTFS Stop ID -> (Complex ID, Borough, North label, South label)."""
    labels = {}
    if not os.path.exists(path):
        print(f"warning: {path} not found, stations will have no direction labels", file=sys.stderr)
        return labels
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            stop_id, complex_id, borough, _routes, north, south = line.split("|")
            labels[stop_id] = (complex_id, borough, north, south)
    return labels

def main(path, out, labels_path):
    labels = read_labels(labels_path)
    z = zipfile.ZipFile(path)
    feed = next(rows(z, "feed_info.txt"))
    stops = {s["stop_id"]: s for s in rows(z, "stops.txt")}
    trips = {t["trip_id"]: t for t in rows(z, "trips.txt")}

    # (parent, route, N/S) -> Counter(headsign)
    heads = defaultdict(Counter)
    mismatch = 0
    for st in rows(z, "stop_times.txt"):
        t = trips.get(st["trip_id"])
        stop = stops.get(st["stop_id"])
        if not t or not stop or not stop["parent_station"]:
            continue
        suffix = st["stop_id"][-1]
        expected = "N" if t["direction_id"] == "0" else "S"
        if suffix != expected:
            mismatch += 1
            continue
        heads[(stop["parent_station"], t["route_id"], suffix)][t["trip_headsign"]] += 1
    if mismatch:
        print(f"warning: {mismatch} stop_times where direction_id and N/S suffix disagree (skipped)", file=sys.stderr)

    by_station = defaultdict(dict)
    for (parent, route, d), c in heads.items():
        by_station[parent].setdefault(route, {})[d] = c.most_common(1)[0][0]

    stations = []
    listed = bad = 0
    for sid, s in stops.items():
        if s["location_type"] != "1" or sid not in by_station:
            continue
        listed += 1
        try:
            lat, lon = float(s["stop_lat"]), float(s["stop_lon"])
        except ValueError:
            # A station whose position isn't a number is left out; more than one in a hundred means the data is broken
            bad += 1
            continue
        routes = [
            {"route": r, "north": v.get("N", FILL.get((sid, r, "N"))), "south": v.get("S", FILL.get((sid, r, "S")))}
            for r, v in sorted(by_station[sid].items())
        ]
        station = {
            "id": sid,
            "name": s["stop_name"],
            "lat": round(lat, 6),
            "lon": round(lon, 6),
            "routes": routes,
        }
        if sid in labels:
            complex_id, borough, north, south = labels[sid]
            station.update({"complex": complex_id, "borough": borough, "northLabel": north, "southLabel": south})
        else:
            print(f"warning: no MTA label row for station {sid}", file=sys.stderr)
        stations.append(station)
    if bad:
        print(f"warning: {bad} stations whose position isn't a number (left out)", file=sys.stderr)
        if bad * 100 > listed:
            sys.exit(f"Too many stations without a position: {out} was not changed.")
    # Never replace the bundled file with empty data (e.g. the wrong zip)
    if not stations:
        sys.exit(f"No stations found: {out} was not changed.")
    stations.sort(key=lambda x: x["id"])
    doc = {
        "source": "MTA New York City Transit static GTFS (https://rrgtfsfeeds.s3.amazonaws.com/gtfs_subway.zip)",
        "feedVersion": feed.get("feed_version", ""),
        "feedStartDate": feed.get("feed_start_date", ""),
        "feedEndDate": feed.get("feed_end_date", ""),
        "stations": stations,
    }
    # A temp file next to the bundled one, then swapped in, so a failed run never leaves a half-written file
    with open(out + ".tmp", "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, separators=(",", ":"))
    os.replace(out + ".tmp", out)
    print(f"wrote {len(stations)} stations to {out}")

if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    default_out = os.path.join(here, "..", "Packages", "CatchCore", "Sources", "TransitCore", "Resources", "subway_stations.json")
    default_labels = os.path.join(here, "data", "mta_stations.psv")
    main(sys.argv[1] if len(sys.argv) > 1 else "gtfs_subway.zip",
         sys.argv[2] if len(sys.argv) > 2 else default_out,
         sys.argv[3] if len(sys.argv) > 3 else default_labels)
