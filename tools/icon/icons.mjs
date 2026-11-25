// Icon sources. The app icon is a picture (the 1024 x 1024 master in the app's icon set, see README.md); the menu bar icon is
// drawn here as SVG, in this module rather than in an .svg file so that it stays plain text without any metadata added by the
// tools it passes through. render-menubar.mjs reads it.

// Menu bar icon (44 x 36, drawn at 22 x 18 pt): the app icon's train in one color. The front, a little wider at the bottom
// and arched on top, with the windshield cut out; in the windshield the sign bar and the two headlights; under it the stripe
// (cut out); then the two rails and one sleeper.
export const menuBarIcon = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 44 36" width="44" height="36">
  <!-- the front, with the windshield and the stripe cut out -->
  <path fill-rule="evenodd" fill="#000" d="M 16.65 1.7 Q 22 0.86 27.35 1.7 Q 31.55 2 31.85 6 L 33 23.3 Q 33 27.5 28.8 27.5 L 15.2 27.5 Q 11 27.5 11 23.3 L 12.15 6 Q 12.45 2 16.65 1.7 Z
    M 17.3 5 L 26.7 5 Q 28.7 5 28.8 7 L 29.8 17 Q 29.8 19 27.8 19 L 16.2 19 Q 14.2 19 14.2 17 L 15.2 7 Q 15.3 5 17.3 5 Z
    M 15.6 22 L 28.4 22 A 1 1 0 0 1 28.4 24 L 15.6 24 A 1 1 0 0 1 15.6 22 Z"/>
  <!-- in the windshield: the sign bar and the two headlights -->
  <path fill="#000" d="M 18.5 7 L 25.5 7 A 1.5 1.5 0 0 1 25.5 10 L 18.5 10 A 1.5 1.5 0 0 1 18.5 7 Z
    M 17.1 14 L 19.1 14 A 1.5 1.5 0 0 1 19.1 17 L 17.1 17 A 1.5 1.5 0 0 1 17.1 14 Z
    M 24.9 14 L 26.9 14 A 1.5 1.5 0 0 1 26.9 17 L 24.9 17 A 1.5 1.5 0 0 1 24.9 14 Z"/>
  <!-- two rails and a sleeper -->
  <g fill="#000">
    <path d="M 15.2 27.5 L 17.5 27.5 L 13.7 35 L 11.2 35 Z"/>
    <path d="M 26.5 27.5 L 28.8 27.5 L 32.8 35 L 30.3 35 Z"/>
    <path d="M 11.73 31 L 32.27 31 L 33.33 33 L 10.67 33 Z"/>
  </g>
</svg>`;
