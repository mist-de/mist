{
  lib,
  stdenv,
  zig,
  wayland,
  wayland-scanner,
  wayland-protocols,
  libxkbcommon,
  freetype,
  harfbuzz,
  basu,
  imagemagick,
  wireplumber,
  fetchurl,
}:

let
  version = "0.1.0";

  # zig-wayland dependency — fetched ahead of time (sandbox has no network)
  # Zig stores the raw .tar.gz in its package cache, so fetchurl (not fetchzip)
  zig-wayland = fetchurl {
    url = "https://codeberg.org/ifreund/zig-wayland/archive/main.tar.gz";
    hash = "sha256-yV/Tzg8MtSwrj/n4wJXxbz2cJDjgBuqLXpY6KbjKvPo=";
  };
in
stdenv.mkDerivation {
  pname = "mist";
  inherit version;

  src = lib.cleanSource ./..;

  nativeBuildInputs = [ zig wayland-scanner ];

  buildInputs = [
    wayland
    wayland-protocols
    libxkbcommon
    freetype
    harfbuzz
    basu
  ];

  preBuild = ''
    mkdir -p .wayland-dep
    ln -sf ${wayland-scanner}/share/wayland/wayland.xml .wayland-dep/wayland.xml
    ln -sf ${wayland-protocols}/share/wayland-protocols .wayland-dep/protocols

    # Place zig-wayland in zig's package cache so it skips network fetch
    cache_dir="$TMPDIR/zig-cache"
    mkdir -p "$cache_dir/p"
    ln -sf ${zig-wayland} "$cache_dir/p/wayland-0.7.0-dev-lQa1kjT8AQDBstL61Gy3WCMtGwVaMN1p6w5wGfdDvP15.tar.gz"
    export ZIG_GLOBAL_CACHE_DIR="$cache_dir"
  '';

  buildPhase = ''
    runHook preBuild
    zig build -Doptimize=ReleaseFast
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/share/mist/fonts
    cp zig-out/bin/mist $out/bin/mist
    cp -r fonts/* $out/share/mist/fonts/
    runHook postInstall
  '';

  meta = with lib; {
    description = "A minimal Wayland desktop environment shell written in Zig";
    homepage = "https://github.com/mist-de/mist-shell";
    license = licenses.gpl3Only;
    platforms = platforms.linux;
    mainProgram = "mist";
  };
}
