#include "virtual-pointer.h"
#include <chrono>
#include <cstring>
#include <iostream>
#include <sstream>
#include <wayland-client.h>
static zwlr_virtual_pointer_manager_v1 *manager;
static void global(void *, wl_registry *r, uint32_t id, const char *iface,
                   uint32_t version) {
  if (!strcmp(iface, zwlr_virtual_pointer_manager_v1_interface.name))
    manager = (zwlr_virtual_pointer_manager_v1 *)wl_registry_bind(
        r, id, &zwlr_virtual_pointer_manager_v1_interface, 1);
}
static void removed(void *, wl_registry *, uint32_t) {}
int main() {
  auto d = wl_display_connect(nullptr);
  if (!d)
    return 1;
  auto r = wl_display_get_registry(d);
  wl_registry_listener listener{global, removed};
  wl_registry_add_listener(r, &listener, nullptr);
  wl_display_roundtrip(d);
  if (!manager)
    return 2;
  auto p =
      zwlr_virtual_pointer_manager_v1_create_virtual_pointer(manager, nullptr);
  wl_display_roundtrip(d);
  std::string line;
  while (std::getline(std::cin, line)) {
    std::istringstream s(line);
    std::string cmd;
    unsigned x, y, width, height;
    s >> cmd >> x;
    uint32_t t = std::chrono::duration_cast<std::chrono::milliseconds>(
                     std::chrono::steady_clock::now().time_since_epoch())
                     .count();
    if (cmd == "move") {
      s >> y >> width >> height;
      zwlr_virtual_pointer_v1_motion_absolute(p, t, x, y, width, height);
    } else if (cmd == "press" || cmd == "release")
      zwlr_virtual_pointer_v1_button(p, t, x,
                                     cmd == "press"
                                         ? WL_POINTER_BUTTON_STATE_PRESSED
                                         : WL_POINTER_BUTTON_STATE_RELEASED);
    zwlr_virtual_pointer_v1_frame(p);
    wl_display_roundtrip(d);
    std::cout << "ok" << std::endl;
  }
  zwlr_virtual_pointer_v1_destroy(p);
  wl_display_roundtrip(d);
  wl_display_disconnect(d);
}
