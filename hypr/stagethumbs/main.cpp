// stagethumbs: true miniatures for the Lua "stage" layout (~/.config/hypr/stage.lua).
//
// The layout gives thumbnail windows a small box. Normally the app is then
// resized to that box and re-lays itself out with full-size text. Instead,
// for windows the layout marks with hl.plugin.stagethumbs.set(), this plugin:
//   - keeps telling the app it has its full (middle-of-screen) size,
//   - draws that full-size content scaled down into the small box,
//   - scales pointer coordinates so clicks land where they appear,
//   - redraws the whole thumbnail whenever the app updates,
//   - tells the layout which thumbnail the pointer is over, so it can
//     highlight it (Hyprland has no hover event for Lua),
//   - tells the layout when ALT is released after Alt+Tab, so its switcher
//     can open the highlighted window (a release bind would be cancelled by
//     the TAB presses in between).
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
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <linux/input-event-codes.h>
#include <xkbcommon/xkbcommon.h>

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <optional>
#include <unordered_map>
#include <vector>
#include <format>

#include <hyprland/src/render/pass/TexPassElement.hpp>
#include <hyprgraphics/image/Image.hpp>

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

// thumbnail under the pointer (0: none), and the pending report of it to Lua
static uintptr_t                               g_hovered = 0;
static UP<SEventLoopDoLaterLock>               g_hoverReport;

// set by watch_alt(): report the next ALT release to the switcher
static bool                                    g_watchAlt = false;
static UP<SEventLoopDoLaterLock>               g_altReport;
static CHyprSignalListener                     g_keyListener;

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

// Report hover changes to the layout's Lua side as _G.omarchy_stage.hover().
// Deferred to the event loop: running Lua (which dispatches) from inside the
// seat manager isn't safe. Only the latest state is reported, so a fast sweep
// over several thumbnails costs one call.
static void reportHover(uintptr_t hovered) {
    if (hovered == g_hovered)
        return;
    g_hovered     = hovered;
    g_hoverReport = g_pEventLoopManager->doLaterLock([] {
        const auto addr = g_hovered ? std::format("0x{:x}", g_hovered) : std::string{};
        HyprlandAPI::invokeHyprctlCommand("eval", std::format("local s = _G.omarchy_stage; if s and s.hover then s.hover('{}') end", addr));
    });
}

typedef void (*setPointerFocusFn)(CSeatManager*, SP<CWLSurfaceResource>, const Vector2D&);
static void hkSetPointerFocus(CSeatManager* self, SP<CWLSurfaceResource> surface, const Vector2D& local) {
    ((setPointerFocusFn)g_hkFocus->m_original)(self, surface, toFull(surface, local));
    const auto window = windowOf(surface);
    reportHover(window && fullSize(window.get()) ? reinterpret_cast<uintptr_t>(window.get()) : 0);
}

typedef void (*sendPointerMotionFn)(CSeatManager*, uint32_t, const Vector2D&);
static void hkSendPointerMotion(CSeatManager* self, uint32_t timeMs, const Vector2D& local) {
    ((sendPointerMotionFn)g_hkMotion->m_original)(self, timeMs, toFull(self->m_state.pointerFocus.lock(), local));
}

// --- keyboard --------------------------------------------------------------

// ALT by hardware key, or by what the keymap makes of the key (remapped keys,
// virtual keyboards with their own keymaps).
static bool isAlt(uint32_t keycode) {
    if (keycode == KEY_LEFTALT || keycode == KEY_RIGHTALT)
        return true;
    const auto keyboard = g_pSeatManager->m_keyboard.lock();
    if (!keyboard || !keyboard->m_xkbStaticState)
        return false;
    const auto sym = xkb_state_key_get_one_sym(keyboard->m_xkbStaticState, keycode + 8);
    return sym == XKB_KEY_Alt_L || sym == XKB_KEY_Alt_R;
}

