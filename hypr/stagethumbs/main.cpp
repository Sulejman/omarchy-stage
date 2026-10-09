// stagethumbs: true miniatures for the Lua "stage" layout (~/.config/hypr/stage.lua).
//
// The layout gives thumbnail windows a small box. Normally the app is then
// resized to that box and re-lays itself out with full-size text. Instead,
// for windows the layout marks with hl.plugin.stagethumbs.set(), this plugin:
//   - keeps telling the app it has its full (middle-of-screen) size,
//   - draws that full-size content scaled down into the small box,
//   - scales pointer coordinates so clicks land where they appear,
//   - redraws the whole thumbnail whenever the app updates.
//
// It only acts on tiled, non-fullscreen windows on a workspace whose layout
// is lua:stage, so a window moved elsewhere goes back to normal by itself.

#define WLR_USE_UNSTABLE

#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/desktop/view/WLSurface.hpp>
#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/layout/space/Space.hpp>
#include <hyprland/src/layout/algorithm/Algorithm.hpp>
#include <hyprland/src/layout/supplementary/WorkspaceAlgoMatcher.hpp>
#include <hyprland/src/render/pass/SurfacePassElement.hpp>
#include <hyprland/src/render/ElementRenderer.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/managers/SeatManager.hpp>
#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>
#include <hyprland/src/protocols/core/Compositor.hpp>

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

#include <unordered_map>
#include <optional>

using Desktop::View::CWindow;

static HANDLE                                  PHANDLE = nullptr;
static const std::string                       LAYOUT  = "lua:stage";

// window address -> size the app is told it has
static std::unordered_map<uintptr_t, Vector2D> g_full;

static CFunctionHook*                          g_hkReportSize = nullptr;
static CFunctionHook*                          g_hkUV         = nullptr;
static CFunctionHook*                          g_hkTexBox     = nullptr;
static CFunctionHook*                          g_hkFocus      = nullptr;
static CFunctionHook*                          g_hkMotion     = nullptr;
static CFunctionHook*                          g_hkDamage     = nullptr;

// The full size of a window currently shown as a thumbnail, if it is one.
static std::optional<Vector2D> fullSize(const CWindow* w) {
    if (!w || g_full.empty())
        return std::nullopt;

    const auto it = g_full.find(reinterpret_cast<uintptr_t>(w));
    if (it == g_full.end())
        return std::nullopt;

    if (w->m_isFloating || w->m_isX11)
        return std::nullopt;

    const auto& ws = w->m_workspace;
    if (!ws || !ws->m_space || !ws->m_space->algorithm() || !ws->m_space->algorithm()->tiledAlgo())
        return std::nullopt;

    if (Fullscreen::controller()->isFullscreen(w->m_self.lock()))
        return std::nullopt;

    if (Layout::Supplementary::algoMatcher()->getNameForTiledAlgo(ws->m_space->algorithm()->tiledAlgo().get()) != LAYOUT)
        return std::nullopt;

    return it->second;
}

static PHLWINDOW windowOf(SP<CWLSurfaceResource> surface) {
    if (!surface)
        return nullptr;
    const auto wl = Desktop::View::CWLSurface::fromResource(surface);
    if (!wl)
        return nullptr;
    return CWindow::fromView(wl->view());
}

// thumbnail box size / full size, per axis
static std::optional<Vector2D> shrink(const CWindow* w) {
    const auto full = fullSize(w);
    if (!full || full->x < 1 || full->y < 1)
        return std::nullopt;
    const auto box = w->getWindowMainSurfaceBox().size();
    if (box.x < 1 || box.y < 1)
        return std::nullopt;
    return box / *full;
}

// --- size reported to the app ----------------------------------------------

typedef Vector2D (*realToReportSizeFn)(CWindow*);
static Vector2D hkRealToReportSize(CWindow* self) {
    if (const auto full = fullSize(self))
        return *full;
    return ((realToReportSizeFn)g_hkReportSize->m_original)(self);
}

// --- drawing ---------------------------------------------------------------

