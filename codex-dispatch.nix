{
  lib,
  writeShellApplication,
  coreutils,
  nix,
  codexUnwrapped,
  codexBwrapRo,
  codexBwrapRw,
  codexBwrapClosureRo,
  codexBwrapClosureRw,
}:

writeShellApplication {
  name = "codex";
  runtimeInputs = [ coreutils nix ];

  text = ''
    printBwrapHelp() {
      cat <<'EOF'
Usage:
  codex [CODEX_ARGS...]
  codex --unwrapped [CODEX_ARGS...]
  codex bwrap [OPTIONS] [nix MODE] [-- CODEX_ARGS...]

Default behavior:
  codex                       Run Codex in a read-only workspace sandbox.
  codex --unwrapped            Run the upstream Codex binary without bwrap.

Bwrap options:
  --write                      Mount the workspace read-write.
  --memory SIZE                Set systemd MemoryMax (default: 8G).
  --cpu PERCENT                Set systemd CPUQuota (default: 200%).
  --tasks COUNT                Set systemd TasksMax (default: 512).
  --disable-nested-userns      Experimental: disable nested user namespaces.
  -h, --help                   Show this help.

Nix modes:
  nix --full                   Read-only mount of the full /nix/store.
  nix --nixpkgs PKG... --      Start through nix shell with nixpkgs packages.
  nix --flake [INSTALLABLE] -- Start through nix develop (default: .).

Use -- to separate bwrap or Nix options from upstream Codex arguments.
EOF
    }

    ensureCodexHome() {
      if [ -z "''${HOME:-}" ]; then
        echo "HOME must be set" >&2
        exit 2
      fi

      hostXdgConfigHome="''${XDG_CONFIG_HOME:-$HOME/.config}"
      case "$hostXdgConfigHome" in
        /*) ;;
        *)
          echo "XDG_CONFIG_HOME must be an absolute path" >&2
          exit 2
          ;;
      esac

      hostCodexHome="$hostXdgConfigHome/codex"
      legacyCodexHome="$HOME/.codex"
      if [ -e "$legacyCodexHome" ] && [ ! -e "$hostCodexHome" ]; then
        mkdir -p "$(dirname "$hostCodexHome")"
        mv "$legacyCodexHome" "$hostCodexHome"
      elif [ -e "$legacyCodexHome" ] && [ -e "$hostCodexHome" ] && [ "$(realpath -e "$legacyCodexHome")" != "$(realpath -e "$hostCodexHome")" ]; then
        echo "both $legacyCodexHome and $hostCodexHome exist; merge them manually before running codex" >&2
        exit 2
      fi

      mkdir -p "$hostCodexHome"
      CODEX_HOME="$(realpath -e "$hostCodexHome")"
      export CODEX_HOME
    }

    requireValue() {
      if [ "$#" -lt 2 ]; then
        echo "missing value for $1" >&2
        exit 2
      fi
    }

    runBwrap() {
      local wrapper="$1"
      shift

      exec ${coreutils}/bin/env \
        CODEX_BWRAP_MEMORY_MAX="$memoryMax" \
        CODEX_BWRAP_CPU_QUOTA="$cpuQuota" \
        CODEX_BWRAP_TASKS_MAX="$tasksMax" \
        CODEX_BWRAP_DISABLE_NESTED_USERNS="$disableNestedUserns" \
        CODEX_BWRAP_IMPORT_DEV_ENV="$importDevEnv" \
        "$wrapper" "$@"
    }

    runBwrapCommand() {
      local writable=0
      local nixMode=full
      local flakeTarget=.
      local memoryMax="''${CODEX_BWRAP_MEMORY_MAX:-8G}"
      local cpuQuota="''${CODEX_BWRAP_CPU_QUOTA:-200%}"
      local tasksMax="''${CODEX_BWRAP_TASKS_MAX:-512}"
      local disableNestedUserns=0
      local importDevEnv=0
      local wrapper
      local -a nixPackages=()
      local -a codexArgs=()

      while [ "$#" -gt 0 ]; do
        case "$1" in
          --write)
            writable=1
            shift
            ;;
          --memory)
            requireValue "$@"
            memoryMax="$2"
            shift 2
            ;;
          --cpu)
            requireValue "$@"
            cpuQuota="$2"
            shift 2
            ;;
          --tasks)
            requireValue "$@"
            tasksMax="$2"
            shift 2
            ;;
          --disable-nested-userns)
            disableNestedUserns=1
            shift
            ;;
          -h|--help)
            printBwrapHelp
            exit 0
            ;;
          nix)
            shift
            case "''${1:-}" in
              --full)
                nixMode=full
                shift
                ;;
              --nixpkgs)
                nixMode=nixpkgs
                shift
                while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
                  nixPackages+=("nixpkgs#$1")
                  shift
                done
                if [ "''${1:-}" = -- ]; then
                  shift
                fi
                codexArgs=("$@")
                break
                ;;
              --flake)
                nixMode=flake
                shift
                if [ "$#" -gt 0 ] && [ "$1" != -- ]; then
                  flakeTarget="$1"
                  shift
                fi
                if [ "''${1:-}" = -- ]; then
                  shift
                fi
                codexArgs=("$@")
                break
                ;;
              *)
                echo "expected --full, --nixpkgs, or --flake after 'nix'" >&2
                exit 2
                ;;
            esac
            ;;
          --)
            shift
            codexArgs=("$@")
            break
            ;;
          *)
            codexArgs=("$@")
            break
            ;;
        esac
      done

      if [ "$writable" = 1 ]; then
        if [ "$nixMode" = full ]; then
          wrapper=${lib.getExe codexBwrapRw}
        else
          wrapper=${lib.getExe codexBwrapClosureRw}
        fi
      else
        if [ "$nixMode" = full ]; then
          wrapper=${lib.getExe codexBwrapRo}
        else
          wrapper=${lib.getExe codexBwrapClosureRo}
        fi
      fi

      case "$nixMode" in
        full)
          runBwrap "$wrapper" "''${codexArgs[@]}"
          ;;
        nixpkgs)
          if [ "''${#nixPackages[@]}" -eq 0 ]; then
            echo "nix --nixpkgs requires at least one package" >&2
            exit 2
          fi

          exec ${lib.getExe nix} --extra-experimental-features "nix-command flakes" shell "''${nixPackages[@]}" --command \
            ${coreutils}/bin/env \
            CODEX_BWRAP_MEMORY_MAX="$memoryMax" \
            CODEX_BWRAP_CPU_QUOTA="$cpuQuota" \
            CODEX_BWRAP_TASKS_MAX="$tasksMax" \
            CODEX_BWRAP_DISABLE_NESTED_USERNS="$disableNestedUserns" \
            CODEX_BWRAP_IMPORT_DEV_ENV=0 \
            "$wrapper" "''${codexArgs[@]}"
          ;;
        flake)
          importDevEnv=1
          exec ${lib.getExe nix} --extra-experimental-features "nix-command flakes" develop "$flakeTarget" --command \
            ${coreutils}/bin/env \
            CODEX_BWRAP_MEMORY_MAX="$memoryMax" \
            CODEX_BWRAP_CPU_QUOTA="$cpuQuota" \
            CODEX_BWRAP_TASKS_MAX="$tasksMax" \
            CODEX_BWRAP_DISABLE_NESTED_USERNS="$disableNestedUserns" \
            CODEX_BWRAP_IMPORT_DEV_ENV="$importDevEnv" \
            "$wrapper" "''${codexArgs[@]}"
          ;;
      esac
    }

    ensureCodexHome

    case "''${1:-}" in
      --unwrapped)
        shift
        exec ${coreutils}/bin/env CODEX_HOME="$CODEX_HOME" ${lib.getExe codexUnwrapped} "$@"
        ;;
      --help|-h)
        printBwrapHelp
        exit 0
        ;;
      help)
        if [ "''${2:-}" = bwrap ]; then
          printBwrapHelp
          exit 0
        fi
        runBwrapCommand "$@"
        ;;
      bwrap)
        shift
        runBwrapCommand "$@"
        ;;
      *)
        runBwrapCommand "$@"
        ;;
    esac
  '';

  meta = {
    description = "Codex dispatcher with Bubblewrap workspace modes";
    homepage = "https://github.com/Pionanx/codex-nix";
    license = lib.licenses.asl20;
    platforms = lib.platforms.linux;
    mainProgram = "codex";
  };
}
