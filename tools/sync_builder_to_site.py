#!/usr/bin/env python3
"""Regenerate the beta site's MQTT builder from the canonical copy in Documents/.

The site copy is a branded fork: same markup and JS, different palette, plus a
top nav, a beta banner, a mobile page picker and one extra sleep-sound field.
Hand-patching it drifted badly (at one point 78 elements existed only in the
canonical copy, and the site's `updateAll()` called a function that had never
been ported, throwing on every keystroke). So instead of patching, this script
rebuilds the site copy from source and re-applies the site-only pieces, which it
lifts out of the current site file rather than hard-coding.

    python3 tools/sync_builder_to_site.py [--check]

--check reports whether the site copy is already up to date without writing.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(HERE, "Documents", "mqtt-builder.html")
DST = os.path.abspath(os.path.join(HERE, "..", "Allarise-info-beta", "mqtt-builder.html"))


def between(s, a, b, inclusive=True):
    i = s.index(a)
    j = s.index(b, i) + (len(b) if inclusive else 0)
    return s[i:j]


def top_level_rules(style):
    """Yield (selector, full rule text) for each brace-balanced top-level rule."""
    i, n = 0, len(style)
    while i < n:
        brace = style.find("{", i)
        if brace == -1:
            return
        # Comments sit in the gap between rules, so they land in the selector
        # text. Strip them, or a rule reads as new on the next run purely
        # because this script's own "Added upstream" banner is now in front of
        # it, and it gets appended again on every sync.
        selector = re.sub(r"/\*.*?\*/", " ", style[i:brace], flags=re.S)
        selector = " ".join(selector.split())
        depth, j = 0, brace
        while j < n:
            if style[j] == "{":
                depth += 1
            elif style[j] == "}":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        yield selector, style[i:j + 1].strip()
        i = j + 1


def merge_styles(site_style, src_style):
    """Site styling wins; rules only the canonical copy has are appended.

    Selector-level, not property-level: a rule the site already defines is left
    alone even if upstream changed it, because that is usually the branding
    diverging on purpose (palette, font sizes). A brand-new selector, though, is
    a feature that would otherwise render unstyled.
    """
    # Both blocks arrive wrapped in their <style> tags; append inside them.
    open_tag, close_tag = "<style>", "</style>"
    site_body = site_style[len(open_tag):-len(close_tag)]
    src_body = src_style[len(open_tag):-len(close_tag)]

    seen = {sel for sel, _ in top_level_rules(site_body)}
    extra = [rule for sel, rule in top_level_rules(src_body)
             if sel not in seen and not sel.startswith(("@", ":root"))]
    if not extra:
        return site_style
    return (open_tag + site_body.rstrip()
            + "\n\n  /* Added upstream — see Documents/mqtt-builder.html */\n  "
            + "\n  ".join(extra) + "\n" + close_tag)


def build(src, site):
    # The site-only pieces, lifted from whatever the site currently has so its
    # branding can evolve without editing this script.
    style = between(site, "<style>", "</style>")
    favicon = between(site, '<link rel="icon"', "<title>", inclusive=False)
    banner = between(site, "<!-- BETA SITE BANNER", '<div class="app">', inclusive=False)
    mobile = between(site, "<!-- Mobile nav (replaces sidebar", "</select>\n</div>\n")
    hamburger = between(site, "// ─── Hamburger nav ───",
                        "document.getElementById('nav-dropdown').style.display = 'none';\n")
    sysvol = between(site,
                     '            <div class="field-group">\n              <label>System Volume (0–100)',
                     "Independent of the sleep sound volume above.</div>\n            </div>\n")

    out = src.replace("HaWake", "Allarise").replace("hawake", "allarise")
    out = out.replace("<title>Allarise MQTT Payload Builder</title>",
                      "<title>[BETA] Allarise MQTT Payload Builder</title>")
    out = out.replace("<title>[BETA]", favicon + "<title>[BETA]", 1)

    # The site's stylesheet carries the branding, so it replaces the canonical
    # one wholesale — but anything newly added upstream would then vanish, so
    # rules the site has never seen are appended after it.
    out = out.replace(between(out, "<style>", "</style>"), merge_styles(style, between(src, "<style>", "</style>")), 1)

    out = out.replace('<body>\n<div class="app">', "<body>\n" + banner + '<div class="app">', 1)
    out = out.replace('<!-- Main -->\n<div class="main">\n<div class="content">',
                      '<!-- Main -->\n<div class="main">\n\n' + mobile + '\n<div class="content">', 1)
    out = out.replace("<script>\n", "<script>\n" + hamburger + "\n", 1)

    # showPage gains the mobile picker sync; the picker calls back in.
    out = out.replace(
        """  document.getElementById('page-' + id).classList.add('active');
  btn.classList.add('active');
  document.getElementById('cfg-topic-display').textContent = topic(pageToCmd(id));
}""",
        """  document.getElementById('page-' + id).classList.add('active');
  if (btn) btn.classList.add('active');
  document.getElementById('cfg-topic-display').textContent = topic(pageToCmd(id));
  const sel = document.getElementById('mobile-page-select');
  if (sel) sel.value = id;
}

