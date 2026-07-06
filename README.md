# Mist

![Zig](https://img.shields.io/badge/Zig-0.16.0-F7A41D?logo=zig&logoColor=white)
[![License: GPLv3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

> **Early development. Not stable.**

A minimal Wayland desktop environment shell written in Zig — inspired by [end-4](https://github.com/end-4/dots-hyprland). Pure software rendering via `wl_shm`. Zero GPU. Zero GLib.

- Pure CPU rendering — no GPU required
- Zero GLib dependencies — no GTK/GNOME baggage
- FreeType + HarfBuzz for text via @cImport (Ghostty pattern)
- ~530 KB stripped binary

## Quick Start

```sh
nix-shell                       # NixOS recommended
zig build -Doptimize=ReleaseFast -- -lwayland-client -lxkbcommon -lfreetype -lharfbuzz
./zig-out/bin/mist-bar
```

<details>
<summary>Dependencies by distro</summary>

**Debian / Ubuntu:**
```sh
sudo apt install libwayland-dev wayland-protocols libxkbcommon-dev \
  libfreetype-dev libharfbuzz-dev pkg-config zig
```

**Fedora:**
```sh
sudo dnf install wayland-devel wayland-protocols-devel libxkbcommon-devel \
  freetype-devel harfbuzz-devel pkg-config zig
```

**Arch Linux:**
```sh
sudo pacman -S wayland wayland-protocols libxkbcommon freetype2 harfbuzz pkgconf zig
```

**Void Linux:**
```sh
sudo xbps-install -S wayland-devel wayland-protocols libxkbcommon-devel \
  freetype-devel harfbuzz-devel pkg-config zig
```

**openSUSE:**
```sh
sudo zypper install wayland-devel wayland-protocols-devel libxkbcommon-devel \
  freetype2-devel harfbuzz-devel pkg-config zig
```

**NixOS:**
```sh
nix-shell --run "zig build -Doptimize=ReleaseFast -- -lwayland-client -lxkbcommon -lfreetype -lharfbuzz"
```

</details>

<details>
<summary>Build without nix-shell</summary>

```sh
export WAYLAND_XML=/usr/share/wayland/wayland.xml
export WAYLAND_PROTOCOLS=/usr/share/wayland-protocols
zig build -Doptimize=ReleaseFast -- -lwayland-client -lxkbcommon -lfreetype -lharfbuzz
```

</details>

## Repository

```
src/
├── main.zig     — entry point, registry sync, poll loop
├── bar.zig      — bar layout, draw, widgets
├── wl.zig       — Wayland context, layer surface, shm buffer
├── render.zig   — Canvas software renderer (ARGB8888)
├── config.zig   — hardcoded Catppuccin Mocha colors
├── seat.zig     — pointer / keyboard event stubs
├── output.zig   — per-output bar lifecycle
├── geometry.zig — Point, Rect, Size
├── color.zig    — Color with ARGB pixel conversion
└── util.zig     — BoundedArray generic
fonts/           — bundled Inter, NotoSans NF, JetBrainsMono NF, Material Symbols
build.zig        — wayland protocol scanner
```

## Compositor Support

Requires `wlr-layer-shell`, `ext-workspace-v1`, and `zwlr-foreign-toplevel-management-v1`. Only tested on:

| Compositor | Status |
|------------|--------|
| River      | Confirmed |
| MangoWM    | Confirmed (dwl-based) |

## Status

| Component | Status |
|-----------|--------|
| Wayland layer shell (wl_shm) | Working |
| Smoothstep AA rendering | Working |
| FreeType + HarfBuzz text | Working |
| M3 color palette | Working |
| Workspace indicators | Working (live via ext-workspace) |
| Active window tracking | Working (live via zwlr-foreign-toplevel) |
| Mouse input (click workspace/activate) | Working |
| Resource rings | Working (live /proc) |
| D-Bus services | Not implemented |
| Auto-hide | Not implemented |
| Popups / tooltips | Not implemented |
| Config file parsing | Not implemented |

## License

GPLv3 — see [LICENSE](LICENSE).
