# Mist

> **Early development. Not stable. Expect rendering issues.**

A minimal Wayland desktop environment shell written in Zig. Pure software rendering via wl_shm. Zero GPU. Zero GLib.

Inspired by [end-4](https://github.com/end-4/dots), rewritten from scratch.

## Build

```sh
# NixOS (recommended)
nix-shell --run "zig build -Doptimize=ReleaseFast -- -lwayland-client -lxkbcommon -lfreetype -lharfbuzz"
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
<summary>Build from source (without nix-shell)</summary>

The build system uses environment variables (`WAYLAND_XML`, `WAYLAND_PROTOCOLS`) set by `nix-shell`. For non-Nix builds, set these manually:

```sh
export WAYLAND_XML=/usr/share/wayland/wayland.xml
export WAYLAND_PROTOCOLS=/usr/share/wayland-protocols
zig build -Doptimize=ReleaseFast -- -lwayland-client -lxkbcommon -lfreetype -lharfbuzz
```

</details>

## Compositor Support

| Compositor | Status |
|------------|--------|
| MangoWM | Supported (ext-workspace + zwlr-foreign-toplevel) |
| River | Supported (layer-shell + foreign-toplevel) |
| Sway | Supported (layer-shell + foreign-toplevel) |
| Hyprland | Supported (layer-shell + foreign-toplevel) |
| Labwc | Supported (layer-shell + foreign-toplevel) |

MangoWM users: workspace clicks switch tags, window title clicks activate windows.

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
| Resource rings | Working (placeholder data) |
| D-Bus services | Not implemented |
| Auto-hide | Not implemented |
| Popups / tooltips | Not implemented |
| Config file parsing | Not implemented |

## Design

- **Zero GPU** — pure wl_shm software rendering
- **Zero GLib** — no GTK, no GNOME dependencies
- **Minimal** — target 1-2 MB stripped binary

## Fonts

Bundled in `fonts/`: Inter, NotoSans Nerd Font, JetBrains Mono Nerd Font, Material Symbols Rounded.

<details>
<summary>Architecture</summary>

```
src/
├── main.zig          Entry point, event loop
├── wl.zig            Wayland context, layer surfaces, SHM buffers, protocol listeners
├── bar.zig           Bar layout, widget rendering (left/center/right sections)
├── render.zig        Pixel-level canvas with smoothstep AA
├── font.zig          FreeType glyph rendering, cache
├── text.zig          HarfBuzz text shaping, compositing
├── config.zig        Configuration, font paths
├── seat.zig          Pointer/keyboard input, click dispatch
├── output.zig        Output lifecycle, bar per-monitor
├── geometry.zig      Point, Rect, Size types
├── color.zig         ARGB color, premultiplied alpha
├── util.zig          BoundedArray generic
├── c.zig             @cImport bridge for FreeType + HarfBuzz
└── tr.h              Minimal C header for text rendering
```

</details>
