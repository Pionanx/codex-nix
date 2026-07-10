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
          isLinux = pkgs.stdenv.hostPlatform.isLinux;
          codexUnwrapped = pkgs.callPackage ./package.nix { };
          mkBwrap =
            {
              name,
              workspaceWritable,
              storeMode,
            }:
            pkgs.callPackage ./codex-bwrap.nix {
              codex = codexUnwrapped;
              inherit name workspaceWritable storeMode;
            };
          codexBwrap = mkBwrap {
            name = "codex-bwrap";
            workspaceWritable = true;
            storeMode = "full";
          };
          codexBwrapRo = mkBwrap {
            name = "codex-bwrap-ro";
            workspaceWritable = false;
            storeMode = "full";
          };
          codexBwrapClosure = mkBwrap {
            name = "codex-bwrap-closure";
            workspaceWritable = true;
            storeMode = "closure";
          };
          codexBwrapClosureRo = mkBwrap {
            name = "codex-bwrap-closure-ro";
            workspaceWritable = false;
            storeMode = "closure";
          };
          codex =
            if isLinux then
              pkgs.callPackage ./codex-dispatch.nix {
                inherit
                  codexUnwrapped
                  codexBwrapRo
                  codexBwrapClosureRo
                  ;
                codexBwrapRw = codexBwrap;
                codexBwrapClosureRw = codexBwrapClosure;
              }
            else
              codexUnwrapped;
        in
        {
          packages =
            {
              default = codex;
              inherit codex;
              "codex-unwrapped" = codexUnwrapped;
            }
            // lib.optionalAttrs isLinux {
              "codex-bwrap" = codexBwrap;
              "codex-bwrap-ro" = codexBwrapRo;
              "codex-bwrap-closure" = codexBwrapClosure;
              "codex-bwrap-closure-ro" = codexBwrapClosureRo;
            };

          apps.default = {
            type = "app";
            program = "${codex}/bin/codex";
            meta.description = "OpenAI Codex CLI";
          };

          checks = {
            package = codexUnwrapped;
            version =
              pkgs.runCommand "codex-version-${codexUnwrapped.version}"
                {
                  nativeBuildInputs = [ codexUnwrapped ];
                }
                ''
                  actual="$(codex --version 2>/dev/null)"
                  expected="codex-cli ${codexUnwrapped.version}"

                  if [ "$actual" != "$expected" ]; then
                    echo "expected '$expected', got '$actual'" >&2
                    exit 1
                  fi

                  HOME="$TMPDIR" codex --help >/dev/null 2>&1
                  touch "$out"
                '';
          }
          // lib.optionalAttrs isLinux {
            dispatcher =
              pkgs.runCommand "codex-dispatch-${codexUnwrapped.version}"
                {
                  nativeBuildInputs = [ codex ];
                }
                ''
                  HOME="$TMPDIR/home"
                  XDG_CONFIG_HOME="$TMPDIR/config"
                  mkdir -p "$HOME"

                  actual="$(codex --unwrapped --version 2>/dev/null)"
                  expected="codex-cli ${codexUnwrapped.version}"

                  if [ "$actual" != "$expected" ]; then
                    echo "expected '$expected', got '$actual'" >&2
                    exit 1
                  fi

                  codex bwrap --help >/dev/null
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
        overlays.default = final: _prev:
          let
            isLinux = _prev.stdenv.hostPlatform.isLinux;
            codexUnwrapped = _prev.callPackage ./package.nix { };
            mkBwrap =
              {
                name,
                workspaceWritable,
                storeMode,
              }:
              _prev.callPackage ./codex-bwrap.nix {
                codex = codexUnwrapped;
                inherit name workspaceWritable storeMode;
              };
            codexBwrap = mkBwrap {
              name = "codex-bwrap";
              workspaceWritable = true;
              storeMode = "full";
            };
            codexBwrapRo = mkBwrap {
              name = "codex-bwrap-ro";
              workspaceWritable = false;
              storeMode = "full";
            };
            codexBwrapClosure = mkBwrap {
              name = "codex-bwrap-closure";
              workspaceWritable = true;
              storeMode = "closure";
            };
            codexBwrapClosureRo = mkBwrap {
              name = "codex-bwrap-closure-ro";
              workspaceWritable = false;
              storeMode = "closure";
            };
            codex =
              if isLinux then
                _prev.callPackage ./codex-dispatch.nix {
                  inherit
                    codexUnwrapped
                    codexBwrapRo
                    codexBwrapClosureRo
                    ;
                  codexBwrapRw = codexBwrap;
                  codexBwrapClosureRw = codexBwrapClosure;
                }
              else
                codexUnwrapped;
          in
          {
            inherit codex;
            "codex-unwrapped" = codexUnwrapped;
          }
          // (if isLinux then {
            "codex-bwrap" = codexBwrap;
            "codex-bwrap-ro" = codexBwrapRo;
            "codex-bwrap-closure" = codexBwrapClosure;
            "codex-bwrap-closure-ro" = codexBwrapClosureRo;
          } else { });
      };
    };
}
