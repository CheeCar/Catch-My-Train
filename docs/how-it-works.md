# How it works

Catch My Train answers one question for every departure near you: *if I leave now, will I make it?*

## 1. Where you are

- **My current location:** the Mac's Location Services. The position is kept in memory only. The widget data holds rounded walking times, which a program on this Mac could use to estimate it to about a block (see [Security and privacy](../SECURITY.md#location)).
- **A place I choose:** an address, a recent place, a favorite, or a point picked on the map, in the place picker or on the transit map.
- **Commute presets:** each one switches your starting place and transit mode in one click. Make them in Settings → General.
- When your location can't be used (turned off, not allowed, or not found), the app walks from the place you chose last. If you have never chosen one, it shows no departures and asks you to choose a place.
- When macOS says your position may be off by more than about 300 m (1,000 ft), a line under the place's name says so. When it may be off by more than about 3 km (2 mi), the app doesn't use it: it shows no departures until the position gets better and asks you to choose a place, rather than walking from the place you chose last, which may be far away.

## 2. Nearby stations

A station is a candidate when it's within both the primary walk time and the **search radius** (4,000 ft in a straight line by default), or within the extended walk time. For the extended range, the radius grows to how far you walk in the extended walk time, if that's farther. Stations that are connected inside (for example the Times Sq complex) are shown as one station. Where a train, ferry or regional bus timetable marks a stop as drop-off only, it isn't shown there as a departure.

## 3. Walk time

```
walk time = Apple Maps walking route length ÷ walking speed
```

- Walking speed is 4.5 km/h (2.8 mph) by default and can be changed in Settings.
- If Apple Maps can't return a route (for example, offline), the app uses
  `straight-line distance × 1.25 ÷ walking speed` and marks the walk **estimated**.
- **Directions**, beside the walk on a station's page and in a departure's details, opens the walking route to that station in Apple Maps, or in Google Maps if you choose it in Settings → Privacy.
- When the straight line crosses a river, a bay or the sea (water areas bundled with the app), an estimate can be far too short. While online, such a station is left out until its Apple Maps route arrives. Without a route it is listed, but its verdict is at most **Not sure** (it can still be **Too soon**), with the note "Across the water: the real walk may be much longer." A walk to a ferry pier on the same shore doesn't count as crossing.

## 4. Primary and extended range

- **Primary range:** stations up to 15 minutes' walk (default).
- **Extended range:** 15 to 20 minutes' walk (default). These stations are always shown when they are in range, after the primary-range stations, with an "Extended range" tag.
- **Extend Range for Now** adds +5, +10, +15 or +20 minutes until standby or quit. Your settings don't change.

## 5. Can I catch it?

```
time at platform = now + walk to the entrance + entrance to platform
slack            = train's time − time at platform
needed slack     = safety buffer + uncertainty
```

- **Train's time:** the one time the app shows for that train. Depending on the data, it is when the train leaves the stop or when it gets there (NYC Subway: when it gets there).
- **Entrance to platform:** about 1.5 minutes for the subway, PATH, light rail and trolley lines; 2 minutes for trains; 1 minute for ferries, the Roosevelt Island Tram and buses other than the MTA's (30 minutes for the Statue of Liberty Ferry, for tickets and security screening); none at MTA bus stops. A departure's details call it "Station entrance to platform", "Time to board" (ferries and buses) or "Ticket and security check" (Statue of Liberty Ferry).
- **Safety buffer:** 2 minutes by default.
- **Uncertainty:** +15% of the walk time when the walk is estimated, and +60 seconds when only a schedule is available. An estimated walk across water is at most **Not sure**.

| Result | Verdict |
|---|---|
| slack ≥ needed slack | **Can try** |
| 0 ≤ slack < needed slack | **Tight** |
| slack < 0 | **Too soon** (take the next one) |
| no prediction, or real-time data older than the expiry time | **Not sure** |

