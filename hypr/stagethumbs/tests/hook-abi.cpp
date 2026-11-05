// Compile the real hook aliases against the installed Hyprland declarations.
// Access control is relaxed only for this offline, syntax-only check.
#include <bits/stdc++.h>
#define private public
#define protected public
#include "../main.cpp"
#undef protected
#undef private

template <typename> struct MemberSignature;
template <typename R, typename C, typename... Args>
struct MemberSignature<R (*)(C*, Args...)> {
    using Type = R (C::*)(Args...);
};

#ifdef STAGE_HYPRLAND_057
static_assert(std::is_same_v<MemberSignature<configureFn>::Type, decltype(&Desktop::View::CWaylandBackend::configure)>);
static_assert(std::is_same_v<configureFn, decltype(&hkConfigure)>);
#else
static_assert(std::is_same_v<MemberSignature<realToReportSizeFn>::Type, decltype(&CWindow::realToReportSize)>);
static_assert(std::is_same_v<realToReportSizeFn, decltype(&hkRealToReportSize)>);
#endif
static_assert(std::is_same_v<MemberSignature<calcUVFn>::Type, decltype(&Render::IElementRenderer::calculateUVForSurface)>);
static_assert(std::is_same_v<MemberSignature<getTexBoxFn>::Type, decltype(&CSurfacePassElement::getTexBox)>);
static_assert(std::is_same_v<MemberSignature<setPointerFocusFn>::Type, decltype(&CSeatManager::setPointerFocus)>);
static_assert(std::is_same_v<MemberSignature<sendPointerMotionFn>::Type, decltype(&CSeatManager::sendPointerMotion)>);
static_assert(std::is_same_v<MemberSignature<damageSurfaceFn>::Type, decltype(&Render::IHyprRenderer::damageSurface)>);
static_assert(std::is_same_v<calcUVFn, decltype(&hkCalculateUVForSurface)>);
static_assert(std::is_same_v<getTexBoxFn, decltype(&hkGetTexBox)>);
static_assert(std::is_same_v<setPointerFocusFn, decltype(&hkSetPointerFocus)>);
static_assert(std::is_same_v<sendPointerMotionFn, decltype(&hkSendPointerMotion)>);
static_assert(std::is_same_v<damageSurfaceFn, decltype(&hkDamageSurface)>);