function showPageFromSelect(sel) {
  const id = sel.value;
  const btn = document.querySelector(`.nav-item[onclick*="'${id}'"]`);
  showPage(id, btn);
}""", 1)

    anchor = """            <div class="field-group">
              <label>Volume (0–100)</label>
              <input type="number" id="ss-volume" min="0" max="100" placeholder="50" oninput="updateSleepSoundStart()">
              <div class="field-hint">Accepts 0–100 integers or 0.0–1.0 floats.</div>
            </div>
"""
    out = out.replace(anchor, anchor + "\n" + sysvol, 1)
    emit = "  const vol = vInt('ss-volume'); if (vol !== null) p.volume = vol;"
    out = out.replace(emit, emit +
                      "\n  const sysVol = vInt('ss-system-volume'); if (sysVol !== null) p.system_volume = sysVol;", 1)

    if '<option value="radio">' not in out:
        out = out.replace('      <option value="sleep-sounds">Sleep Sounds</option>\n',
                          '      <option value="sleep-sounds">Sleep Sounds</option>\n'
                          '      <option value="radio">Radio</option>\n', 1)
    return out


def verify(src, out):
    """Every id the canonical copy has must survive, and no JS may reference an
    id that does not exist — the exact failure that broke the site before."""
    if out.count("<style>") != 1 or out.count("</style>") != 1:
        sys.exit("rebuilt site copy has a malformed <style> block")
    if out.index("</style>") > out.index("</head>"):
        sys.exit("rebuilt site copy leaks CSS past </head>")

    src_ids = set(re.findall(r'id="([a-z0-9\-]+)"', src))
    out_ids = set(re.findall(r'id="([^"]+)"', out))
    missing = sorted(src_ids - out_ids)
    if missing:
        sys.exit("lost ids in the rebuilt site copy: " + ", ".join(missing))

    js = re.search(r"<script[^>]*>([\s\S]*?)</script>", out).group(1)
    refs = set()
    for pat in (r"getElementById\('([^']+)'\)", r"\bv\('([^']+)'\)",
                r"\bvInt\('([^']+)'\)", r"\bc\('([^']+)'\)"):
        refs |= set(re.findall(pat, js))
    dangling = sorted(r for r in refs if r not in out_ids)
    if dangling:
        sys.exit("rebuilt site copy references missing ids: " + ", ".join(dangling))


def main():
    src, site = open(SRC).read(), open(DST).read()
    out = build(src, site)
    verify(src, out)

    if "--check" in sys.argv:
        print("up to date" if out == site else "OUT OF DATE — rerun without --check")
        sys.exit(0 if out == site else 1)

    if out == site:
        print("already up to date")
        return
    open(DST, "w").write(out)
    print("wrote", DST)


if __name__ == "__main__":
    main()