// Hyprland crops a buffer that is larger than its window instead of scaling
// it. For thumbnails, show the whole buffer (respecting any viewport crop the
// app asked for) so it gets squeezed into the box.
typedef void (*calcUVFn)(Render::IElementRenderer*, PHLWINDOW, SP<CWLSurfaceResource>, PHLMONITOR, bool, const Vector2D&, const Vector2D&, bool);
static void hkCalculateUVForSurface(Render::IElementRenderer* self, PHLWINDOW window, SP<CWLSurfaceResource> surface, PHLMONITOR monitor, bool main, const Vector2D& projSize,
                                    const Vector2D& projSizeUnscaled, bool fixMisaligned) {
    ((calcUVFn)g_hkUV->m_original)(self, window, surface, monitor, main, projSize, projSizeUnscaled, fixMisaligned);

    if (!window || !surface || !fullSize(window.get()))
        return;

    Vector2D uvTL{0, 0}, uvBR{1, 1};
    if (surface->m_current.viewport.hasSource) {
        const auto& buffer = surface->m_current.bufferSize;
        const auto& source = surface->m_current.viewport.source;
        if (buffer.x > 0 && buffer.y > 0) {
            uvTL = {source.x / buffer.x, source.y / buffer.y};
            uvBR = {(source.x + source.width) / buffer.x, (source.y + source.height) / buffer.y};
        }
    }

    auto& rd = g_pHyprRenderer->m_renderData;
    if (uvTL == Vector2D{0, 0} && uvBR == Vector2D{1, 1}) {
        rd.primarySurfaceUVTopLeft     = {-1, -1};
        rd.primarySurfaceUVBottomRight = {-1, -1};
    } else {
        rd.primarySurfaceUVTopLeft     = uvTL;
        rd.primarySurfaceUVBottomRight = uvBR;
    }
}

// The main surface is already stretched to the window box; subsurfaces
// (video, embedded views) are drawn at their own size, so scale them too.
typedef CBox (*getTexBoxFn)(CSurfacePassElement*);
static CBox hkGetTexBox(CSurfacePassElement* self) {
    const CBox original = ((getTexBoxFn)g_hkTexBox->m_original)(self);

    const auto& d = self->m_data;
    if (d.mainSurface || d.popup || !d.surface || !d.pWindow || !d.pMonitor)
        return original;

    const auto scale = shrink(d.pWindow.get());
    if (!scale)
        return original;

    const auto mon  = d.pMonitor.lock();
    const auto size = d.surface->m_current.size;
    CBox       box{-mon->m_position.x + d.pos.x + d.localPos.x * scale->x, -mon->m_position.y + d.pos.y + d.localPos.y * scale->y,
                   std::max(size.x, 2.0) * scale->x, std::max(size.y, 2.0) * scale->y};

    if (d.squishOversized) {
        if (d.localPos.x * scale->x + box.width > d.w)
            box.width = d.w - d.localPos.x * scale->x;
        if (d.localPos.y * scale->y + box.height > d.h)
            box.height = d.h - d.localPos.y * scale->y;
    }
    return box;
}

// --- pointer ---------------------------------------------------------------

static Vector2D toFull(SP<CWLSurfaceResource> surface, const Vector2D& local) {
    const auto window = windowOf(surface);
    if (!window)
        return local;
    const auto scale = shrink(window.get());
    if (!scale)
        return local;
    return local / *scale;
}

typedef void (*setPointerFocusFn)(CSeatManager*, SP<CWLSurfaceResource>, const Vector2D&);
static void hkSetPointerFocus(CSeatManager* self, SP<CWLSurfaceResource> surface, const Vector2D& local) {
    ((setPointerFocusFn)g_hkFocus->m_original)(self, surface, toFull(surface, local));
}

typedef void (*sendPointerMotionFn)(CSeatManager*, uint32_t, const Vector2D&);
static void hkSendPointerMotion(CSeatManager* self, uint32_t timeMs, const Vector2D& local) {
    ((sendPointerMotionFn)g_hkMotion->m_original)(self, timeMs, toFull(self->m_state.pointerFocus.lock(), local));
}

// --- damage ----------------------------------------------------------------

