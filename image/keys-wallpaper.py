#!/usr/bin/env python3
"""Draw the desktop wallpaper: a key-binding cheatsheet on black.

Runs at image build, after /etc/scroll/config and config.d are final. Every key
on the sheet must be bound at the top level of that config (not inside a mode),
or the build fails, so the sheet can't drift from the real bindings.

  python3 -I keys-wallpaper.py <config> <out.png>

Writes an SVG and renders it with ImageMagick (librsvg delegate), both in the image.
"""
import glob
import html
import os
import re
import subprocess
import sys
import tempfile

# (section, [(label, description, [bindsym combos that must exist])])
SHEET = [
    ("Basics", [
        ("Super T", "terminal", ["$mod+t"]),
        ("Super D", "launcher", ["$mod+d"]),
        ("Super Q", "close window", ["$mod+q"]),
        ("Super Alt L", "lock (key PIN + touch, then password)", ["$mod+Alt+l"]),
        ("Super Shift E", "log out (asks first)", ["$mod+Shift+e"]),
        ("Super Shift C", "reload config", ["$mod+Shift+c"]),
        ("Print", "screenshot to ~/Pictures/Screenshots", ["Print"]),
    ]),
    ("Focus and move", [
        ("Super ← → / H L", "focus column", ["$mod+Left", "$mod+Right", "$mod+h", "$mod+l"]),
        ("Super ↑ ↓ / K J", "focus window in column", ["$mod+Up", "$mod+Down", "$mod+k", "$mod+j"]),
        ("Super Ctrl + those", "move column / window",
         ["$mod+Ctrl+Left", "$mod+Ctrl+Right", "$mod+Ctrl+Up", "$mod+Ctrl+Down",
          "$mod+Ctrl+h", "$mod+Ctrl+l", "$mod+Ctrl+k", "$mod+Ctrl+j"]),
        ("Super Home / End", "first / last column", ["$mod+Home", "$mod+End"]),
        ("Super [ / ]", "window into or out of column", ["$mod+bracketleft", "$mod+bracketright"]),
        ("Super Shift ←↑↓→", "focus monitor", ["$mod+Shift+Left", "$mod+Shift+Down",
                                              "$mod+Shift+Up", "$mod+Shift+Right"]),
        ("Super Shift Ctrl ←→", "move column to monitor",
         ["$mod+Shift+Ctrl+Left", "$mod+Shift+Ctrl+Right"]),
    ]),
    ("Workspaces", [
        ("Super U / I", "workspace down / up", ["$mod+u", "$mod+i", "$mod+Page_Down", "$mod+Page_Up"]),
        ("Super Ctrl U / I", "move column down / up", ["$mod+Ctrl+u", "$mod+Ctrl+i"]),
        ("Super 1…9", "go to workspace", ["$mod+1", "$mod+9"]),
        ("Super Ctrl 1…9", "move column there", ["$mod+Ctrl+1", "$mod+Ctrl+9"]),
        ("Super Tab", "previous workspace", ["$mod+Tab"]),
        ("Super O", "overview", ["$mod+o"]),
    ]),
    ("Size", [
        ("Super R", "width: 1/3, 1/2, 2/3", ["$mod+r"]),
        ("Super Shift R", "height presets", ["$mod+Shift+r"]),
        ("Super − / =", "width −10% / +10%", ["$mod+minus", "$mod+equal"]),
        ("Super Shift − / =", "height −10% / +10%", ["$mod+Shift+minus", "$mod+Shift+equal"]),
        ("Super F", "maximize column", ["$mod+f"]),
        ("Super Shift F", "fullscreen", ["$mod+Shift+f"]),
        ("Super C", "center column", ["$mod+c"]),
    ]),
    ("Floating", [
        ("Super V", "float toggle", ["$mod+v"]),
        ("Super Shift V", "focus floating ↔ tiling", ["$mod+Shift+v"]),
        ("Super drag", "move window (right drag: resize)", []),
    ]),
    ("Extras", [
        ("Super /", "jump: type a window's label", ["$mod+slash"]),
        ("Super Shift Z", "send to scratchpad", ["$mod+Shift+z"]),
        ("Super Z", "show / cycle scratchpad", ["$mod+z"]),
        ("Super N", "VMs: networks and USB (vmtui)", ["$mod+n"]),
    ]),
]

