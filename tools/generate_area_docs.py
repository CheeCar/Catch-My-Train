#!/usr/bin/env python3
"""Write what README.md and the docs/data-sources pages say about the metro areas, from the app's own list of them.

The app's metro areas, their regions and counties, and which operators run in each are in
Packages/CatchCore/Sources/TransitCore/Resources/areas.json; what the pages say about each area (what it covers, the towns on
the map, its operator tables, the keys some operators need) is in tools/area-docs.json. Adding an area means adding it to those
two files and running this script: no page is edited by hand for it. Standard library only.

Usage (inside the CatchMyTrain folder):
    python3 -I tools/generate_area_docs.py check            # checks area-docs.json against areas.json, writes nothing
    python3 -I tools/generate_area_docs.py write            # writes the pages
    python3 -I tools/generate_area_docs.py write FOLDER     # writes the pages and the map
FOLDER is the folder `tools/generate_areas.py get FOLDER` downloaded the US Census Bureau's county boundary file into: the map's
land and state lines come from it, so the map is redrawn only when an area, its counties or its places change. The counties'
names come from tools/area-county-names.json, which `tools/generate_areas.py make` writes.

What it writes:
- README.md, between <!-- generated:NAME --> and <!-- /generated:NAME -->: "intro" (the number of areas in the first paragraph, or
  with only one, its name) and "service-area" (the sentence under the Service area heading, and the map). README.md names no operators: its data section says what
  the app covers in general words and links docs/data-sources.md.
- docs/data-sources.md, between <!-- generated:areas --> and <!-- /generated:areas -->: the list of areas, each linking its page.
- docs/metro-areas.md, whole: how the metro areas are drawn. First the rules (area-docs.json's "rules"), then for each area the
  government's metro area it starts from and the counties added or left out, and why.
- docs/data-sources/AREA.md, whole: what the area covers, its counties, every operator that runs there (an operator in two
  areas is on both pages), the keys and accounts some of them need, and its stations without times (from source-list.json;
  a station's area is found the way the app finds it, by the county it is in, from area_counties.bin).
- docs/images/service-area-map.svg: the map, light only (GitHub on an iPad or a phone doesn't show a picture that changes with the
  dark theme, so the README shows this one in both; service-area-map-dark.svg isn't written any more). Land and state
  lines from the county boundary file, each metro area's counties shaded and outlined, cut to the app's service area
  (ServiceArea.boxes in TransitSystems.swift, read from there) the way the app's own map draws it, with the area's name
  written inside it. The colors aren't chosen per area: PALETTE has a few that can be told apart with any kind of color
  vision, and each area gets one its neighbors don't have (see area_colors), so adding an area needs no new color. The
  Census Bureau's boundary files are in the public domain.

The check fails when a metro area in areas.json has no entry in area-docs.json (or the other way round), when an operator
areas.json puts in an area isn't in one of that area's rows (or a row names one that isn't there), when an operator with
stations without times has no "positions" entry, or when an area's counties in areas.json aren't the government's ("official"),
plus those "added", minus those "leftOut": a county can't change without docs/metro-areas.md saying why.
"""
import json, math, os, re, sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
AREAS = os.path.join(ROOT, "Packages", "CatchCore", "Sources", "TransitCore", "Resources", "areas.json")
DOCS = os.path.join(HERE, "area-docs.json")
README = os.path.join(ROOT, "README.md")
SOURCES = os.path.join(ROOT, "docs", "data-sources.md")
METRO_AREAS = os.path.join(ROOT, "docs", "metro-areas.md")
DELINEATION = "https://www.census.gov/geographies/reference-files/time-series/demo/metro-micro/delineation-files.html"
RES = os.path.join(ROOT, "Packages", "CatchCore", "Sources", "TransitCore", "Resources")
SOURCE_LIST = os.path.join(RES, "source-list.json")
COUNTIES = os.path.join(RES, "area_counties.bin")
COUNTY_NAMES = os.path.join(HERE, "area-county-names.json")
PAGES = os.path.join(ROOT, "docs", "data-sources")
MAP = os.path.join(ROOT, "docs", "images", "service-area-map.svg")
MAP_LINK = "docs/images/service-area-map.svg"
MARGIN_KM = 15.0
SERVICE_AREA = os.path.join(ROOT, "Packages", "CatchCore", "Sources", "TransitCore", "TransitSystems.swift")
NAME = "cb_2023_us_county_500k"
NUMBERS = ["no", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
# The map's colors: bluish green, vermilion, blue, reddish purple, orange and sky blue of the Okabe-Ito set, which stay apart
# for people with any kind of color vision. Two pairs of them look alike (the two blues, and orange and vermilion: under ALIKE
# apart in CIELAB, every other pair is over 50), so neighbors don't get both of a pair while another color is free
PALETTE = ["#009e73", "#d55e00", "#0072b2", "#cc79a7", "#e69f00", "#56b4e9"]
ALIKE = 45.0


def load():
    areas = json.load(open(AREAS, encoding="utf-8"))
    docs = json.load(open(DOCS, encoding="utf-8"))
    sources = json.load(open(SOURCE_LIST, encoding="utf-8"))
    return areas, docs, sources


def check(areas, docs, sources):
    """The problems found, as sentences; empty when area-docs.json matches areas.json"""
    problems = []
    ids = [a["id"] for a in areas["areas"]]
    doc_ids = [a["id"] for a in docs["areas"]]
    if ids != doc_ids:
        problems.append("area-docs.json has the areas %s, areas.json %s (same ones, same order)" % (doc_ids, ids))
    by_id = {a["id"]: a for a in docs["areas"]}
    for area in ids:
        entry = by_id.get(area)
        if not entry:
            continue
        running = {op["id"] for op in areas["operators"] if area in op["areas"]}
        covered = defaultdict(int)
        for group in entry["groups"]:
            for row in group["rows"]:
                for op in row["ops"]:
                    covered[op] += 1
        for op in sorted(running - set(covered)):
            problems.append("%s: operator %s runs there (areas.json) but no row of area-docs.json names it" % (area, op))
        for op in sorted(set(covered) - running):
            problems.append("%s: a row names operator %s, which areas.json doesn't put there" % (area, op))
        for op, n in sorted(covered.items()):
            if n > 1:
                problems.append("%s: operator %s is in %d rows" % (area, op, n))
        for key in ("slug", "covers", "label", "places", "groups"):
            if not entry.get(key):
                problems.append("%s: no %s in area-docs.json" % (area, key))
        if entry.get("color"):
            problems.append("%s: has a \"color\": the map picks the colors itself (see PALETTE)" % area)
        label = entry.get("label")
        if label and not (isinstance(label, list) and len(label) == 2 and all(isinstance(v, (int, float)) for v in label)):
            problems.append("%s: \"label\" is where its name goes on the map, as [latitude, longitude]" % area)
        for place in entry.get("places", []):
            if len(place) > 3 and place[3] not in ("left", "above"):
                problems.append("%s: place %s is written \"%s\" of its dot: only \"left\" or \"above\" (or nothing, right)" % (
                    area, place[0], place[3]))
    listed = {a["id"]: [c for r in a["regions"] for c in r["counties"]] for a in areas["areas"]}
    for area in ids:
        entry = by_id.get(area)
        if not entry:
            continue
        official = entry.get("official", {})
        if not official.get("name") or not official.get("counties"):
            problems.append("%s: no \"official\" with \"name\" and \"counties\" (the government's metro area it starts from)" % area)
            continue
        added = [c for group in entry.get("added", []) for c in group["counties"]]
        left_out = [c for group in entry.get("leftOut", []) for c in group["counties"]]
        for group in entry.get("added", []) + entry.get("leftOut", []):
            if not group.get("text") or not group.get("counties"):
                problems.append("%s: an \"added\" or \"leftOut\" group needs \"counties\" and the \"text\" saying why" % area)
        for c in added:
            if c in official["counties"]:
                problems.append("%s: %s is added, but it is in the official area already" % (area, c))
        for c in left_out:
            if c not in official["counties"]:
                problems.append("%s: %s is left out, but it isn't in the official area" % (area, c))
        expected = (set(official["counties"]) | set(added)) - set(left_out)
        for c in sorted(expected - set(listed[area])):
            problems.append("%s: %s is official or added and not left out, but areas.json doesn't list it: say why in \"leftOut\"" % (area, c))
        for c in sorted(set(listed[area]) - expected):
            if c in left_out:
                problems.append("%s: %s is left out, but areas.json still lists it" % (area, c))
            else:
                problems.append("%s: areas.json lists %s, which isn't official: say why in \"added\"" % (area, c))
    if not docs.get("rules"):
        problems.append("no \"rules\" (docs/metro-areas.md starts with them)")
    for op in sources["stationsWithoutTimes"]["operators"]:
        if op["key"] not in docs["positions"]:
            problems.append("stations without times: no \"positions\" for %s" % op["key"])
    known = {op["id"] for op in areas["operators"]}
    for op in [o for k in docs["keys"] for o in k["ops"]]:
        if op not in known:
            problems.append("area-docs.json names operator %s, which areas.json doesn't have" % op)
    return problems


def names(areas):
    return {a["id"]: a["name"] for a in areas["areas"]}


def joined(items, word="and"):
    return items[0] if len(items) == 1 else ", ".join(items[:-1]) + " %s " % word + items[-1]


def number(n):
    return NUMBERS[n] if n < len(NUMBERS) else str(n)


def called(area, areas):
    """An area as a sentence names it: "the New York Metropolitan Area", or its "inText" ("Greater Boston", no "the")"""
    return area.get("inText") or "the " + names(areas)[area["id"]]


# MARK: - Where a place is (as the app finds it: TransitCore, CountyMap)

def read_county_outlines():
    """area_counties.bin (see tools/generate_areas.py): {FIPS code: [rings of (lon, lat)]}"""
    data = open(COUNTIES, "rb").read()
    if data[:5] != b"CMTC\x01":
        sys.exit("area_counties.bin isn't version 1")
    pos = 5
    def num():
        nonlocal pos
        n, shift = 0, 0
        while True:
            b = data[pos]
            pos += 1
            n |= (b & 0x7F) << shift
            if b < 0x80:
                return n
            shift += 7
    def unzig(n):
        return (n >> 1) ^ -(n & 1)
    out = {}
    for _ in range(num()):
        code, rings = num(), []
        for _ in range(num()):
            x = y = 0
            ring = []
            for _ in range(num()):
                x += unzig(num())
                y += unzig(num())
                ring.append((x / 100000, y / 100000))
            rings.append(ring)
        out["%05d" % code] = rings
    return out


def county_of(lon, lat, outlines):
    """The county a place is in, or the nearest one within MARGIN_KM (piers, the water between two counties); None beyond"""
    for code, rings in outlines.items():
        inside = False
        for ring in rings:
            for (x1, y1), (x2, y2) in zip(ring, ring[1:]):
                if (y1 > lat) != (y2 > lat) and lon < x1 + (lat - y1) * (x2 - x1) / (y2 - y1):
                    inside = not inside
        if inside:
            return code
    kx = 111.32 * math.cos(math.radians(lat))
    best, nearest = MARGIN_KM ** 2, None
    for code, rings in outlines.items():
        for ring in rings:
            for (x1, y1), (x2, y2) in zip(ring, ring[1:]):
                ax, ay, bx, by = (x1 - lon) * kx, (y1 - lat) * 110.57, (x2 - lon) * kx, (y2 - lat) * 110.57
                dx, dy = bx - ax, by - ay
                t = max(0.0, min(1.0, -(ax * dx + ay * dy) / (dx * dx + dy * dy))) if dx or dy else 0.0
                d = (ax + t * dx) ** 2 + (ay + t * dy) ** 2
                if d < best:
                    best, nearest = d, code
    return nearest


# MARK: - The pages

def readme_blocks(areas, docs):
    name = names(areas)
    count = len(docs["areas"])
    full = [name[a["id"]] for a in docs["areas"]]
    # The first paragraph gives the number of areas, never their names or a few of them (as if those were all): it stays one
    # line as areas are added, and its link to the Service area section (outside the markers) shows where they are. With one
    # area, its name: "It works in the New York Metropolitan Area (see the service area below)"
    intro = called(docs["areas"][0], areas) if count == 1 else "%s metro areas" % number(count)
    # Under the Service area heading, no names either: each area's page, listed in Data sources, says what it covers
    if count == 1:
        link = called(docs["areas"][0], areas).replace(full[0], "[%s](docs/data-sources/%s.md)" % (full[0], docs["areas"][0]["slug"]))
        text = ("The app covers %s, shown on the map below; its page lists the counties and cities it covers ([how they were "
                "chosen](docs/metro-areas.md)). Outside it, the app shows \"Outside the service area\"." % link)
        alt = "Map of the service area: %s, shaded and outlined, with state lines" % called(docs["areas"][0], areas)
    else:
        text = ("The app covers %s metro areas, shown on the map below. [Data sources](docs/data-sources.md) has a page for "
                "each, with the counties and cities it covers, and [How the metro areas are drawn](docs/metro-areas.md) says why "
                "those counties. Outside them, the app shows \"Outside the service area\"." % number(count))
        alt = ("Map of the service area: the %s metro areas, each shaded, outlined and named, neighbors in different colors, "
               "with state lines" % number(count))
    service = "\n".join([
        text, "", "<details open>", "<summary><b>Service area map</b> (click to collapse)</summary>", "<br>",
        '<img src="%s" width="640" alt="%s">' % (MAP_LINK, alt.replace('"', "&quot;")), "", "</details>"])
    return {"intro": intro, "service-area": service}


def index_block(areas, docs):
    name = names(areas)
    count = len(docs["areas"])
    out = ["The app covers %s metro area%s. Each has its own page with every operator that runs there (an operator in two areas "
           "is on both), the keys and accounts some of them need, and any stations without times:" % (
               number(count), "" if count == 1 else "s"), ""]
    out += ["- [%s](data-sources/%s.md): %s" % (name[a["id"]], a["slug"], a["covers"]) for a in docs["areas"]]
    out += ["", "[How the metro areas are drawn](metro-areas.md) says which counties each area has and why."]
    # The services some timetables come through, as the pages' rows name them ("through 511NY"), each once
    hosts = []
    for a in docs["areas"]:
        for group in a["groups"]:
            for row in group["rows"]:
                for host in re.findall(r"through ([^,()]+)", row["operator"]):
                    if host not in hosts:
                        hosts.append(host)
    if hosts:
        out += ["", "Some timetables come through %s, as noted on those pages." % joined(hosts, "or")]
    return "\n".join(out)


def area_page(area, areas, docs, sources, outlines, county_names):
    name = names(areas)[area["id"]]
    catalog = next(a for a in areas["areas"] if a["id"] == area["id"])
    running = {op["id"] for op in areas["operators"] if area["id"] in op["areas"]}
    codes = [c for r in catalog["regions"] for c in r["counties"]]
    planning = " (in Connecticut, its planning region)" if any(c.startswith("09") for c in codes) else ""
    out = ["<!-- Generated by tools/generate_area_docs.py from areas.json and tools/area-docs.json: don't edit by hand. -->", "",
           "# " + name, "", "[All metro areas](../data-sources.md)", "",
           "**Covers:** %s. The title bar shows which of these parts a place is in: %s." % (
               area["covers"], joined([r["name"] for r in catalog["regions"]], "or")),
           "", "**Counties:** %s. Within the service area, the app tells which metro area and which of its parts a place is in by "
           "its county%s, or, on the water or a pier, by the nearest county. [Why these counties](../metro-areas.md#%s)" % (
               "; ".join(county_names.get(c, c) for c in codes), planning, anchor(name)),
           "", "## Operators"]
    for group in area["groups"]:
        if group.get("heading"):
            out += ["", "### " + group["heading"]]
        out += ["", "| Operator | Runs | Real-time | Key needed |", "|---|---|---|---|"]
        out += ["| %s | %s | %s | %s |" % (r["operator"], r["runs"], r["realtime"], r["key"]) for r in group["rows"]]
    keys = [k for k in docs["keys"] if running & set(k["ops"])]
    if keys:
        out += ["", "## Keys and accounts", "",
                "Most real-time feeds here are free and need no key. For the ones below, you request a key or account yourself. "
                "Each is free, each person uses their own, and the app keeps it only in the macOS Keychain. Without it, that "
                "operator's times come from its timetable and are marked \"Timetable\", except where noted below.", ""]
        out += ["- " + k["text"] for k in keys]
    nt = sources["stationsWithoutTimes"]
    stations = defaultdict(list)
    for st in nt["stations"]:
        code = county_of(st["longitude"], st["latitude"], outlines)
        if code and any(code in r["counties"] for r in catalog["regions"]):
            stations[st["operator"]].append(st["name"])
    ops = [o for o in nt["operators"] if stations[o["key"]]]
    if ops:
        out += ["", "## Stations without times", "",
                "These operators don't publish their times in a form the app can use, so nothing is downloaded from them. The "
                "app lists their stations and piers without departures, with an **Open Website** button for the operator's own "
                "page. The sources in the last column are described under "
                "[Stations without times](../data-sources.md#stations-without-times).",
                "", "| Operator | Mode | Stations and piers | Positions from |", "|---|---|---|---|"]
        out += ["| %s | %s | %s | %s |" % (o["name"], o["mode"].capitalize(), ", ".join(stations[o["key"]]), docs["positions"][o["key"]])
                for o in ops]
    return "\n".join(out) + "\n"


def anchor(heading):
    """The link to a heading on GitHub: lower case, spaces to hyphens, other punctuation dropped"""
    return re.sub(r"[^a-z0-9 -]", "", heading.lower()).replace(" ", "-")


def metro_areas_page(areas, docs):
    name = names(areas)
    count = len(docs["areas"])
    out = ["<!-- Generated by tools/generate_area_docs.py from areas.json and tools/area-docs.json: don't edit by hand. -->", "",
           "# How the metro areas are drawn", "", "[All metro areas](data-sources.md)", "",
           "The app covers %s metro area%s. This page says which counties each one has and why: first the rules, then how each "
           "area follows them." % (number(count), "" if count == 1 else "s"), "", "## Rules", ""]
    out += ["%d. **%s.** %s" % (i + 1, rule["title"], rule["text"]) for i, rule in enumerate(docs["rules"])]
    out += ["", "The government's definitions are in the US Census Bureau's [delineation files](%s)." % DELINEATION]
    for area in docs["areas"]:
        official = area["official"]["counties"]
        ct = sum(1 for c in official if c.startswith("09"))
        if ct == len(official):
            size = "%d planning regions" % ct
        elif ct:
            size = "%d counties and Connecticut planning regions" % len(official)
        else:
            size = "%d counties" % len(official)
        out += ["", "## " + name[area["id"]], "", "- **Government's area:** %s (%s)." % (area["official"]["name"], size)]
        changes = [("Added", g["text"]) for g in area.get("added", [])] + [("Left out", g["text"]) for g in area.get("leftOut", [])]
        out += ["- **%s:** %s" % change for change in changes] or ["- **Changes:** none."]
        out += ["- [Counties and operators](data-sources/%s.md)" % area["slug"]]
    return "\n".join(out) + "\n"


def replace_block(text, tag, block, path, inline=False):
    start, end = "<!-- generated:%s -->" % tag, "<!-- /generated:%s -->" % tag
    if text.count(start) != 1 or text.count(end) != 1:
        sys.exit("%s needs one %s and one %s" % (path, start, end))
    i, j = text.index(start) + len(start), text.index(end)
    return text[:i] + (block if inline else "\n" + block + "\n") + text[j:]


# MARK: - The map

def read_counties(folder):
    """Every county in the boundary file: (FIPS code, state code, rings)"""
    sys.path.insert(0, HERE)
    import generate_areas as g
    rows = g.read_dbf(os.path.join(folder, NAME + ".dbf"))
    shapes = g.read_shp(os.path.join(folder, NAME + ".shp"))
    if len(rows) != len(shapes):
        sys.exit("the .dbf and .shp files don't match")
    return [(row["GEOID"], row["STATEFP"], rings) for row, rings in zip(rows, shapes)]


def simplify_line(points, tol):
    """Douglas-Peucker on an open line of (x, y)"""
    if len(points) < 3:
        return points
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        a, b = stack.pop()
        if b - a < 2:
            continue
        (ax, ay), (bx, by) = points[a], points[b]
        dx, dy = bx - ax, by - ay
        norm = math.hypot(dx, dy)
        best, idx = -1.0, -1
        for k in range(a + 1, b):
            px, py = points[k]
            d = abs(dy * (px - ax) - dx * (py - ay)) / norm if norm else math.hypot(px - ax, py - ay)
            if d > best:
                best, idx = d, k
        if best > tol:
            keep[idx] = True
            stack += [(a, idx), (idx, b)]
    return [p for p, k in zip(points, keep) if k]


def chain(edges):
    """Undirected edges (pairs of points) joined into lines"""
    nbrs = defaultdict(list)
    for a, b in edges:
        nbrs[a].append(b)
        nbrs[b].append(a)
    used, lines = set(), []
    def key(a, b):
        return (a, b) if a < b else (b, a)
    starts = [p for p in nbrs if len(nbrs[p]) != 2] + list(nbrs)
    for s in starts:
        for n in nbrs[s]:
            if key(s, n) in used:
                continue
            line, prev, cur = [s], s, n
            used.add(key(s, n))
            while True:
                line.append(cur)
                nxt = [m for m in nbrs[cur] if key(cur, m) not in used]
                if len(nbrs[cur]) != 2 or not nxt:
                    break
                used.add(key(cur, nxt[0]))
                prev, cur = cur, nxt[0]
            lines.append(line)
    return lines


def edges_of(rings):
    for ring in rings:
        for a, b in zip(ring, ring[1:]):
            if a != b:
                yield (a, b) if a < b else (b, a)


def service_boxes():
    """The app's service area, ServiceArea.boxes in TransitSystems.swift, as (lon0, lon1, lat0, lat1) boxes: the map shades and
    outlines only what is inside them, as the app's own map does"""
    text = open(SERVICE_AREA, encoding="utf-8").read()
    start = text.index("static let boxes")
    body = text[start:text.index("]\n", start)]
    num = r"(-?\d+(?:\.\d+)?)"
    boxes = [(float(lon0), float(lon1), float(lat0), float(lat1)) for lat0, lat1, lon0, lon1 in
             re.findall(r"\(%s\s*\.\.\.\s*%s,\s*%s\s*\.\.\.\s*%s\)" % (num, num, num, num), body)]
    if not boxes:
        sys.exit("found no ServiceArea.boxes in " + SERVICE_AREA)
    return boxes


def in_boxes(p, boxes):
    return any(b[0] <= p[0] <= b[1] and b[2] <= p[1] <= b[3] for b in boxes)


def clip_to_boxes(a, b, boxes):
    """The parts of the segment a-b inside any of the boxes"""
    spans = []
    for x0, x1, y0, y1 in boxes:
        t0, t1 = 0.0, 1.0
        for p, q in ((a[0] - b[0], a[0] - x0), (b[0] - a[0], x1 - a[0]), (a[1] - b[1], a[1] - y0), (b[1] - a[1], y1 - a[1])):
            if p == 0:
                if q < 0:
                    t0, t1 = 1.0, 0.0
                continue
            t = q / p
            if p < 0:
                t0 = max(t0, t)
            else:
                t1 = min(t1, t)
        if t1 - t0 > 1e-12:
            spans.append((t0, t1))
    spans.sort()
    merged = []
    for t0, t1 in spans:
        if merged and t0 <= merged[-1][1] + 1e-12:
            merged[-1] = (merged[-1][0], max(merged[-1][1], t1))
        else:
            merged.append((t0, t1))
    at = lambda t: (round(a[0] + (b[0] - a[0]) * t, 7), round(a[1] + (b[1] - a[1]) * t, 7))
    return [(at(t0), at(t1)) for t0, t1 in merged]


def box_edges(boxes):
    """The outline of the boxes together, as axis-aligned segments"""
    xs = sorted({v for b in boxes for v in b[:2]})
    ys = sorted({v for b in boxes for v in b[2:]})
    def filled(i, j):
        if not (0 <= i < len(xs) - 1 and 0 <= j < len(ys) - 1):
            return False
        return in_boxes(((xs[i] + xs[i + 1]) / 2, (ys[j] + ys[j + 1]) / 2), boxes)
    edges = []
    for i in range(-1, len(xs)):
        for j in range(-1, len(ys)):
            if filled(i, j) != filled(i + 1, j):
                edges.append(((xs[i + 1], ys[j]), (xs[i + 1], ys[j + 1])))
            if filled(i, j) != filled(i, j + 1):
                edges.append(((xs[i], ys[j + 1]), (xs[i + 1], ys[j + 1])))
    return edges


def inside_rings(p, rings):
    """Whether the point is inside the rings (even-odd)"""
    x, y = p
    hit = False
    for ring in rings:
        for (ax, ay), (bx, by) in zip(ring, ring[1:]):
            if (ay > y) != (by > y) and x < ax + (y - ay) * (bx - ax) / (by - ay):
                hit = not hit
    return hit


def split_by(seg, edges):
    """An axis-aligned segment cut where the edges cross it"""
    (ax, ay), (bx, by) = seg
    ts = {0.0, 1.0}
    for (cx, cy), (dx, dy) in edges:
        if ax == bx:
            if (cx - ax) * (dx - ax) < 0:
                y = cy + (ax - cx) * (dy - cy) / (dx - cx)
                ts.add((y - ay) / (by - ay))
        elif (cy - ay) * (dy - ay) < 0:
            x = cx + (ay - cy) * (dx - cx) / (dy - cy)
            ts.add((x - ax) / (bx - ax))
    ts = sorted(t for t in ts if 0 <= t <= 1)
    at = lambda t: (round(ax + (bx - ax) * t, 7), round(ay + (by - ay) * t, 7))
    return [(at(t0), at(t1)) for t0, t1 in zip(ts, ts[1:]) if t1 > t0]


def lab(color):
    """ "#rrggbb" in CIELAB, where the distance between two colors is about how different they look"""
    def linear(v):
        v /= 255
        return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = (linear(int(color[i:i + 2], 16)) for i in (1, 3, 5))
    x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
    y = 0.2126 * r + 0.7152 * g + 0.0722 * b
    z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
    f = lambda t: t ** (1 / 3) if t > 0.008856 else 7.787 * t + 16 / 116
    return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))