// Damage arrives in the app's full-size coordinates; just redraw the whole
// (small) thumbnail instead.
typedef void (*damageSurfaceFn)(void*, SP<CWLSurfaceResource>, double, double, double);
static void hkDamageSurface(void* self, SP<CWLSurfaceResource> surface, double x, double y, double scale) {
    const auto window = windowOf(surface);
    if (window && fullSize(window.get())) {
        g_pHyprRenderer->damageWindow(window);
        return;
    }
    ((damageSurfaceFn)g_hkDamage->m_original)(self, surface, x, y, scale);
}

// --- Lua API: hl.plugin.stagethumbs.* -------------------------------------

static uintptr_t addressArg(lua_State* L, int idx) {
    const char* str = luaL_checkstring(L, idx);
    return std::stoull(str, nullptr, 16);
}

// set(address, w, h): show this window as a thumbnail of a w x h window
static int luaSet(lua_State* L) {
    const auto addr = addressArg(L, 1);
    const auto w    = luaL_checknumber(L, 2);
    const auto h    = luaL_checknumber(L, 3);
    if (w >= 1 && h >= 1)
        g_full[addr] = Vector2D{w, h}.floor();
    return 0;
}

// clear(address): back to a normal window
static int luaClear(lua_State* L) {
    g_full.erase(addressArg(L, 1));
    return 0;
}

static int luaLoaded(lua_State* L) {
    lua_pushboolean(L, 1);
    return 1;
}

// --- plugin lifecycle ------------------------------------------------------

static void* find(const std::string& name, const std::string& demangled) {
    for (const auto& match : HyprlandAPI::findFunctionsByName(PHANDLE, name)) {
        if (match.demangled.find(demangled) != std::string::npos)
            return match.address;
    }
    throw std::runtime_error("stagethumbs: could not find " + demangled);
}

static CFunctionHook* hook(const std::string& name, const std::string& demangled, void* fn) {
    auto* h = HyprlandAPI::createFunctionHook(PHANDLE, find(name, demangled), fn);
    if (!h || !h->hook())
        throw std::runtime_error("stagethumbs: could not hook " + demangled);
    return h;
}

APICALL EXPORT std::string PLUGIN_API_VERSION() {
    return HYPRLAND_API_VERSION;
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    PHANDLE = handle;

    if (__hyprland_api_get_hash() != std::string{__hyprland_api_get_client_hash()})
        throw std::runtime_error("stagethumbs: built for a different Hyprland version, rebuild it (make -C ~/.config/hypr/stagethumbs)");

    g_hkReportSize = hook("realToReportSize", "CWindow::realToReportSize", (void*)&hkRealToReportSize);
    g_hkUV         = hook("calculateUVForSurface", "IElementRenderer::calculateUVForSurface", (void*)&hkCalculateUVForSurface);
    g_hkTexBox     = hook("getTexBox", "CSurfacePassElement::getTexBox", (void*)&hkGetTexBox);
    g_hkFocus      = hook("setPointerFocus", "CSeatManager::setPointerFocus", (void*)&hkSetPointerFocus);
    g_hkMotion     = hook("sendPointerMotion", "CSeatManager::sendPointerMotion", (void*)&hkSendPointerMotion);
    g_hkDamage     = hook("damageSurface", "::damageSurface(", (void*)&hkDamageSurface);

    HyprlandAPI::addLuaFunction(PHANDLE, "stagethumbs", "set", luaSet);
    HyprlandAPI::addLuaFunction(PHANDLE, "stagethumbs", "clear", luaClear);
    HyprlandAPI::addLuaFunction(PHANDLE, "stagethumbs", "loaded", luaLoaded);

    return {"stagethumbs", "True miniatures for the Lua stage layout", "sulejman", "0.1"};
}

APICALL EXPORT void PLUGIN_EXIT() {
    g_full.clear();
    for (auto* h : {g_hkReportSize, g_hkUV, g_hkTexBox, g_hkFocus, g_hkMotion, g_hkDamage}) {
        if (h)
            HyprlandAPI::removeFunctionHook(PHANDLE, h);
    }
    for (const char* fn : {"set", "clear", "loaded"})
        HyprlandAPI::removeLuaFunction(PHANDLE, "stagethumbs", fn);
}
