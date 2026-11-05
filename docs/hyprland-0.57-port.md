# Hyprland 0.57 miniature renderer port

The 0.56 renderer fails to compile on 0.57.1 because Window.hpp moved. Beyond
that first error, window state and workspace accessors changed, the
realToReportSize hook disappeared, and calculateUVForSurface now receives a
CRenderContext instead of using shared renderer data.

The compatibility branch detects the new window header and:

- Uses isFloating(), backend().isX11(), and workspace->space().
- Hooks CWaylandBackend::configure to override only the client configure size.
  The compositor's small thumbnail layout box remains unchanged. Native
  logicalToClient conversion still runs, including monitor scale handling.
- Forwards CRenderContext through the UV hook and updates its m_data.
- Preserves the existing 0.56 code path. XWayland windows remain excluded.

## Offline validation

Tested with Hyprland 0.57.1-2, commit
acc1aa0bfd4bd575dcb0f76c35ccf12b660a1ab9, on x86_64.

```sh
make -C hypr/stagethumbs
make -C hypr/stagethumbs check
```

Both pass. The check compiles the actual hook aliases against all six native
member-function declarations. It does not load or run the plugin.

All six lookups were also inspected in the exact installed Hyprland binary
using nm -D -C; each resolves to one exported target:

- Desktop::View::CWaylandBackend::configure
- Render::IElementRenderer::calculateUVForSurface
- CSurfacePassElement::getTexBox
- CSeatManager::setPointerFocus
- CSeatManager::sendPointerMotion
- Render::IHyprRenderer::damageSurface

The 0.56 branch has not been rebuilt in this environment. Offline success
establishes compilation and hook types, not visual or input correctness.

## Runtime validation checklist

Use a disposable/nested compositor or save work before testing in a desktop
session: the native plugin executes inside Hyprland.

- Open several native Wayland apps on one Stage workspace.
- Confirm side windows preserve their full app layout and are scaled down.
- Check hover, promotion by click, and input at several positions in miniatures.
- Check continuous animation/video and subsurface rendering.
- Check Alt+Tab commit and resizing the middle window.
- Check fractional scaling and a second monitor if available.
- Leave Stage, toggle floating/fullscreen, and move windows between workspaces;
  confirm full-size rendering and input are restored.
- Reload the Lua config and disable Stage; check for stale thumbnails or crashes.

## Initial live trial (2026-11-05)

The patched main.cpp and built library were installed into the existing
Omarchy plugin and loaded through its stage-service.sh loader. Hyprland
reports stagethumbs 0.3 loaded, its Lua loaded() function returns true, and
configerrors is empty. A desktop capture confirms side windows display full
application layouts scaled down as miniatures rather than reflowed small
windows. The user subsequently confirmed that the live thumbnails work well
in normal use. This is an initial live acceptance result, not a claim that
every item in the runtime checklist above has been tested; detailed pointer
accuracy, video/subsurfaces, multi-monitor behavior, and lifecycle transitions
still need targeted coverage.
