{
  description = "Nix flake for Codex, OpenAI's coding agent for the terminal";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      perSystem =
        { pkgs, lib, ... }:
        let
          codex = pkgs.callPackage ./package.nix { };
          codexBwrap = pkgs.callPackage ./codex-bwrap.nix { inherit codex; };
        in
        {
          packages =
            {
              default = codex;
              inherit codex;
            }
            // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
              "codex-bwrap" = codexBwrap;
            };

          apps.default = {
            type = "app";
            program = "${codex}/bin/codex";
            meta.description = "OpenAI Codex CLI";
          };

          checks = {
            package = codex;
            version =
              pkgs.runCommand "codex-version-${codex.version}"
                {
                  nativeBuildInputs = [ codex ];
                }
                ''
                  actual="$(codex --version 2>/dev/null)"
                  expected="codex-cli ${codex.version}"

                  if [ "$actual" != "$expected" ]; then
                    echo "expected '$expected', got '$actual'" >&2
                    exit 1
                  fi

                  HOME="$TMPDIR" codex --help >/dev/null 2>&1
                  touch "$out"
                '';
          };

          devShells.default = pkgs.mkShellNoCC {
            packages = [
              codex
              pkgs.curl
              pkgs.jq
            ];
          };
        };

      flake = {
        overlays.default = final: _prev: {
          codex = final.callPackage ./package.nix { };
        };
      };
    };
}
