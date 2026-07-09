{
  pkgs,
  mist,
}:
pkgs.mkShell {
  inputsFrom = [ mist ];

  nativeBuildInputs = with pkgs; [
    just
    imagemagick
    wireplumber
  ];

  shellHook = ''
    echo " Mist dev-shell | 'just --list' to see available tasks"
  '';
}