def area_colors(order, area_of, counties):
    """A color of PALETTE for each area, in `order`: never one a neighbor has (areas whose counties share a border); among the
    rest one used least so far, so the areas all differ while there are colors left and far ones share afterwards; among
    those, one that doesn't look like a neighbor's (ALIKE) before one that does; then the first in PALETTE. An area added
    at the end changes no earlier area's color"""
    owners = defaultdict(set)
    for geoid, _, rings in counties:
        if geoid in area_of:
            for e in edges_of(rings):
                owners[e].add(area_of[geoid])
    neighbors = defaultdict(set)
    for group in owners.values():
        for a in group:
            neighbors[a] |= group - {a}
    colors, used = {}, defaultdict(int)
    for area in order:
        taken = {colors[n] for n in neighbors[area] if n in colors}
        free = [c for c in PALETTE if c not in taken]
        if not free:
            sys.exit("the map needs more colors: %s touches areas of every color in PALETTE" % area)
        near = [lab(colors[n]) for n in neighbors[area] if n in colors]
        alike = lambda c: any(math.dist(lab(c), n) < ALIKE for n in near)
        colors[area] = min(free, key=lambda c: (used[c], alike(c), PALETTE.index(c)))
        used[colors[area]] += 1
    return colors


def shade(color, dark):
    """An area's color a shade darker for its outline and name (a shade lighter on the dark map): mixed with black 68:32, or
    with white 60:40"""
    rgb = [int(color[i:i + 2], 16) for i in (1, 3, 5)]
    mixed = [v * 0.6 + 255 * 0.4 for v in rgb] if dark else [v * 0.68 for v in rgb]
    return "#" + "".join("%02x" % int(v + 0.5) for v in mixed)


