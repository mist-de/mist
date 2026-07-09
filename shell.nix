{ pkgs ? import <nixpkgs> { } }:

pkgs.mkShell {
  buildInputs = with pkgs; [
    just
    zig
    zls
    wayland
    wayland-scanner
    wayland-protocols
    libxkbcommon
    freetype
    harfbuzz
    basu
    imagemagick
    wireplumber
  ];

  WAYLAND_XML = "${pkgs.wayland-scanner}/share/wayland/wayland.xml";
  WAYLAND_PROTOCOLS = "${pkgs.wayland-protocols}/share/wayland-protocols";

  shellHook = ''
    echo "Mist DE development shell"
    echo "Zig $(zig version)"
    echo ""
    echo "Run: zig build -Doptimize=ReleaseFast -- -lwayland-client -lxkbcommon -lfreetype -lharfbuzz"
    echo "Then: ./zig-out/bin/mist-bar"
  '';
}