W, H = 1920, 1080
FG, DIM, ACCENT, KEY = "#d8dee9", "#7b8494", "#7fc8ff", "#e5e9f0"
MOD_ORDER = ("shift", "ctrl", "control", "alt", "mod1", "mod4", "super")


def die(msg):
    sys.exit(f"keys-wallpaper: {msg}")


def read_config(path):
    """Top-level bindsym combos and `set` variables, following config.d includes."""
    variables, binds, depth = {}, set(), 0
    files = [path]
    while files:
        f = files.pop(0)
        with open(f) as fh:
            for raw in fh:
                line = raw.strip()
                if not line or line.startswith("#"):
                    continue
                if depth == 0:
                    m = re.match(r"set\s+(\$\w+)\s+(.*)", line)
                    if m:
                        variables[m.group(1)] = m.group(2)
                    m = re.match(r"include\s+(\S+)", line)
                    if m:
                        files += sorted(glob.glob(m.group(1)))
                    m = re.match(r"bindsym\s+((?:--[\w-]+\s+)*)(\S+)", line)
                    if m:
                        binds.add(norm(m.group(2), variables))
                depth += line.count("{") - line.count("}")
    return variables, binds


def norm(combo, variables):
    for k in sorted(variables, key=len, reverse=True):
        combo = combo.replace(k, variables[k])
    parts = [p.lower() for p in combo.split("+")]
    mods = sorted(p for p in parts[:-1] if p in MOD_ORDER)
    return "+".join(mods + [parts[-1]])


def svg(sections):
    cols, colw, top = 3, 620, 150
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}">',
           f'<rect width="{W}" height="{H}" fill="#000"/>',
           f'<text x="{W // 2}" y="90" fill="{DIM}" font-family="Adwaita Sans" '
           f'font-size="22" text-anchor="middle" letter-spacing="6">SCROLL · KEYS</text>']
    # Two sections per column, in SHEET order; the second row starts level.
    row2 = top + 60 + 38 * max(len(rows) for _, rows in sections[0::2]) + 40
    for i, (title, rows) in enumerate(sections):
        x = (W - cols * colw) // 2 + (i // 2) * colw + 20
        y = top if i % 2 == 0 else row2
        out.append(f'<text x="{x}" y="{y}" fill="{ACCENT}" font-family="Adwaita Sans" '
                   f'font-size="20" font-weight="bold">{html.escape(title)}</text>')
        for j, (label, desc, _) in enumerate(rows):
            ry = y + 42 + 38 * j
            out.append(f'<text x="{x}" y="{ry}" fill="{KEY}" font-family="Adwaita Mono" '
                       f'font-size="18">{html.escape(label)}</text>')
            out.append(f'<text x="{x + 250}" y="{ry}" fill="{FG}" font-family="Adwaita Sans" '
                       f'font-size="18">{html.escape(desc)}</text>')
    out.append("</svg>")
    return "\n".join(out)


def main():
    if len(sys.argv) != 3:
        die("usage: keys-wallpaper.py <config> <out.png>")
    config, png = sys.argv[1:]
    variables, binds = read_config(config)
    missing = [c for _, rows in SHEET for _, _, combos in rows for c in combos
               if norm(c, variables) not in binds]
    if missing:
        die(f"on the sheet but not bound in {config}: {', '.join(missing)}")
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "keys.svg")
        with open(src, "w") as f:
            f.write(svg(SHEET))
        subprocess.run(["magick", "-background", "black", src, png], check=True,
                       env={**os.environ, "MAGICK_TEMPORARY_PATH": tmp})
    print(f"keys-wallpaper: {png} ({sum(len(r) for _, r in SHEET)} entries)")


if __name__ == "__main__":
    main()