static void onKey(const IKeyboard::SKeyEvent& e) {
    if (!g_watchAlt || e.state != WL_KEYBOARD_KEY_STATE_RELEASED || !isAlt(e.keycode))
        return;
    g_watchAlt  = false;
    g_altReport = g_pEventLoopManager->doLaterLock(
        [] { HyprlandAPI::invokeHyprctlCommand("eval", "local s = _G.omarchy_stage; if s and s.tab_commit then s.tab_commit() end"); });
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

// --- app icon badge --------------------------------------------------------

// A small badge of the app's own icon sits in the bottom-left corner of every
// thumbnail, drawn on top of the miniature. The icon is resolved from the
// window class through the desktop files and the active icon theme, then
// loaded once and cached.

static constexpr double ICON_SHARE = 0.09; // badge width, as a share of the thumbnail width
static constexpr double ICON_MIN   = 14.0; // ...clamped between these,
static constexpr double ICON_MAX   = 44.0; // ...in pixels
static constexpr double ICON_INSET = 6.0;  // gap from the thumbnail's corner

static std::unordered_map<std::string, std::string>          g_classIcon; // "class\ntitle" -> icon file ("" = none)
static std::unordered_map<std::string, SP<Render::ITexture>> g_iconTex;   // icon file -> texture (null = failed)
static CHyprSignalListener                                   g_stageListener;

static std::string lower(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) { return std::tolower(c); });
    return s;
}

static std::string trim(const std::string& s) {
    const auto a = s.find_first_not_of(" \t\r\n");
    if (a == std::string::npos)
        return "";
    return s.substr(a, s.find_last_not_of(" \t\r\n") - a + 1);
}

// The XDG data dirs that hold applications/ and icons/.
static std::vector<std::string> dataDirs() {
    std::vector<std::string> dirs;
    const char*              home = std::getenv("HOME");
    if (const char* xdg = std::getenv("XDG_DATA_HOME"); xdg && *xdg)
        dirs.emplace_back(xdg);
    else if (home)
        dirs.emplace_back(std::string{home} + "/.local/share");

    const char* list = std::getenv("XDG_DATA_DIRS");
    const std::string s = (list && *list) ? list : "/usr/local/share:/usr/share";
    for (size_t pos = 0; pos <= s.size();) {
        const auto next = s.find(':', pos);
        const auto part = s.substr(pos, next == std::string::npos ? std::string::npos : next - pos);
        if (!part.empty())
            dirs.push_back(part);
        if (next == std::string::npos)
            break;
        pos = next + 1;
    }
    return dirs;
}

// Omarchy records the current icon theme name here.
static std::string activeIconTheme() {
    const char* home = std::getenv("HOME");
    if (home) {
        std::ifstream f(std::string{home} + "/.local/state/omarchy/current/theme/icons.theme");
        std::string   line;
        if (std::getline(f, line) && !trim(line).empty())
            return trim(line);
    }
    return "Yaru-blue"; // Omarchy's default
}

// The active theme and everything it inherits, so an icon that only the base
// theme ships is still found.
static std::vector<std::string> themeChain() {
    std::vector<std::string> themes;
    const auto               push = [&themes](const std::string& t) {
        if (!t.empty() && std::find(themes.begin(), themes.end(), t) == themes.end())
            themes.push_back(t);
    };

    push(activeIconTheme());

    for (size_t i = 0; i < themes.size() && i < 8; i++) {
        for (const auto& dir : dataDirs()) {
            std::ifstream f(dir + "/icons/" + themes[i] + "/index.theme");
            std::string   line;
            while (std::getline(f, line)) {
                if (line.rfind("Inherits=", 0) != 0)
                    continue;
                std::string cur;
                for (char c : trim(line.substr(9)) + ",") {
                    if (c == ',') {
                        push(trim(cur));
                        cur.clear();
                    } else
                        cur += c;
                }
            }
        }
    }

    push("hicolor");
    return themes;
}

// Resolve an icon name (as in a desktop file's Icon=) to a file on disk,
// preferring a large PNG and falling back to SVG.
static std::optional<std::string> iconFile(const std::string& name) {
    std::error_code ec;
    if (!name.empty() && name[0] == '/')
        return std::filesystem::exists(name, ec) ? std::optional{name} : std::nullopt;

    std::vector<std::string> iconDirs;
    for (const auto& d : dataDirs())
        iconDirs.push_back(d + "/icons");
    if (const char* home = std::getenv("HOME"))
        iconDirs.push_back(std::string{home} + "/.icons");

    static const std::vector<std::string> SIZES = {"256x256", "192x192", "128x128", "96x96", "64x64", "48x48", "32x32", "24x24", "16x16"};
    const auto                            themes = themeChain();

    for (const auto& dir : iconDirs) {
        for (const auto& theme : themes) {
            for (const auto& size : SIZES) {
                const auto p = dir + "/" + theme + "/" + size + "/apps/" + name + ".png";
                if (std::filesystem::exists(p, ec))
                    return p;
            }
            const auto svg = dir + "/" + theme + "/scalable/apps/" + name + ".svg";
            if (std::filesystem::exists(svg, ec))
                return svg;
        }
    }

    for (const auto& d : dataDirs()) {
        for (const char* ext : {".png", ".svg"}) {
            const auto p = d + "/pixmaps/" + name + ext;
            if (std::filesystem::exists(p, ec))
                return p;
        }
    }
    return std::nullopt;
}

