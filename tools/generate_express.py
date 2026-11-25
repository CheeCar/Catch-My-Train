#!/usr/bin/env python3
"""Generate the "express stops" data express_stops.json from MTA's official static GTFS.

Usage (in the CatchMyTrain folder; gtfs_subway.zip comes from https://rrgtfsfeeds.s3.amazonaws.com/gtfs_subway.zip):
    python3 tools/generate_express.py gtfs_subway.zip

Method: a train leaves station A and its next stop is B. If the timetable has other trains leaving A
that stop at other stations before reaching B (same direction), this train skipped the stations in between, so it's an express.
Results list, per "station ID + direction", the "next stops that mean express", e.g. "712N": ["707"]
(on the 7 line at 61 St-Woodside toward Manhattan, a next stop of Junction Blvd means express).
The app looks up each train's next stop from realtime data in this table, so trains switched to all-stops service at night correctly show as local.
"""
import csv, io, json, os, sys, zipfile


def build(z):
    def rows(name):
        return csv.DictReader(io.TextIOWrapper(z.open(name), encoding="utf-8-sig"))

    trips = {}
    platform_rows = bad = 0
    for r in rows("stop_times.txt"):
        stop = r["stop_id"]
        if stop[-1:] not in ("N", "S"):
            continue
        platform_rows += 1
        try:
            sequence = int(r["stop_sequence"])
        except ValueError:
            # A row whose stop_sequence isn't a number is skipped; more than one in a hundred means the data is broken
            bad += 1
            continue
        trips.setdefault(r["trip_id"], []).append((sequence, stop))
    if bad:
        print(f"warning: {bad} stop_times with a stop_sequence that isn't a number (skipped)", file=sys.stderr)
        if bad * 100 > platform_rows:
            sys.exit("Too many unreadable stop_times rows: express_stops.json was not changed.")
    patterns = set()
    for seq in trips.values():
        seq.sort()
        patterns.add(tuple(s for _, s in seq))
    direct, later = set(), set()
    for p in patterns:
        stations = [(s[:-1], s[-1]) for s in p]
        for i, (a, d) in enumerate(stations):
            if i + 1 < len(stations) and stations[i + 1][1] == d:
                direct.add((a, d, stations[i + 1][0]))
            for b, d2 in stations[i + 2:]:
                if d2 == d and b != a:
                    later.add((a, d, b))
    result = {}
    for a, d, b in sorted(direct & later):
        result.setdefault(a + d, []).append(b)
    return result


if __name__ == "__main__":
    with zipfile.ZipFile(sys.argv[1]) as z:
        data = build(z)
    # Never replace the bundled file with empty data (e.g. the wrong zip)
    if not data:
        sys.exit("No express stops found: express_stops.json was not changed.")
    out = "Packages/CatchCore/Sources/TransitCore/Resources/express_stops.json"
    # A temp file next to the bundled one, then swapped in, so a failed run never leaves a half-written file
    with open(out + ".tmp", "w") as f:
        json.dump(data, f, separators=(",", ":"), sort_keys=True)
    os.replace(out + ".tmp", out)
    print(out, len(data), "station-directions with express service")
