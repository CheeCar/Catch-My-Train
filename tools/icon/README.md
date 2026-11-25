# Icons

- The app icon is a picture. Its master is `App/Assets.xcassets/AppIcon.appiconset/icon_1024.png` (1024 × 1024; the rounded square takes the middle 824 × 824, the corners are transparent). On a dark blue background, a white train front seen from the front, a little wider at the bottom: one dark windshield with a teal sign bar at its top and a yellow headlight in each lower corner, a blue stripe and a small gray bar under it, standing on a track with sleepers that runs toward the viewer. The smaller sizes are made from the master by `render.mjs`.
- The menu bar icon is drawn as SVG in `icons.mjs` (`menuBarIcon`, 44 × 36, shown at 22 × 18 pt): the same train in one color, with the windshield and the stripe cut out, the sign bar and the two headlights in the windshield, on two rails with one sleeper. It is the same both when started and in standby. It is a template image, so macOS colors it for light and dark menu bars. The menu bar panel shows it in its top corner too.

The widget's subway symbol (SF Symbol "tram") stands for the transit mode, not the app, so it does not use these icons.

To put in a new app icon, save it as `icon_1024.png` in the icon set (a square 8-bit RGBA PNG, not interlaced). Then make the smaller sizes (needs only Node), draw the menu bar icon (needs Node and Playwright's bundled Chromium), and remove any metadata chunks:

    node tools/icon/render.mjs App/Assets.xcassets/AppIcon.appiconset 16 32 64 128 256 512
    node tools/icon/render-menubar.mjs App/Assets.xcassets
    tools/icon/strip-png-metadata.py App/Assets.xcassets/*/*.png

The app icon files are named `icon_<pixels>.png` and `AppIcon.appiconset/Contents.json` already maps them.
The menu bar files go to `MenuBarIcon.imageset`, whose `Contents.json` marks them as templates.
RepositoryHygieneTests fails if an image still carries embedded metadata.
