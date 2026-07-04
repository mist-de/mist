# Mist

Featherlight Wayland shell. Compositor-agnostic bar, launcher, notifications, OSD, lockscreen.

## Build

### NixOS

```bash
nix-shell shell.nix
zig build
# Run on MangoWM :
mango -- zig-out/bin/mist-shell
# Run on River:
river -c "zig-out/bin/mist-shell"
```

### Other distros

```bash
# Dependencies: zig 0.16.0, wayland-client, freetype2, harfbuzz,
#               basu (sd-bus), xkbcommon, fontconfig, wayland-scanner,
#               wayland-protocols, pkg-config
PKG_CONFIG_PATH=/path/to/pkgs zig build
./zig-out/bin/mist-shell
```

Tested on MangoWM, River. No systemd dependency — uses basu (sd-bus fork) for D-Bus.

## License

GPL-3.0-only