def name_lines(name):
    """An area's name on the map: on two lines when it has a space ("New York" over "Metropolitan Area", "Lehigh" over "Valley"),
    cut at the space that makes the two lines closest in length"""
    if " " not in name:
        return [name]
    cuts = [i for i, ch in enumerate(name) if ch == " "]
    cut = min(cuts, key=lambda i: max(i, len(name) - i - 1))
    return [name[:cut], name[cut + 1:]]


def draw_map(areas, docs, counties, dark=False):
    area_of = {}
    for area in areas["areas"]:
        for region in area["regions"]:
            for c in region["counties"]:
                area_of[c] = area["id"]
    colors = area_colors([a["id"] for a in docs["areas"]], area_of, counties)
    name = names(areas)
    boxes = service_boxes()
    # Each area: its counties' outline, cut to the service area's boxes, plus the boxes' edges where they cross its counties
    shapes = {}
    for area in docs["areas"]:
        rings = [r for geoid, _, rs in counties if area_of.get(geoid) == area["id"] for r in rs]
        count = defaultdict(int)
        for e in edges_of(rings):
            count[e] += 1
        own = [e for e, n in count.items() if n == 1]
        lines = [piece for a, b in own for piece in clip_to_boxes(a, b, boxes)]
        near = lambda seg: [e for e in own if min(e[0][0], e[1][0]) <= max(seg[0][0], seg[1][0]) and
                            max(e[0][0], e[1][0]) >= min(seg[0][0], seg[1][0]) and
                            min(e[0][1], e[1][1]) <= max(seg[0][1], seg[1][1]) and max(e[0][1], e[1][1]) >= min(seg[0][1], seg[1][1])]
        for seg in box_edges(boxes):
            for a, b in split_by(seg, near(seg)):
                if inside_rings(((a[0] + b[0]) / 2, (a[1] + b[1]) / 2), rings):
                    lines.append((a, b))
        shapes[area["id"]] = (rings, lines)
    # The view: the shaded parts, with a margin
    xs = [p[0] for _, lines in shapes.values() for e in lines for p in e]
    ys = [p[1] for _, lines in shapes.values() for e in lines for p in e]
    lon0, lon1, lat0, lat1 = min(xs), max(xs), min(ys), max(ys)
    kx = math.cos(math.radians((lat0 + lat1) / 2))
    pad = 0.07 * max((lon1 - lon0) * kx, lat1 - lat0)
    lon0, lon1, lat0, lat1 = lon0 - pad / kx, lon1 + pad / kx, lat0 - pad, lat1 + pad
    width = 1200.0
    scale = width / ((lon1 - lon0) * kx)
    height = round((lat1 - lat0) * scale)
    def xy(p):
        return ((p[0] - lon0) * kx * scale, (lat1 - p[1]) * scale)
    def visible(rings):
        return any(lon0 - 1 < p[0] < lon1 + 1 and lat0 - 1 < p[1] < lat1 + 1 for r in rings for p in r[::25])
    tol = 0.9
    def path(lines, closed):
        out = []
        for line in lines:
            pts = simplify_line([xy(p) for p in line], tol)
            if len(pts) < 2:
                continue
            out.append("M" + " ".join("%.1f %.1f" % p for p in pts) + ("Z" if closed else ""))
        return "".join(out)
    shown = [(geoid, state, rings) for geoid, state, rings in counties if visible(rings)]
    land = path([r for _, _, rings in shown for r in rings], True)
    # State lines: edges two counties of different states share; an area's outline: edges only one of its counties has
    owners = defaultdict(set)
    for geoid, state, rings in shown:
        for e in edges_of(rings):
            owners[e].add((geoid, state))
    borders = [e for e, o in owners.items() if len({s for _, s in o}) > 1]
    # An island's small outline pieces (under 9 px both ways) aren't drawn: on a ragged coast they ran together. Their fill stays
    def big_enough(line):
        pts = [xy(p) for p in line]
        xs, ys = [x for x, _ in pts], [y for _, y in pts]
        return max(xs) - min(xs) >= 9 or max(ys) - min(ys) >= 9
    parts = []
    for area in docs["areas"]:
        rings, lines = shapes[area["id"]]
        parts.append((area, path(rings, True), path([line for line in chain(lines) if big_enough(line)], False)))
    c = {"water": "#1f2d3a", "land": "#2b2b2d", "border": "#55555a", "state": "#8e8e93", "text": "#f2f2f7", "town": "#d1d1d6",
         "halo": "#1c1c1e", "credit": "#a1a1a6", "dot": "#f2f2f7"} if dark else \
        {"water": "#c6dcef", "land": "#f3f2ee", "border": "#c9c6be", "state": "#a3a09a", "text": "#1d1d1f", "town": "#3a3a3c",
         "halo": "#ffffff", "credit": "#6e6e73", "dot": "#1d1d1f"}
    font = "-apple-system, 'Helvetica Neue', Helvetica, Arial, sans-serif"
    svg = ['<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" width="%d" height="%d" font-family="%s">' % (
        width, height, width, height, font)]
    svg.append('<rect width="100%%" height="100%%" fill="%s"/>' % c["water"])
    svg.append('<path d="%s" fill="%s" stroke="%s" stroke-width="2" stroke-linejoin="round"/>' % (land, c["land"], c["land"]))
    svg.append('<clipPath id="service-area">%s</clipPath>' % "".join(
        '<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f"/>' % (
            xy((x0, y1)) + (xy((x1, y0))[0] - xy((x0, y1))[0], xy((x1, y0))[1] - xy((x0, y1))[1])) for x0, x1, y0, y1 in boxes))
    for area, fill, outline in parts:
        svg.append('<path d="%s" fill="%s" fill-opacity="%s" stroke="none" clip-path="url(#service-area)"/>' % (
            fill, colors[area["id"]], "0.28" if dark else "0.20"))
    svg.append('<path d="%s" fill="none" stroke="%s" stroke-width="1.2"/>' % (path(chain(borders), False), c["border"]))
    for area, fill, outline in parts:
        svg.append('<path d="%s" fill="none" stroke="%s" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/>' % (
            outline, shade(colors[area["id"]], dark)))
    def inside(x, y):
        return 0 <= x <= width and 0 <= y <= height
    for label, lat, lon in docs.get("states", []):
        x, y = xy((lon, lat))
        if inside(x, y):
            svg.append('<text x="%.0f" y="%.0f" font-size="17" font-weight="600" letter-spacing="3" fill="%s" '
                       'text-anchor="middle">%s</text>' % (x, y, c["state"], label))
    # Each place: [name, latitude, longitude] with its name right of the dot, or a fourth item "left" or "above" for a name
    # that would cover a nearby one there
    for area in docs["areas"]:
        for i, place in enumerate(area["places"]):
            label, lat, lon = place[:3]
            side = place[3] if len(place) > 3 else "right"
            x, y = xy((lon, lat))
            big = i == 0
            svg.append('<circle cx="%.1f" cy="%.1f" r="%s" fill="%s" stroke="%s" stroke-width="1.5"/>' % (
                x, y, "6" if big else "4.5", c["dot"], c["halo"]))
            if side == "above":
                tx, ty, anchor = x, y - (12 if big else 10), "middle"
            else:
                tx, ty = x + (11 if big else 9) * (1 if side == "right" else -1), y + (8 if big else 7)
                anchor = "start" if side == "right" else "end"
            svg.append('<text x="%.1f" y="%.1f" font-size="%d" font-weight="%d" fill="%s" text-anchor="%s" '
                       'stroke="%s" stroke-width="4" paint-order="stroke" stroke-linejoin="round">%s</text>' % (
                           tx, ty, 24 if big else 20, 700 if big else 500, c["text"] if big else c["town"], anchor, c["halo"], label))
    # Each area's name inside it, in the darker shade of its color with a halo, on two lines: the largest text on the map, so
    # the name tells the areas apart and the color only neighbors. Drawn after the towns, over them
    for area in docs["areas"]:
        lat, lon = area["label"]
        x, y = xy((lon, lat))
        lines = name_lines(name[area["id"]])
        for k, line in enumerate(lines):
            svg.append('<text x="%.1f" y="%.1f" font-size="26" font-weight="800" letter-spacing="0.3" fill="%s" text-anchor="middle" '
                       'stroke="%s" stroke-width="6" paint-order="stroke" stroke-linejoin="round">%s</text>' % (
                           x, y + (k - (len(lines) - 1) / 2) * 29 + 9, shade(colors[area["id"]], dark), c["halo"], line))
    # Where the lines come from. No legend: the names are on the map, and the lines are plain solid lines
    svg.append('<text x="%d" y="%d" font-size="16" fill="%s" text-anchor="end">County and state lines: US Census Bureau</text>' % (
        width - 24, height - 22, c["credit"]))
    svg.append("</svg>")
    return "\n".join(svg) + "\n"


