# Mist

![Zig](https://img.shields.io/badge/Zig-0.16.0-F7A41D?logo=zig&logoColor=white)
[![License: GPLv3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

> **Early development. Not stable.**

A minimal Wayland desktop environment shell written in Zig — inspired by [end-4](https://github.com/end-4/dots-hyprland). Pure software rendering via `wl_shm`. Zero GPU. Zero GLib.

- Pure CPU rendering — no GPU required
- Zero GLib dependencies — no GTK/GNOME baggage
- FreeType + HarfBuzz for text via @cImport
- MPRIS media detection via basu
- Album art via ImageMagick (convert)
- Audio control via WirePlumber (wpctl)

## Quick Start

**Any distro:**
```sh
just build-release
sudo cp zig-out/bin/mist /usr/local/bin/mist
mist
```

<details>
<summary>Installation</summary>

**Install dependencies:**
```sh
# Debian / Ubuntu
sudo apt install libwayland-dev wayland-protocols libxkbcommon-dev \
  libfreetype-dev libharfbuzz-dev libbasu-dev imagemagick wireplumber zig

# Fedora
sudo dnf install wayland-devel wayland-protocols-devel libxkbcommon-devel \
  freetype-devel harfbuzz-devel basu-devel imagemagick wireplumber zig

# Arch Linux
sudo pacman -S wayland wayland-protocols libxkbcommon freetype2 harfbuzz basu \
  imagemagick wireplumber zig

# Void Linux
sudo xbps-install -S wayland-devel wayland-protocols libxkbcommon-devel \
  freetype-devel harfbuzz-devel basu-devel imagemagick wireplumber zig

# openSUSE
sudo zypper install wayland-devel wayland-protocols-devel libxkbcommon-devel \
  freetype2-devel harfbuzz-devel basu-devel imagemagick wireplumber zig
```

**NixOS (flake):**
```nix
{
  inputs.mist-shell.url = "github:mist-de/mist-shell";

  outputs = { self, nixpkgs, mist-shell, ... }: {
    nixosConfigurations.mybox = nixpkgs.lib.nixosSystem {
      modules = [
        mist-shell.nixosModules.default
        { programs.mist.enable = true; }
      ];
    };
  };
}
```

**NixOS (legacy shell):**
```sh
nix-shell
just build-release
sudo cp zig-out/bin/mist /usr/local/bin/mist
```

**Without just:**
```sh
ln -s /usr/share/wayland/wayland.xml .wayland-dep/wayland.xml
ln -s /usr/share/wayland-protocols .wayland-dep/protocols
zig build -Doptimize=ReleaseFast
sudo cp zig-out/bin/mist /usr/local/bin/mist
```

</details>

## Compositor Support

Requires `wlr-layer-shell`, `ext-workspace-v1`, and `zwlr-foreign-toplevel-management-v1`. Only tested on:

| Compositor | Status |
|------------|--------|
| River      | Confirmed |
| MangoWM    | Confirmed (dwl-based) |

## IPC (Remote Control)

Mist exposes a Unix socket for external control. Uses the same `mist` binary — no separate tool required.

```sh
# Drop-in replacement: auto-starts daemon if not running
mist msg call status            → full JSON state
mist msg call clock             → 18:24:26
mist msg call resources         → cpu/memory/swap/battery
```

<details>
<summary>All IPC commands (37)</summary>

| Command | Description |
|---------|-------------|
| `status` | Print all state as JSON |
| `volume-get` | Current audio volume |
| `volume-up` | Increase volume by 5% |
| `volume-down` | Decrease volume by 5% |
| `volume-mute` | Mute audio |
| `volume-unmute` | Unmute audio |
| `volume-toggle` | Toggle mute |
| `mic-get` | Current mic volume |
| `mic-up` | Increase mic volume by 5% |
| `mic-down` | Decrease mic volume by 5% |
| `mic-mute` | Mute mic |
| `mic-unmute` | Unmute mic |
| `mic-toggle` | Toggle mic mute |
| `media-play-pause` | Play/pause media |
| `media-next` | Next track |
| `media-previous` | Previous track |
| `workspace-switch <N>` | Switch to workspace |
| `workspace-next` | Next workspace |
| `workspace-previous` | Previous workspace |
| `sidebar-toggle` | Toggle sidebar |
| `sidebar-show` | Show sidebar |
| `sidebar-hide` | Hide sidebar |
| `sidebar-get` | Sidebar visibility |
| `popup-toggle` | Toggle media popup |
| `popup-show` | Show media popup |
| `popup-hide` | Hide media popup |
| `notification-count` | Count notifications |
| `notification-status` | Summary (count + unread) |
| `notification-dismiss <id>` | Dismiss by ID |
| `notification-dismiss-all` | Dismiss all |
| `notification-mark-all-read` | Mark all read |
| `notification-dnd-set <on\|off>` | Set DND |
| `notification-dnd-toggle` | Toggle DND |
| `notification-dnd-status` | Get DND state |
| `clock` | Current time |
| `resources` | CPU/memory/swap/battery |

</details>

### Auto-start

`mist msg` auto-launches the daemon if it's not running. In your compositor config:

```
# MangoWM / River / dwl
exec-once = mist

# Niri
spawn-at-startup "mist"

# From terminal
mist msg call volume-up
mist msg call media-play-pause
mist msg call workspace-next
```

### Hot-reload

Mist watches its own binary. After building, replace the binary and it auto-restarts:

```sh
sudo cp zig-out/bin/mist /usr/local/bin/mist   # triggers restart in ≤3s
```

No manual restart needed.

## Status

| Component | Status |
|-----------|--------|
| Wayland layer shell (wl_shm) | Working |
| Smoothstep AA rendering | Working |
| FreeType + HarfBuzz text | Working |
| M3 color palette | Working |
| Workspace indicators | Working (live via ext-workspace) |
| Active window tracking | Working (live via zwlr-foreign-toplevel) |
| Mouse input (click workspace/scroll) | Working |
| Resource rings | Working (live /proc) |
| MPRIS media detection | Working (D-Bus via basu) |
| Media controls popup (album art, prev/play/next) | Working |
| Album art (file:// via ImageMagick, HTTPS via curl) | Working |
| Audio volume indicator (capsule + scroll) | Working |
| IPC server (Unix socket, 37 commands) | Working |
| Auto-start on `mist msg` | Working |
| Hot-reload on rebuild | Working |
| Auto-hide | Not implemented |
| Config file parsing | Not implemented |

## License

GPLv3 — see [LICENSE](LICENSE).
