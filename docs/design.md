# Design guidelines

The rules the app's screens follow, and why. They cover the app, the menu bar panel and the widget.

## Accessibility

### Never color alone

- Every verdict has its own icon shape, its own word and its own color: **Can try** (check mark, green), **Tight** (triangle, orange), **Too soon** (cross, red), **Not sure** (question mark, gray). In red–green color blindness, small red, green and orange text looks almost the same, so the icon and the word are what you read. Where there is no room for the word, as on a station's card in the sidebar, the icon stands alone and screen readers still say the word.
- Service tags (Express, Local, Limited), line badges and data states (Live, Timetable, Not checked yet) always carry text.
- The primary and extended walking ranges differ by shape too: ◎ and ◌ in the lists and on map labels, solid and dashed rings on the map.
- Favorites are gold stars, stations are round dots and the place you walk from is a pin, so they differ by shape, not only by color.
- Notices and errors have an icon and text.
- When macOS shows the widget without color, its tags switch to an outlined style.
- In the line filter, the lines you didn't choose turn gray instead of fading, so their letters keep their full contrast.

### Contrast

- The app's own colored text (verdicts, notices, metro area names) has a contrast ratio of at least 4.5:1 with its background, and its colored icons and map shapes at least 3:1 (WCAG 2). The system's green, orange, red, yellow and purple are too pale for that on white, so the light appearance uses darker ones; the dark appearance uses the system colors.
- Colors that appear together and must be told apart, such as the service tags, are compared in three color-blindness simulations (protanopia, deuteranopia and tritanopia), and must stay clearly different in all three.
- Automatic tests check the palette's contrast and color-blindness differences.
- With **Increase contrast** on in macOS, boxes, cards and tags get a clear border.

### Screen readers and keyboard

- Each departure is read as one sentence: the line, where it goes, the time, the minutes until it comes, the walk and the verdict. Directions are headings, so you can jump between them.
- Line badges are read by their names, not internal codes. Decorative icons are hidden from the screen reader.
- Things that show a state say it: the selected station, Start or Standby, and values with their units ("15 min"). The menu bar icon says whether the app is on or on standby.
- Each station in the sidebar is read with the departures you can catch. A subway station reads the first one in each direction, with the direction's name from the station's page; a direction with trains but none you can catch reads its first train with its verdict. Bus, train and ferry stations read the first departure you can catch in either direction.
- With VoiceOver, pressing the menu bar icon (VO-Space) shows the panel's content in a small window below the icon. Escape closes it; it can take two presses.
- Rows drawn by the app that you can click are also buttons for the screen reader.
- Select a departure and press Space to see its details. In search fields, ↑ and ↓ move through the suggestions and Return picks one; a screen reader says each suggestion as it lights up.
- Favorites can also be moved with the keyboard or VoiceOver: **Move Left** and **Move Right** in a favorite's right-click menu, among VoiceOver's actions, or ⌥⌘← and ⌥⌘→ while it's selected.

### Motion

- When **Reduce motion** is on in macOS, the app switches views without animation.
- Animations are short: 0.4 seconds or less.
- Selecting a station only changes the color of its card. A card lights up for a moment only when you come to it from the map, and not at all when Reduce motion is on.

### Text size and languages

- **Text size** in Settings makes the app's own text larger, in the menu bar panel too. The widget keeps a fixed text size.
- Languages written right to left use a fully mirrored layout. In them the maps' zoom buttons and compass sit in the bottom-left corner, above the Legal link.
- Every new screen is checked at the largest text size, in the longest translations and right to left.

### Known gaps

- A few of the newest parts haven't yet been listened to with VoiceOver on a Mac. The rest of the app has, window by window.
  - The reminders' bell, its list and the **Cancel all reminders?** alert, and moving to a reminder's row with Tab.
  - The station name you can click on a station card in Plan a Trip.
  - The **What Changed** list in Settings.
  - The badges of the bus companies added last, and a pier two ferry companies share, which is listed once for each.
- The lists that open from menus, the small arrows beside number fields and system alerts don't grow with **Text size**: macOS draws them.
- The title bar doesn't grow with **Text size**: macOS sets its height.

## Equality and respect

Everyone is treated the same and with respect, wherever they are. Accessibility, above, is part of this.

- The same situation gets the same message for everyone. When something can't be reached or found, the app says what it sees and what you can do.
- Each language is listed by its own name, and every language the app offers gets every text. The language list in Settings is in the alphabetical order of the languages' names in the language the app is in; in English, that is the order of the README's table. How the languages were chosen is in the README.
- Text speaks to you directly, in plain words that translate well.

## Color

- All colors come from one palette shared by the app and the widget, with a light and a dark value each.
- The accent color (blue by default; it follows your macOS setting) marks what is selected or current, a window's main button, links, a pin you dropped but haven't used yet, and on the map the stations within walking range. Ordinary buttons are gray, and the accent color is never decoration: the walking range on the map is teal, not blue, for that reason.
- Line badges use the operators' official line colors. On light colors (for example the G, N, Q, R and W lines) the text is black.
- The service area on the map is a purple dashed line.
- Each station in the sidebar is a card, a little lighter than the sidebar around it. The selected card is filled with the accent color, with white text. The verdict icons on it keep their own colors and get a white edge, because those colors alone have too little contrast with the accent color.

## Text

- In a departure, the train's time is the largest text, with the countdown right after it, then the walk time and the verdict.
- Lists have one item per line, and a wrapped line lines up with the text above it, not with the bullet.
- A number stays on the same line as its unit ("5 min").
- Times are the local time of the metro area you leave from, written the way your language and 12- or 24-hour setting write them. When your Mac's clock is set to a time zone that shows a different time, every time of day also shows its zone ("8:14 PM EST"), and a line says whose time it is.

## Notes and buttons

- A box that only explains something is neutral gray.
- A note that needs you to do something, such as add a key, comes with the button that does it.
- When a button can't be used, the reason is written next to it, not only in its mouse-over tip. The one exception is a grayed-out commute preset in the sidebar or the menu bar panel: there is no room beside it, so the reason is in its tip, and screen readers say it too.
- Mouse-over tips are short. Longer lists open in a box you click.
- Buttons side by side are the same width and height; when they don't fit, they stack.
- Dialogs, the title bar and the toolbar keep the standard macOS look.

## Windows

| Window | Smallest size |
|---|---|
| Main window | 960 × 560 |
| Map | 640 × 480 |
| Plan a Trip | 600 × 480 |

- Windows remember their position and size, and move back if their screen is unplugged.
- When a window gets narrow, content wraps or moves below instead of being cut off: for example, Plan a Trip's controls go to two or three rows, and its map hides below 860 points wide; in a narrow sidebar, at a larger text size or in a long translation, station, place and direction names wrap onto another line instead of being cut short, and the two Walk from choices go one above the other.
- Every list, menu and row is designed for the crowded case too: many items, long names and the longest translations.

## Region names

- Metro areas use their common English names, for example New York Metropolitan Area.
- Areas inside a metro area use their common names (Long Island, Hudson Valley, South Jersey). An area that is one county is written "County name County, state" (Pike County, PA).