def main():
    if len(sys.argv) not in (2, 3) or sys.argv[1] not in ("check", "write") or (sys.argv[1] == "check" and len(sys.argv) == 3):
        sys.exit(__doc__)
    areas, docs, sources = load()
    problems = check(areas, docs, sources)
    county_names = json.load(open(COUNTY_NAMES, encoding="utf-8"))
    every = [c for a in areas["areas"] for r in a["regions"] for c in r["counties"]]
    if sorted(county_names) != sorted(every):
        problems.append("tools/area-county-names.json doesn't list areas.json's counties: run tools/generate_areas.py make")
    if problems:
        sys.exit("area-docs.json doesn't match areas.json:\n- " + "\n- ".join(problems))
    if sys.argv[1] == "check":
        print("area-docs.json matches areas.json: %d metro areas" % len(docs["areas"]))
        return
    readme = open(README, encoding="utf-8").read()
    for tag, block in readme_blocks(areas, docs).items():
        readme = replace_block(readme, tag, block, README, inline=tag == "intro")
    open(README, "w", encoding="utf-8").write(readme)
    index = open(SOURCES, encoding="utf-8").read()
    open(SOURCES, "w", encoding="utf-8").write(replace_block(index, "areas", index_block(areas, docs), SOURCES))
    open(METRO_AREAS, "w", encoding="utf-8").write(metro_areas_page(areas, docs))
    os.makedirs(PAGES, exist_ok=True)
    outlines = read_county_outlines()
    for area in docs["areas"]:
        page = area_page(area, areas, docs, sources, outlines, county_names)
        open(os.path.join(PAGES, area["slug"] + ".md"), "w", encoding="utf-8").write(page)
    if len(sys.argv) == 3:
        counties = [(geoid, state, rings) for geoid, state, rings in read_counties(sys.argv[2])]
        open(MAP, "w", encoding="utf-8").write(draw_map(areas, docs, counties))
    print("wrote README.md, docs/data-sources.md, docs/metro-areas.md and %d area pages%s" % (len(docs["areas"]), " and the map" if len(sys.argv) == 3 else
          " (not the map: no FOLDER)"))


if __name__ == "__main__":
    main()
