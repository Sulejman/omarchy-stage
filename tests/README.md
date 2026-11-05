# Focus regression checks

From the repository root, run:

```sh
lua tests/stage-focus.lua
```

The harness loads the actual Stage script with a simulated Hyprland API,
registers its layout and event handlers, adds a second window, sends focus
events, and runs the deferred relayout. It checks which window occupies the
middle. It does not require a running compositor or read/write user state.

Coverage includes the 0.56 ordinal reasons and the 0.57 bitmask reasons,
including click down/up, new-window focus, explicit switches, and events that
must not promote a window (hover, directional navigation, and close fallback).
The native definitions are in Hyprland's
[0.56 FocusState.hpp](https://github.com/hyprwm/Hyprland/blob/v0.56.0/src/desktop/state/FocusState.hpp)
and
[0.57 FocusState.hpp](https://github.com/hyprwm/Hyprland/blob/v0.57.0/src/desktop/state/FocusState.hpp).

## Live validation

The change was also checked on Hyprland 0.57.1 in an isolated headless
compositor with two disposable native Wayland terminal windows, both without
and with stagethumbs 0.3 loaded:

- Before: the new window stayed in a thumbnail (335 px wide); explicitly
  focusing the old window and then the new one did not promote it.
- After: opening the second window immediately put it in the middle
  (1204 px wide); explicitly switching between the two also promoted them.
- Config errors were empty in both runs.

The harness covers click reason handling; physical pointer clicks were not
part of this live test. Hyprland 0.56 compatibility was checked by the harness,
not by running a second compositor version.
