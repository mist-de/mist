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
    home.packages = [ cfg.package ];

    systemd.user.services.mist = {
      Unit = {
        Description = "Mist Wayland shell";
        PartOf = [ "graphical-session.target" ];
      };

      Service = {
        Type = "simple";
        ExecStart = "${cfg.package}/bin/mist";
        Restart = "on-failure";
      };

      Install = {
        WantedBy = [ "graphical-session.target" ];
      };
    };
  };
}