The expiry time is **Real-time data expires after** in Settings → Running: 180 seconds by default, and at least the refresh interval plus 1 minute.

Each verdict has its own shape icon as well as its own color, so it can be read without relying on color. How It Works in the app starts with a legend of these icons and colors, the bar on the first one you can catch, the two walking ranges and the Timetable tag.

Times are the local time of the metro area you leave from: the area you're in when you use your location, the area of the place you chose, and in Plan a Trip the area of your starting place. Every metro area the app covers so far is on Eastern Time. The current time on the board and in the menu bar panel also shows the time zone, written the way your language writes it, for example "EDT" in English or "GMT-4" in German.

When your Mac's clock is set to a time zone that shows a different time, every time of day also shows its zone, and the board, Plan a Trip and the menu bar panel get a line at the top saying whose local time it is. The minutes until a departure stay the same. The widget then shows no times and asks you to open the app.

Outside the service area there are no departures, and the current time follows your Mac's time zone. When you use your location there and the time where you are differs from your Mac's, the current time follows where you are and a line says so. Dates in Settings follow your Mac's time zone, except those about one metro area's downloaded data, which follow that area's time.

## 6. Sorting

- **Stations:** primary-range stations first, then extended-range stations, each group ordered by walk time.
- **Departures:** in each direction, listed by time; departures without a prediction come last.
- **Next catchable:** when a departure is Too soon or Not sure, the app points out the next one you can catch (*Can try* or *Tight*) on the same route.
- **Widget:** Too-soon departures are skipped at the top of the widget.

## 7. Express or local

For the MTA subway, the stops a train will make (from real-time data) are compared with the MTA schedule. If it skips stops that other trains on that line make, it is shown as **Express**; otherwise **Local**. Buses use the MTA's own categories: Local, Limited, Select Bus Service (SBS) and Express.

## 8. Refreshing

