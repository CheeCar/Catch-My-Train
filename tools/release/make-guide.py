#!/usr/bin/env python3
"""Builds the DMG's two guide folders from tools/release/translations/dmg-guide.json.

    tools/release/make-guide.py <stage folder>

Writes two folders into the stage folder and prints their paths, one per line: the install guide first, then the
notes for people who use the desktop widget. Each is "<name>.localized/", where <name> is the English folder name:
  - .localized/<locale>.strings: Finder shows the item's name in the Mac's language, one short line
    ("How to Install and Open", "About the Widget"; macOS's own folder-name localization, English where no
    translation matches). Finder can't be told where to break a name (a line break in it shows as "?"), and a name
    longer than its two lines is cut in the middle, so the steps themselves are only in the pages;
  - one page ("How to Install and Open.html", "About the Widget.html"). It opens in the browser and picks the Mac's
    language from navigator.languages, falling back to English.
The install page names the widget folder the way Finder shows it: its sentence has {widgetFolder} where the name goes.
make-dmg.sh copies LICENSE.txt into the install guide and gives each folder its icon.
"""
import html
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RIGHT_TO_LEFT = {"ar", "he", "ur", "yi"}
INSTALL_PAGE = "How to Install and Open.html"
WIDGET_PAGE = "About the Widget.html"
# Finder looks for these file names in .localized; several spellings per language cover old and new locale ids
FINDER_LOCALES = {
    "en": ["en", "English"], "es": ["es", "es_419", "es_ES", "es_MX"], "fr": ["fr", "fr_CA"], "de": ["de"],
    "pt": ["pt", "pt_BR", "pt_PT"], "ru": ["ru"], "zh-Hans": ["zh_CN", "zh-Hans", "zh_Hans"],
    "zh-Hant": ["zh_TW", "zh_HK", "zh-Hant", "zh_Hant"], "ja": ["ja", "Japanese"], "ko": ["ko"], "uk": ["uk"],
    "ar": ["ar"], "he": ["he"], "hi": ["hi"], "ur": ["ur"], "it": ["it"], "pl": ["pl"], "vi": ["vi"], "bn": ["bn"], "ht": ["ht"],
    "yi": ["yi"], "gu": ["gu"], "tl": ["tl", "fil"],
}


def strings_line(key, value):
    escape = lambda s: s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
    return f'"{escape(key)}" = "{escape(value)}";\n'


def ordered(items):
    return "<ol>" + "".join(f"<li>{html.escape(item)}</li>" for item in items) + "</ol>"


def note(text):
    return f"<p class=note>{html.escape(text)}</p>"


def install_body(t):
    widget = t["widget"].replace("{widgetFolder}", t["widgetFolder"])
    return "".join([f"<h1>{html.escape(t['title'])}</h1>",
                    ordered([t["step1"], t["step2"]]),
                    f"<h2>{html.escape(t['blockedTitle'])}</h2>",
                    ordered([t["blocked1"], t["blocked2"], t["blocked3"]]),
                    note(t["eachVersion"]), note(t["requirements"]), note(widget), note(t["license"])])


def widget_body(t):
    return "".join([f"<h1>{html.escape(t['widgetTitle'])}</h1>",
                    f"<p>{html.escape(t['widgetIntro'])}</p>",
                    f"<h2>{html.escape(t['updateTitle'])}</h2>",
                    ordered([t["update1"], t["update2"], t["update3"]]),
                    note(t["updateNote"]),
                    f"<h2>{html.escape(t['addTitle'])}</h2>",
                    ordered([t["add1"], t["add2"], t["add3"]])])


def page(texts, title_field, body):
    bodies = {lang: body(t) for lang, t in texts.items()}
    script = """
const bodies = %s;
const rtl = %s;
function pick() {
  for (const code of navigator.languages || [navigator.language || "en"]) {
    const parts = code.toLowerCase().split(/[-_]/);
    if (parts[0] === "zh") {
      // Same rule as AppLanguage.matching: the script decides when there is one, only a code without one goes by region
      const rest = parts.slice(1);
      if (rest.includes("hans")) return "zh-Hans";
      if (rest.includes("hant")) return "zh-Hant";
      return rest.some(p => ["tw", "hk", "mo"].includes(p)) ? "zh-Hant" : "zh-Hans";
    }
    if (parts[0] === "fil") return "tl";
    if (bodies[parts[0]]) return parts[0];
  }
  return "en";
}
const lang = pick();
document.documentElement.lang = lang;
document.documentElement.dir = rtl.includes(lang) ? "rtl" : "ltr";
document.getElementById("guide").innerHTML = bodies[lang];
document.title = document.querySelector("h1").textContent;
""" % (json.dumps(bodies, ensure_ascii=False), json.dumps(sorted(RIGHT_TO_LEFT)))
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(texts["en"][title_field])}</title>
<style>
:root {{ color-scheme: light dark; --text: #1d1d1f; --muted: #6e6e73; --bg: #ffffff; --accent: #3a6ea5; }}
@media (prefers-color-scheme: dark) {{ :root {{ --text: #f5f5f7; --muted: #a1a1a6; --bg: #1c1c1e; --accent: #8ab4e8; }} }}
body {{ font: 16px/1.55 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; color: var(--text); background: var(--bg);
  max-width: 640px; margin: 40px auto; padding: 0 20px; }}
h1 {{ font-size: 26px; line-height: 1.25; }}
h2 {{ font-size: 19px; margin-top: 28px; color: var(--accent); }}
li {{ margin: 8px 0; }}
.note {{ color: var(--muted); font-size: 14px; }}
</style></head>
<body><main id="guide">{bodies["en"]}</main><script>{script}</script></body></html>
"""


def folder(stage, texts, name_field, page_name, title_field, body):
    """One guide folder: its name in every language for Finder, and its page."""
    name = texts["en"][name_field]
    path = os.path.join(stage, name + ".localized")
    os.makedirs(os.path.join(path, ".localized"), exist_ok=True)
    for lang, t in texts.items():
        for locale in FINDER_LOCALES[lang]:
            # UTF-16 with a byte order mark, the encoding Finder has always read for .localized
            with open(os.path.join(path, ".localized", locale + ".strings"), "w", encoding="utf-16") as f:
                f.write(strings_line(name, t[name_field]))
    with open(os.path.join(path, page_name), "w", encoding="utf-8") as f:
        f.write(page(texts, title_field, body))
    return path


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: make-guide.py <stage folder>")
    stage = sys.argv[1]
    with open(os.path.join(HERE, "translations", "dmg-guide.json"), encoding="utf-8") as f:
        texts = json.load(f)
    print(folder(stage, texts, "folder", INSTALL_PAGE, "title", install_body))
    print(folder(stage, texts, "widgetFolder", WIDGET_PAGE, "widgetTitle", widget_body))


if __name__ == "__main__":
    main()