// A Chromium --app window's class carries the site host:
// "brave-gemini.google.com__app-Default" -> "gemini.google.com". Empty when the
// class is not a browser app window (a plain tab like "brave-browser", or any
// other app), so the caller only trusts it for web apps.
static std::string hostFromClass(const std::string& klass) {
    static const std::vector<std::string> PREFIXES = {
        "brave-", "google-chrome-", "chrome-", "chromium-", "microsoft-edge-", "vivaldi-", "opera-", "helium-",
    };
    const auto k = lower(klass);
    std::string rest;
    for (const auto& p : PREFIXES) {
        if (k.rfind(p, 0) == 0) {
            rest = k.substr(p.size());
            break;
        }
    }
    if (rest.empty())
        return "";

    // Up to the first character a host can't hold; the URL path and profile
    // parts of the class follow an underscore.
    const auto end  = rest.find_first_not_of("abcdefghijklmnopqrstuvwxyz0123456789.-");
    auto       host = rest.substr(0, end == std::string::npos ? rest.size() : end);
    if (host.rfind("www.", 0) == 0)
        host = host.substr(4);
    return host.find('.') != std::string::npos ? host : "";
}

// The host of the first http(s) URL in a desktop file's Exec, e.g.
// `omarchy-launch-webapp "https://gemini.google.com/app"` -> "gemini.google.com".
static std::string hostFromExec(const std::string& exec) {
    const auto e      = lower(exec);
    auto       at     = e.find("https://");
    size_t     len    = 8;
    const auto httpAt = e.find("http://");
    if (httpAt != std::string::npos && (at == std::string::npos || httpAt < at)) {
        at  = httpAt;
        len = 7;
    }
    if (at == std::string::npos)
        return "";

    at += len;
    const auto end  = e.find_first_of("/\"' \t", at);
    auto       host = e.substr(at, end == std::string::npos ? std::string::npos : end - at);
    if (host.rfind("www.", 0) == 0)
        host = host.substr(4);
    return host;
}

// The Icon= of the desktop file that best fits a window: a StartupWMClass
// match names the app directly; failing that -- apps like the Omarchy shell
// widgets all share one generic class, so the class says little -- the window
// title matched against the desktop name; failing that the desktop file or
// program named after the class.
static std::optional<std::string> desktopIconName(const std::string& klass, const std::string& title) {
    const auto      wantClass = lower(klass);
    const auto      wantTitle = lower(trim(title));
    const auto      classHost = hostFromClass(klass);
    std::error_code ec;

    std::optional<std::string> byTitle, byHost, byClass;
    for (const auto& d : dataDirs()) {
        const auto adir = d + "/applications";
        if (!std::filesystem::is_directory(adir, ec))
            continue;

        for (const auto& entry : std::filesystem::directory_iterator(adir, ec)) {
            if (entry.path().extension() != ".desktop")
                continue;

            std::ifstream f(entry.path());
            std::string   line, icon, name, wmclass, exec;
            while (std::getline(f, line)) {
                if (line.rfind("Icon=", 0) == 0)
                    icon = trim(line.substr(5));
                else if (line.rfind("Name=", 0) == 0)
                    name = trim(line.substr(5));
                else if (line.rfind("StartupWMClass=", 0) == 0)
                    wmclass = trim(line.substr(15));
                else if (line.rfind("Exec=", 0) == 0)
                    exec = trim(line.substr(5));
            }
            if (icon.empty())
                continue;

            if (!wmclass.empty() && lower(wmclass) == wantClass)
                return icon;

            if (!byTitle && !wantTitle.empty() && !name.empty() && lower(name) == wantTitle)
                byTitle = icon;

            auto exe = exec.substr(0, exec.find(' '));
            exe      = exe.substr(exe.find_last_of('/') + 1);
            if (!byClass && (lower(entry.path().stem().string()) == wantClass || (!exe.empty() && lower(exe) == wantClass)))
                byClass = icon;

            if (!byHost && !classHost.empty()) {
                const auto execHost = hostFromExec(exec);
                if (!execHost.empty() && execHost == classHost)
                    byHost = icon;
            }
        }
    }
    return byTitle ? byTitle : (byHost ? byHost : byClass);
}

