#!/usr/bin/env python3
"""Run real pointer input against a click-counting app in nested Hyprland."""
import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time

REPO = Path(__file__).resolve().parent.parent


def wait(check):
    for _ in range(100):
        result = check()
        if result:
            return result
        time.sleep(0.05)
    raise AssertionError("Timed out waiting for compositor/window state")


def run(root, protocol, plugin):
    def build(*args):
        subprocess.run(args, check=True, cwd=root)

    qt = shlex.split(subprocess.check_output(
        ["pkg-config", "--cflags", "--libs", "Qt6Widgets"], text=True))
    wl = shlex.split(subprocess.check_output(
        ["pkg-config", "--cflags", "--libs", "wayland-client"], text=True))
    build("c++", "-std=c++20", str(REPO / "tests/fixtures/click-counter.cpp"),
          "-o", "counter", *qt)
    build("wayland-scanner", "client-header", str(protocol), "virtual-pointer.h")
    build("wayland-scanner", "private-code", str(protocol), "virtual-pointer.c")
    build("cc", "-c", "virtual-pointer.c", "-o", "virtual-pointer.o", *wl)
    build("c++", "-std=c++20", str(REPO / "tests/fixtures/virtual-pointer.cpp"),
          "-I", str(root), "virtual-pointer.o", "-o", "pointer", *wl)
    # JSON string quoting is also valid for these Lua path strings.
    config = root / "hyprland.lua"
    config.write_text("""
dofile('/usr/share/omarchy/default/hypr/bootstrap.lua')
require('default.hypr.helpers')
hl.config({general={layout='lua:stage',gaps_in=5,gaps_out=10},
  animations={enabled=false}, input={follow_mouse=1},
  misc={disable_hyprland_logo=true,disable_splash_rendering=true}})
hl.monitor({output='',mode='1920x1080@60',position='auto',scale=1})
hl.plugin.load(%s)
_G.stage_runtime=true
dofile(%s)
""" % (json.dumps(str(plugin)), json.dumps(str(REPO / "hypr/stage.lua"))))
    processes = []
    pointer = None
    with (root / "compositor.log").open("w") as output:
        compositor = subprocess.Popen(
            ["Hyprland", "--config", str(config)],
            env=dict(os.environ, XDG_STATE_HOME=str(root / "state")),
            stdout=output, stderr=output)
        try:
            def instance():
                assert compositor.poll() is None, "Test compositor exited"
                instances = json.loads(subprocess.check_output(["hyprctl", "instances", "-j"]))
                return next((i for i in instances if i["pid"] == compositor.pid), None)

            i = wait(instance)
            # Keep the nested window off the user's active workspace. Physical
            # mouse motion over it would otherwise race the virtual pointer.
            def parent_window():
                return next((w for w in json.loads(subprocess.check_output(
                    ["hyprctl", "-j", "clients"])) if w["pid"] == compositor.pid), None)

            parent = wait(parent_window)
            subprocess.run(["hyprctl", "eval", 'hl.dispatch(hl.dsp.window.move({window="address:'
                + parent["address"] + '",workspace="name:stage-click-test-'
                + str(os.getpid()) + '",follow=false}))'], check=True, stdout=subprocess.DEVNULL)
            time.sleep(0.3)
            env = dict(os.environ, HYPRLAND_INSTANCE_SIGNATURE=i["instance"],
                       WAYLAND_DISPLAY=i["wl_socket"], QT_QPA_PLATFORM="wayland")

            def ctl(*args):
                return subprocess.check_output(["hyprctl", *args], env=env, text=True).strip()

            def windows():
                return [w for w in json.loads(ctl("-j", "clients"))
                        if w["class"] == "stage-click-counter"]

            def window(name):
                return next(w for w in windows() if w["title"] == name)

            wait(lambda: json.loads(ctl("-j", "monitors")))
            assert not ctl("configerrors"), ctl("configerrors")
            for name in ("A", "B"):
                processes.append(subprocess.Popen(
                    [str(root / "counter"), str(root / (name + ".log")), name],
                    env=env, stdout=output, stderr=output))
                wait(lambda: any(w["title"] == name for w in windows()))
                # Prime the fixture explicitly: new-window focus handling is
                # a separate compatibility change on Hyprland 0.57.
                w = window(name)
                ctl("eval", 'omarchy_stage.activate("' + w["address"] + '")')
                time.sleep(0.25)
            pointer = subprocess.Popen([str(root / "pointer")], env=env,
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)

            def event(line):
                pointer.stdin.write(line + "\n")
                pointer.stdin.flush()
                assert pointer.stdout.readline().strip() == "ok"
                time.sleep(0.15)

            def move(name):
                w = window(name)
                monitor = json.loads(ctl("-j", "monitors"))[0]
                event("move %d %d %d %d" % (w["at"][0] + w["size"][0] // 2,
                      w["at"][1] + w["size"][1] // 2,
                      monitor["width"] / monitor["scale"], monitor["height"] / monitor["scale"]))

            def log(name):
                path = root / (name + ".log")
                return path.read_text() if path.exists() else ""

            assert window("A")["size"][0] < window("B")["size"][0]
            move("A")
            event("press 272")
            wait(lambda: window("A")["size"][0] > window("B")["size"][0])
            # Release after promotion with the pointer over the other window.
            move("B")
            event("release 272")
            assert not log("A") and not log("B"), "Activation click leaked to app"
            move("A")
            event("press 272")
            event("release 272")
            assert log("A") == "press 1\nrelease 1\n", log("A")
            print("PASS: activation consumes press/release; centered click works")

            b, a = window("B"), window("A")
            direction = "l" if b["at"][0] < a["at"][0] else "r"
            ctl("eval", 'omarchy_stage.focus("' + direction + '")()')
            assert json.loads(ctl("-j", "activewindow"))["address"] == b["address"]
            assert window("B")["size"][0] < window("A")["size"][0]
            move("B")
            event("press 273")
            wait(lambda: window("B")["size"][0] > window("A")["size"][0])
            move("B")
            event("release 273")
            assert not log("B"), "Focused thumbnail right-click leaked"
            event("press 273")
            event("release 273")
            assert log("B") == "press 2\nrelease 2\n", log("B")
            print("PASS: focused thumbnail activates; centered right-click works")

            # Compositor bindings take precedence over activating thumbnails.
            marker = root / "binding"
            ctl("eval", 'hl.bind("mouse:274", function() local f=io.open('
                + json.dumps(str(marker)) + ',"w"); f:write("ran"); f:close() end)')
            move("A")
            event("press 274")
            event("release 274")
            assert marker.read_text() == "ran"
            assert window("A")["size"][0] < window("B")["size"][0]
            assert log("A") == "press 1\nrelease 1\n", log("A")
            print("PASS: compositor mouse binding remains available")

            ctl("reload")
            time.sleep(0.5)
            # A reload reinitializes Stage around the current focus; either
            # window may now be the thumbnail.
            thumbnail = min(("A", "B"), key=lambda name: window(name)["size"][0])
            middle = "B" if thumbnail == "A" else "A"
            previous = log(thumbnail)
            move(thumbnail)
            event("press 272")
            wait(lambda: window(thumbnail)["size"][0] > window(middle)["size"][0])
            event("release 272")
            assert log(thumbnail) == previous, log(thumbnail)
            print("PASS: thumbnail activation still works after config reload")

            workspace = json.loads(ctl("-j", "activeworkspace"))["id"]
            ctl("eval", 'hl.workspace_rule({workspace="' + str(workspace)
                + '",layout="dwindle"})')
            wait(lambda: json.loads(ctl("-j", "activeworkspace"))["tiledLayout"] == "dwindle")
            move("B")
            event("press 272")
            event("release 272")
            assert log("B") == "press 2\nrelease 2\npress 1\nrelease 1\n", log("B")
            print("PASS: clicks on non-Stage workspaces reach the app normally")
            assert not ctl("configerrors"), ctl("configerrors")
        finally:
            if pointer:
                pointer.stdin.close()
                pointer.wait(timeout=5)
            for process in processes:
                process.terminate()
                process.wait(timeout=5)
            compositor.terminate()
            compositor.wait(timeout=10)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--protocol", required=True, type=Path,
                        help="Path to wlr-virtual-pointer-unstable-v1.xml")
    parser.add_argument("--plugin", type=Path,
                        default=REPO / "hypr/stagethumbs/stagethumbs.so")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="stage-click-test-") as directory:
        root = Path(directory)
        try:
            run(root, args.protocol.resolve(), args.plugin.resolve())
        except Exception:
            log = root / "compositor.log"
            if log.exists():
                print(log.read_text()[-4000:])
            raise
