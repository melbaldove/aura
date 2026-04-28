{
  description = "Aura development environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          fixEsqliteNif = pkgs.writeShellScriptBin "aura-fix-esqlite-nif" ''
            set -euo pipefail

            nif_dir="''${PWD}/build/dev/erlang/esqlite/ebin"
            if [ ! -d "$nif_dir" ]; then
              echo "esqlite build directory not found. Run gleam build or gleam test first." >&2
              exit 1
            fi

            cd "$nif_dir"
            erlc -o . ../src/esqlite3.erl ../src/esqlite3_nif.erl
          '';
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.gleam
              pkgs.erlang_27
              pkgs.rebar3
              pkgs.gnumake
              pkgs.pkg-config
              pkgs.stdenv.cc
              pkgs.sqlite
              pkgs.tmux
              pkgs.nodejs_22
              fixEsqliteNif
            ];

            shellHook = ''
              otp_version="$(erl -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().')"
              echo "Aura dev shell: Gleam $(gleam --version | awk '{print $2}'), OTP $otp_version"
              echo "If esqlite reports a corrupt atom table after gleam clean, run: aura-fix-esqlite-nif"
            '';
          };
        }
      );
    };
}