- **Start / Standby:** while started, the app refreshes every 30 seconds by default (30 s, 1, 2 or 5 min). On standby it doesn't download anything or use your location on its own; maps and address searches you open yourself still use Apple Maps. The sidebar then shows "Current location" and maps show a plain pin instead of your position. It goes back to standby after 30 minutes by default.
- Only the feeds that serve nearby stations are downloaded. To keep downloads small, an area's timetables are downloaded only once your starting point, a favorite or a Plan a Trip place is in it; recent places don't count. An area you haven't used for 30 days is removed, and downloaded again when you need it (Settings → Data source → Downloaded data, where you can also remove one yourself). Until an area is downloaded, it doesn't count toward **Timetables up to date as of …**.
- Live data that needs your own key or account is asked for at most once a minute, whatever the refresh setting, so it doesn't get limited; the rest refreshes as often as set. MTA Bus Time is also limited to 4 requests at a time and the nearest 24 stops, and pauses on its own if the server rate-limits.
- With an NJ Transit account, a bus departure is shown as live when NJ Transit has a prediction for it, matched by stop and time; the others keep their timetable times. NJ Transit often gives no prediction at a line's first stop, so departures from there are mostly timetable times, and a canceled bus can't be matched, so it keeps its timetable time.
- If one feed fails, the others still update. Its notice appears only in the mode and at the stations that feed serves (for NJ Transit rail: Train mode), says which source failed, and whether the cause is your network or the operator's server. The status rows in Settings list only the current mode's sources.
- The app compares this Mac's clock with the time that several transit data servers and GitHub send. When at least two of them agree, times go by theirs, up to 12 hours off; the MTA's alone counts up to 15 minutes off. From 2 minutes off, the main window (above the departures) and Settings say so and how to set the clock. A date so wrong that secure connections fail, and a network that sends a sign-in page instead of the data, each get one notice instead of one per operator.
- When a station has nothing to show yet, the board says why, for example "Downloading subway and light rail data…". "Network is off in Settings…" appears only when data is actually missing, and a missing timetable is shown as a red line at the bottom of the window and in the menu bar.
- Timetables and maps are checked once a month and replaced when there is new data. From a week before an operator's timetable runs out, it is also checked every day until a new one is out. Each operator is checked on its own: if one fails, only that one is tried again, first after 10 minutes, then after longer waits, up to once a day.
- Before new data takes the place of the data in use, the app compares the two: the stops and lines that came, went or were renamed. If an operator's new data looks far from the old (most stops gone, no stops at all, or the number of stops jumping), that operator keeps the data it had and the app downloads it again the next day; the other operators are updated as usual. The same data coming for a week is taken after all, unless the live departures the app already downloads for the stations near you showed a vehicle, within the last three days, at a stop or on a line the new data leaves out (data with no stops is never taken). Nothing more is downloaded for this. Settings → Data source says when this happens, and what the latest update changed. If the data in use has stations or lines this version of the app doesn't know yet (for example a new PATH station, or a train line the app has no short name for), it's used all the same: only that part shows less, and Settings → Data source says a newer version of the app may know them.
- Once a month the app also downloads a short **source list** from this project's GitHub repository: where to download each operator's data, and the stations without times. An address that moves on the operator's same server can then be fixed without an app update (the list can't send the app to another server). The list is also checked at most once a day while an operator's data can't be downloaded because of a problem on the operator's side, and first when you click **Check Timetables Now** in Settings. It is downloaded only while the app is started, network use is allowed and Demo mode is off, never by the widget, and nothing about you is sent. A list that doesn't pass the app's checks is ignored; the app keeps the last good one, or the copy built into it.
- If a problem on the operator's side lasts 14 days, the station notice and that operator's row in Settings say since when ("Not working since …") and offer **Check for Updates…**, in case a newer version of the app fixes it.
- If an operator's new data hasn't been used for 14 days, its stations say so too, with **Settings…**, which opens Settings → Data source.
- **Timetables up to date as of …** at the bottom of the main window is the oldest of the last successful downloads of the selected station's operators, so it stops moving when one of them falls behind. Settings shows the whole mode's date with the next monthly check. At an MTA subway station, the main window also counts the MTA subway data and Settings doesn't, so the main window's date can be earlier.

## 9. Widget and menu bar

- The app keeps running in the menu bar after you close the window.
- While the app is running, it does all the downloading and shares the results with the widget through a folder on your Mac. It also tells the widget when something it shows has changed.
- When the app is closed, the widget updates by itself only for NYC Subway and Staten Island Railway stations and the Roosevelt Island Tram (macOS decides how often, roughly every 5 minutes). These updates use the download addresses built into the app, because only the app downloads the source list. For every other station or stop, it keeps showing the last data; once that data is no longer fresh or every listed departure has passed, its status line turns orange and asks you to open Catch My Train. The ⟳ button refreshes it right away.
- The widget shows when the data was last updated and marks it **Stale** after 10 minutes. While the app is running and its own data is out of date (for example, when downloads keep failing), the widget follows **Real-time data expires after** in Settings → Running instead, like the main window.
- While a feed is rate-limited, the widget keeps showing "Updated …". A notice about a passing connection problem is dropped about 15 minutes after the app quits, and an empty widget then says "Open Catch My Train and refresh once."

## 10. Leave-by reminders

- Click a departure you can try for: its details say when you have to leave at the latest (**Leave by …**), and **Remind Me at …** sets a notification a few minutes before that (2 by default; Settings → Reminders, 1 to 30). Up to 10 can be set.
- The notification moves when the train's time changes, and says so when the train is now tight, too soon to catch, cancelled or no longer listed.
- A bell with the number of reminders set appears in the main window's toolbar and at the top of the menu bar panel; click it to see them, cancel one, or cancel them all.
- While a reminder is still to come, automatic standby waits until its latest time to leave.
- Notifications are made on this Mac and nothing is sent anywhere. macOS asks whether the app may send them the first time you set one.
