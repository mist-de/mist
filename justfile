# Mist — build + install
#
# On NixOS: enter nix-shell first, then use just
# On other distros: just works directly
#
#   just               # list commands
#   just build         # debug build
#   just build-release # release build
#   just run           # debug build + run
#   just install       # cp zig-out/bin/mist → /usr/local/bin (sudo)

prefix := "/usr/local"

default:
    @just --list

# Build (debug)
build:
    zig build -Doptimize=Debug

# Build release
build-release:
    zig build -Doptimize=ReleaseFast

# Install last built binary to prefix
install:
    cp zig-out/bin/mist "{{prefix}}/bin/mist"
    echo "installed to {{prefix}}/bin/mist"

# Build release + install (run sudo + just outside nix-shell)
install-release: build-release install

# Build + run (debug)
run: build
    ./zig-out/bin/mist

# Build + run (release)
run-release: build-release
    ./zig-out/bin/mist

# Clean
clean:
    rm -rf zig-out .zig-cache

# Show zig version
version:
    @zig version
