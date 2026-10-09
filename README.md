# Stage for Omarchy

A Stage Manager-style tiling layout for [Omarchy](https://omarchy.org/) on Hyprland.

The window you're working in sits alone in the middle of the screen. Every
other window on the workspace becomes a thumbnail in columns on the left and
right. A normal 16:9 or 16:10 screen gets one column per side. Wider screens
get more columns, each one further out a bit smaller, so they stay visible in
your peripheral vision.

Thumbnails keep their spot. Bringing a window into the middle swaps it with
the current middle window, and nothing else moves.

![Stage: a browser in the middle, other windows as thumbnails on both sides](docs/stage.png)

| Any window can take the middle | Narrow the middle and more, smaller columns appear |
|---|---|
| ![An image viewer in the middle](docs/stage-image.png) | ![A narrow editor in the middle with two thumbnail columns per side](docs/stage-narrow.png) |

## Keys

Stage is added as a third step to Omarchy's layout toggle. Other workspaces
keep Omarchy's normal bindings.

| Key | Action |
|---|---|
| `SUPER + L` | Cycle the workspace layout: dwindle → scrolling → stage → dwindle |
| Click a thumbnail | Swap it into the middle |
| `ALT + TAB` / `ALT + SHIFT + TAB` | Next / previous window, in the order they were opened |
| `SUPER + arrows` | Move focus without moving anything (you can type into a thumbnail) |
| `SUPER + Z` | Swap the focused thumbnail into the middle |
| `SUPER + -` / `SUPER + =` | Widen / narrow the middle window (`ALT`: a little, `CTRL`: a lot). The freed space fills with more, smaller thumbnail columns |

Which workspaces are in stage mode and how wide their middle window is are
remembered across reloads and logins.

## Requirements

- Omarchy with Hyprland **0.56 or newer** (stage is a Hyprland Lua layout)
- Optional, for real miniatures: `base-devel` (`make`, `g++`). Hyprland's
  headers ship with the `hyprland` package.

## Install

```bash
git clone https://github.com/Sulejman/omarchy-stage.git
cd omarchy-stage
./install.sh
```

The installer:

1. copies `stage.lua`, `stage-maintain.sh` and the `stagethumbs/` plugin source
   into `~/.config/hypr/` (any file it would change is backed up as `*.bak.<time>`),
2. adds `require("hypr.stage")` to `~/.config/hypr/hyprland.lua`,
3. installs two Omarchy hooks (`post-update`, `post-boot`),
4. builds the thumbnails plugin and reloads Hyprland.

To update: `git pull && ./install.sh`.

## Miniature thumbnails

Without the plugin, a thumbnail is the real window resized to a small box, so
apps re-lay themselves out for that size. The optional `stagethumbs` Hyprland
plugin instead keeps telling the app it has its full middle-of-screen size and
draws that content scaled down. Clicks are scaled too, so they land where they
appear.

Hyprland plugins must be built against the exact Hyprland version that's
running. The hooks take care of that. After `omarchy update`, and at login,
`stage-maintain.sh` rebuilds the plugin when the `hyprland` package version
has changed. If a build fails, the plugin is disabled (stage keeps working
with plain thumbnails), you get a notification, and the log is in
`~/.config/hypr/stagethumbs/build.log`.

The same script puts the `require` line back if `omarchy refresh hyprland`
or an update resets `hyprland.lua`.

## Tuning

The `cfg` table at the top of `~/.config/hypr/stage.lua` holds the knobs:
middle window aspect and min/max share of the screen, thumbnail column width,
how quickly outer columns shrink, and thumbnail opacity. Hyprland reloads on save.

Re-running `install.sh` overwrites the file (your version is backed up first).

## Uninstall

```bash
./uninstall.sh
```

This removes the files, hooks, `require` line and saved state, then reloads
Hyprland. Stage workspaces fall back to the default layout.

## Troubleshooting

- Errors inside stage's callbacks are logged to
  `~/.local/state/hypr-stage/errors.log`, because Hyprland's red error bar is
  cleared on every reload.
- Check for key conflicts with your own bindings:
  `omarchy menu keybindings --print`.

## License

MIT
