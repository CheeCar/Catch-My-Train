# Security and privacy

Catch My Train has no account, no server and no analytics. Everything runs on your Mac.

## Permissions

| Permission | Why |
|---|---|
| App Sandbox | The app and widget run sandboxed. |
| Outgoing network connections | To download transit data and walking routes (see below). |
| Location (only if you allow it) | To work out walking times from where you are. |
| Notifications (only if you allow it) | For leave-by reminders. They are made on this Mac and nothing is sent anywhere. |
| One folder in your Library (a sandbox exception) | So the app and the widget can share what the widget shows: `~/Library/Application Support/com.cheecar.CatchMyTrain/`. Both still run sandboxed. |

## Location

- Used only while the app is started and **Walk from** is set to **My current location**: to work out walking times and to show the name of the place you are at. Never on standby, in Demo mode, or when you walk from a place you chose.
- Sent only to Apple Maps: for walking routes, and to look up the name of the place you are at (shown in the sidebar, and as the area name when you are outside the service area). It is never sent to transit operators or anyone else, unless you choose Google Maps for **Directions** (Settings → Privacy): clicking **Directions** then opens Google Maps in your browser with your starting point and the station, so they are sent to Google.
- Your current location is kept in memory and is not saved.
- The widget data in the shared folder (`transit-snapshot.json`) holds the nearby stations (with the stations' own coordinates), the place name and walking data that is rounded on purpose: straight-line distance rounded up to 100 m and walk time rounded up to 30 seconds, with no route length, plus the order of those stations by walking time. The exact values stay only in the app's memory, except in a leave-by reminder you set (see [Data stored on your Mac](#data-stored-on-your-mac)). The file contains none of your coordinates, but a program on this Mac that reads it could still estimate where you are to about a block from those walking times and their order, and more closely where many stations are nearby. macOS doesn't keep other programs out of this folder: any program you run that isn't sandboxed can read it, though other sandboxed apps can't. This applies only when you walk from your current location; a place you choose is saved on this Mac anyway, and its name is in the file too, for the widget to show.
- You can use the app without location by choosing a place yourself.

## Places you choose

- The place you are walking from, your 10 most recent places, your favorites (up to 50) and your commute presets (up to 4) are saved on this Mac only. A preset that walks from a favorite keeps that favorite's name and coordinates.
- Places searched in **Plan a Trip** are kept in memory only and are not saved.
- Address and place search is done by Apple Maps.
- **Settings → Privacy → Clear Recent Places…** removes the recent places.

## Keys and accounts

- No key is needed for the subway, LIRR, Metro-North, PATH or ferries.
- Optional keys and accounts: MTA Bus Time key, NJ Transit developer account, Swiftly key (Suffolk County Transit).
- They are stored only in the Keychain on this Mac, readable after the Mac is unlocked. A build without an Apple developer signature, like the releases here, can't use the data protection keychain, so it uses your login keychain. If access is denied, the key isn't treated as missing: the app shows "Couldn't read the Keychain. Click to try again." They are never written to files, settings or logs, and are sent only to the operator they belong to.
- Keys, accounts and their tokens are sent only to the servers they are for and never follow a redirect to another server. When NJ Transit refuses a sign-in and says why, Settings shows its reply with the account, password and token fields hidden.
- No key, token or password is built into the source code.

## Network

The app connects only to:

- **Transit operators' public feeds** for each region (full list in [Data sources](docs/data-sources.md)). Requests do not include your location. Most feeds are downloaded whole; MTA Bus Time is asked about each nearby bus stop by its stop ID (the nearest 24 at most), so MTA can tell which stops you are near.
- **Apple Maps** for walking routes, place names and place search.
- **Google Maps**, only if you choose it for **Directions** in Settings → Privacy, and only when you click **Directions**: the app opens the route in your default browser, which sends your starting point and the station to Google. The app itself doesn't connect to Google.
- **GitHub** (`api.github.com`), for two things. Nothing personal is sent.
  - The app's **source list**: where each operator's data is downloaded from, and the stations without times. It is downloaded once a month, at most once a day while an operator's data can't be downloaded because of a problem on the operator's side, and when you click **Check Timetables Now**. Only while the app is started, network use is allowed and Demo mode is off; the widget never downloads it. The list can only move an operator's address within the server and first folder of the one built into the app, and a station's website only to a site the built-in list already links to; a list that tries anything else is ignored.
  - New releases: only if you turn on update checks (off by default, at most once a month), or when you check yourself with **Check Now** in Settings → About or **Check for Updates…**.

**Report an Issue…** in Settings → Data source, shown when an operator's new data wasn't used, opens GitHub's new-issue page in your browser with the app's and macOS's versions, the operator and the problem filled in. These are part of the page's address, so GitHub receives them as soon as the page opens, before you decide whether to submit the issue. No place, favorite, location, account or computer name is in it.

Each download has a size limit far above any real data of its kind (20 MB for live data, 300 MB for a timetable or map package); a server that sends more is stopped, and the data is treated as unreadable. A package is also checked as it is read: at most 1,000 files, no file over 1 MB expanding to more than 200 times its packed size, and each file's checksum must match. Live data in the GTFS-Realtime format may hold at most 50,000 entries (trips, vehicles or alerts), and a trip at most 1,000 stops. Data that fails a check is not used, and the data saved before stays.

On standby the app doesn't go online on its own: nothing is refreshed or downloaded, and your location isn't used. Only things you start yourself still use Apple Maps: opening a map, searching for an address, or picking a place on the map (the app then looks up the place's name). Plan a Trip uses only the timetables already saved and straight-line walking estimates. In **Settings → Privacy** you can turn off network use for Catch My Train only. The app and widget then use only data already saved.

## Data stored on your Mac

| What | Where |
|---|---|
| Settings, chosen place, recent places, favorites, commute presets | App's own settings |
| Data shared with the widget: what it shows (no favorites, recent places, keys or coordinates of yours), the selected station, Start or Standby, and the widget's status | The shared folder `~/Library/Application Support/com.cheecar.CatchMyTrain/`. Everything in it can be made again: the app writes it anew if it's deleted. |
| The six settings the widget needs (network use, refresh interval, data source, language, units and clock) | `app-settings.json` in the shared folder, and the widget's own settings |
| Downloaded timetables and maps | The app's sandbox folder (`~/Library/Containers/com.cheecar.CatchMyTrain/Data/Library/Application Support/CatchMyTrain/`) and the shared folder |
| A leave-by reminder you set: the station, line, direction, times and the exact walk and station entry time (needed to work the reminder out again after a restart) | macOS's pending notification; gone when it comes or is cancelled. The app saves nothing of it. |
| When the NJ Transit sign-in is next renewed (dates and counts only, never the username, password or token) | App's own settings |
| Whether each key or account worked the last time it was checked (worked, refused or couldn't tell; never the key, username or password) | App's own settings |
| When your NJ Transit account was last tried on NJ Transit's test system, and whether it worked there (a date and the result only) | App's own settings |
| When each operator's data was last downloaded, and since when it has failed (dates only) | App's own settings |
| Which metro areas you last used and when, and the ones you removed in Settings (area names and dates only, no places) | App's own settings |
| The downloaded source list | The same sandbox folder as the timetables (`source-list.json`) |
| A copy of a download several modes share, so it's downloaded only once (kept until each of them has read it, at most 6 hours) | The app's temporary folder |
| Keys and accounts | Keychain |

**Settings → Data source → Downloaded data → Delete Downloaded Data…** removes the downloaded timetables, maps and source list, the shared copies in the temporary folder, and the rate-limit records, the widget's status and the last saved departures in the shared folder, and clears each operator's download dates. **Remove…** next to a metro area removes only that area's data. Data is downloaded again when needed; until the source list is, the app uses the one built into it. An area you haven't used for 30 days is removed by itself.

## Logs

Errors are written to the macOS system log (filter by `com.cheecar.catchmytrain` in Console). Logs never include your location, keys, accounts or file paths. Only the app's own errors are logged with their full text; network errors are logged with just the error code and server name, and other system errors with just their domain and code. Besides these, two operators' replies are logged: NJ Transit's when it refuses an account and says why (with the account, password and token taken out, and cut to 200 characters), and MTA Bus Time's error messages, except when it refuses the key, which is logged without its reply. The log can also name the metro areas whose data is on this Mac, but not why they have data, and no places or favorites.

## Tracking

- Nothing is collected and there is no tracking or analytics.
- The app and the widget each include a privacy manifest (`PrivacyInfo.xcprivacy`) that declares no tracking and no collected data. The only declared system APIs are UserDefaults (the app's and the widget's own settings) and file timestamps.

## Cost

The app is free. All data feeds it uses are free. Some need a free key that you request yourself.

## Reporting a problem

If you find a security or privacy problem, please report it privately under **Security → Report a vulnerability** on GitHub (available once the repository is public), or open an issue without sensitive details.
