# Rebuilt automatically after Hyprland updates by ~/.config/hypr/stage-maintain.sh.
# Manual rebuild: make -C ~/.config/hypr/stagethumbs
CXXFLAGS = -shared -fPIC -O2 -std=c++26 -Wall -Wno-deprecated-declarations
INCLUDES = $(shell pkg-config --cflags hyprland pixman-1 libdrm hyprutils hyprlang aquamarine hyprgraphics lua5.5)

stagethumbs.so: main.cpp
	$(CXX) $(CXXFLAGS) $(INCLUDES) main.cpp -o $@.tmp && mv -f $@.tmp $@

clean:
	rm -f stagethumbs.so

.PHONY: clean