static std::string iconForWindow(const std::string& klass, const std::string& title) {
    const auto key = klass + "\n" + title;
    const auto it  = g_classIcon.find(key);
    if (it != g_classIcon.end())
        return it->second;

    if (g_classIcon.size() > 512) // titles can churn; don't grow without bound
        g_classIcon.clear();

    std::string path;
    if (const auto name = desktopIconName(klass, title); name)
        if (const auto file = iconFile(*name); file)
            path = *file;

    g_classIcon[key] = path;
    return path;
}

static SP<Render::ITexture> iconTexture(const std::string& path) {
    const auto it = g_iconTex.find(path);
    if (it != g_iconTex.end())
        return it->second;

    SP<Render::ITexture> tex;
    Hyprgraphics::CImage img(path, {256, 256}); // the size only matters for SVG
    if (img.success() && img.cairoSurface())
        tex = g_pHyprRenderer->createTexture(img.cairoSurface()->cairo());

    g_iconTex[path] = tex; // cache failures too, so we don't retry every frame
    return tex;
}

static void onRenderStage(eRenderStage stage) {
    if (stage != RENDER_POST_WINDOW)
        return;

    const auto window = g_pHyprRenderer->m_renderData.currentWindow.lock();
    if (!window || !fullSize(window.get()))
        return;

    const auto monitor = g_pHyprRenderer->m_renderData.pMonitor.lock();
    if (!monitor)
        return;

    const auto klass = !window->m_class.empty() ? window->m_class : window->m_initialClass;
    const auto title = !window->m_title.empty() ? window->m_title : window->m_initialTitle;
    if (klass.empty() && title.empty())
        return;

    const auto tex = iconTexture(iconForWindow(klass, title));
    if (!tex)
        return;

    const auto box  = window->getWindowMainSurfaceBox();
    const auto size = std::clamp(box.w * ICON_SHARE, ICON_MIN, ICON_MAX);

    CTexPassElement::SRenderData data;
    data.tex = tex;
    data.box = CBox{box.x - monitor->m_position.x + ICON_INSET, box.y - monitor->m_position.y + box.h - size - ICON_INSET, size, size};
    g_pHyprRenderer->addPassElement(makeUnique<CTexPassElement>(std::move(data)));
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
    const auto addr = addressArg(L, 1);
    g_full.erase(addr);
    if (addr == g_hovered)
        reportHover(0);
    return 0;
}

// watch_alt(): call _G.omarchy_stage.tab_commit() when ALT is next released
static int luaWatchAlt(lua_State* L) {
    g_watchAlt = true;
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
    HyprlandAPI::addLuaFunction(PHANDLE, "stagethumbs", "watch_alt", luaWatchAlt);

    g_keyListener   = Event::bus()->m_events.input.keyboard.key.listen([](IKeyboard::SKeyEvent e, Event::SCallbackInfo&) { onKey(e); });
    g_stageListener = Event::bus()->m_events.render.stage.listen([](eRenderStage stage) { onRenderStage(stage); });

    return {"stagethumbs", "True miniatures for the Lua stage layout", "sulejman", "0.5"};
}

APICALL EXPORT void PLUGIN_EXIT() {
    g_keyListener.reset();
    g_stageListener.reset();
    g_hoverReport.reset(); // drop pending reports before our code is unloaded
    g_altReport.reset();
    g_full.clear();
    g_classIcon.clear();
    g_iconTex.clear();
    for (auto* h : {g_hkReportSize, g_hkUV, g_hkTexBox, g_hkFocus, g_hkMotion, g_hkDamage}) {
        if (h)
            HyprlandAPI::removeFunctionHook(PHANDLE, h);
    }
    for (const char* fn : {"set", "clear", "loaded", "watch_alt"})
        HyprlandAPI::removeLuaFunction(PHANDLE, "stagethumbs", fn);
}
