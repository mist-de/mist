{ config, lib, pkgs, ... }:

let
  cfg = config.programs.mist;
in
{
  options.programs.mist = {
    enable = lib.mkEnableOption "Mist Wayland shell";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.mist;
      description = "Mist package to use";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];
  };
}
