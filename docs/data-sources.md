# Data sources

All timetables and real-time data come from each operator's public feeds and are downloaded on your Mac. Nothing goes through a server run by this project.

<!-- generated:areas -->
The app covers six metro areas. Each has its own page with every operator that runs there (an operator in two areas is on both), the keys and accounts some of them need, and any stations without times:

- [New York Metropolitan Area](data-sources/new-york.md): New York City, Long Island, the Hudson Valley, northern and central New Jersey, southern Connecticut to New London and Mystic, and Pike County, PA
- [Philadelphia Metropolitan Area](data-sources/philadelphia.md): Philadelphia and its suburbs, Berks County, PA, South Jersey, northern Delaware and Cecil County, MD
- [Lehigh Valley](data-sources/lehigh-valley.md): Lehigh and Northampton Counties (Allentown, Bethlehem and Easton), Carbon County, Monroe County in the Poconos, and Warren County, NJ
- [Greater Boston](data-sources/greater-boston.md): Boston and its suburbs, the North Shore, the South Shore, Worcester County, Bristol County, Cape Cod, Martha's Vineyard and Nantucket in Massachusetts, Rhode Island, southern New Hampshire, and the edge of York County, Maine, from Berwick to Kittery
- [Greater Hartford](data-sources/greater-hartford.md): Hartford and its suburbs, from New Britain to Enfield and Storrs, the northeastern corner of Connecticut around Putnam and Danielson, and the Northwest Hills around Torrington and Winsted
- [Western Massachusetts](data-sources/western-massachusetts.md): The Pioneer Valley (Springfield, Holyoke, Westfield, Northampton, Amherst and Greenfield, in Hampden, Hampshire and Franklin Counties) and the Berkshires (Pittsfield, North Adams and Great Barrington)

[How the metro areas are drawn](metro-areas.md) says which counties each area has and why.

Some timetables come through Trillium, NJ Transit's website, 511NY, Arcadis, Passio, National RTAP or Modeshift, as noted on those pages.
<!-- /generated:areas -->

## Stations without times

Some operators don't publish their times in a form the app can use, so nothing is downloaded from them. The app lists their stations and piers without departures, with an **Open Website** button for the operator's own page; each metro area's page lists them. Their positions are written into the app's source code, and a newer source list can change them without a new version of the app (see [Rules the app follows](#rules-the-app-follows)). The positions come from:

- **BTS:** the ferry terminals in the National Transportation Atlas Database of the US Bureau of Transportation Statistics (public domain). Some of its points are an operator's address rather than the pier itself, so a pier can be off by a block or two.
- **US Census Bureau:** the street addresses on the operator's website, located with the Census Bureau's address search (public domain).
- **Port Authority:** the station positions in the Port Authority's AirTrain timetable data, once published through 511NY. Only the positions are used.

None of these positions come from OpenStreetMap, Apple Maps or Google Maps.

Private commuter buses aren't in the app at all: their times aren't published in a form it can use, so not even their stops are listed.

## All regions

- **Apple Maps:** walking routes and place search.
- **Water areas** (to tell when a straight-line walk crosses a river or a bay): [US Census Bureau TIGER/Line](https://www.census.gov/geographies/mapping-files/time-series/geo/tiger-line-file.html), AREAWATER (public domain), bundled with the app as `water.bin` and made by `tools/generate_water.py`.
- **County outlines** (to tell whether a place is in the service area, which metro area and which part of it, and for the service area map and its state lines): [US Census Bureau cartographic boundary files](https://www.census.gov/geographies/mapping-files/time-series/geo/cartographic-boundary.html), counties, 2023, 1:500,000 (public domain), bundled with the app as `area_counties.bin` and made by `tools/generate_areas.py`. The file also has the counties next to the metro areas, which the app counts as outside. Which counties make up each metro area is in `areas.json`, next to it, and [How the metro areas are drawn](metro-areas.md) says why; the area pages, the README's service area and the map are written from it by `tools/generate_area_docs.py`.

## Rules the app follows

- An operator with only a timetable is marked **Timetable** in the app and is never shown as live.
- Timetables and maps are checked once a month, and every day from a week before an operator's timetable runs out until a new one is out. New data replaces the old.
- Only the feeds that serve stations near you are downloaded. To keep downloads small, an area's timetables are downloaded only once your starting point, a favorite or a Plan a Trip place is in it; recent places don't count. An area you haven't used for 30 days is removed, and downloaded again when you need it (Settings → Downloaded data).
- New York Metropolitan Area: the subway station list, subway map and MTA bus stops are bundled with the app as a starting point (generated from MTA open data by the scripts in `tools/`). The app regenerates them from the latest MTA data each month.
- Where each operator's data is downloaded from, and the [stations without times](#stations-without-times), are written into the app's source code, and the same list is kept in `Packages/CatchCore/Sources/TransitCore/Resources/source-list.json`. The app downloads the newest copy of that file from this project's GitHub repository once a month, at most once a day while an operator's data can't be downloaded, and when you click **Check Timetables Now**, so a moved address or a station without times can change without a new version of the app. The list can only move an address within the server and first folder of the one built into the app, and a station's website only to a site the built-in list already links to; anything else needs a new version. A list that doesn't pass the app's checks is ignored; the app keeps using the last good one, or its built-in copy.

## Ownership

The data belongs to each operator and is used under its terms. It is not covered by this project's license. This app is not affiliated with or endorsed by any transit operator.

### Data files that come with the app

The files in `Packages/CatchCore/Sources/TransitCore/Resources/` and `tools/data/` are generated from MTA open data (MTA static GTFS and data.ny.gov) and belong to the MTA, except these:

| File | What it is | Where it comes from |
|---|---|---|
| `source-list.json` | The app's own list of download addresses and stations without times | Written for this app; the stations' positions as in [Stations without times](#stations-without-times) |
| `areas.json` | The app's own list of metro areas | Written for this app |
| `water.bin` | Water areas | The US Census Bureau's TIGER/Line files (public domain) |
| `area_counties.bin` | County outlines | The US Census Bureau's cartographic boundary files (public domain) |
