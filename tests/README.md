# Thumbnail activation regression checks

From the repository root:

```sh
lua tests/thumbnail-activation.lua
make -C hypr/stagethumbs
python tests/thumbnail-click.py --protocol /path/to/Hyprland/protocols/wlr-virtual-pointer-unstable-v1.xml
```

The Lua harness exercises the actual registered layout, activation handler,
and deferred relayout with both focused and unfocused thumbnails. It isolates
persisted user state and does not require a running compositor.

The live test requires Omarchy, a C/C++ compiler, Qt6 Widgets development files,
wayland-client, wayland-scanner, and the virtual-pointer protocol XML from
Hyprland's source tree. It starts a nested compositor on a temporary inactive
workspace, builds two small test clients, and cleans them up afterward.

Real pointer input must activate thumbnails without delivering either press
or release to the app, including releases after promotion or over another
window. The test also covers already-focused thumbnails, right clicks,
subsequent centered clicks, compositor mouse bindings, reloads, and leaving
Stage. The old renderer fails with `Activation click leaked to app`.

Live validation used Hyprland 0.57.1 together with the renderer compatibility
changes in PR #5; Hyprland 0.56 was not run. Use `--plugin /path/to/stagethumbs.so`
to select a compatible build. Initial fixture placement uses explicit activation
so the test is independent of PR #6's new-window focus handling.
