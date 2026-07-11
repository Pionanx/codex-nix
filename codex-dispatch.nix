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
  codex [OPTIONS] [NIX_MODE] [-- CODEX_ARGS...]
  codex --unwrapped [CODEX_ARGS...]
  codex bwrap [OPTIONS] [NIX_MODE] [-- CODEX_ARGS...]

Default behavior:
  codex                       Run Codex in a read-only workspace sandbox.
  codex --unwrapped            Run the upstream Codex binary without bwrap.

Bwrap options:
  --write                      Mount the workspace read-write.
  --memory SIZE                Set systemd MemoryMax (default: 8G).
  --cpu PERCENT                Set systemd CPUQuota (default: 200%).
  --tasks COUNT                Set systemd TasksMax (default: 512).
  --disable-nested-userns      Experimental: disable nested user namespaces.
  --allow-dir PATH             Mount PATH read-write at its original path (repeatable).
  --allow-home                 Mount the invoking user's home directory read-write.
  --all-dirs                   Mount the host filesystem read-write.
  -h, --help                   Show this help.

Nix modes:
  --full                       Read-only mount of the full /nix/store.
  --nixpkgs PKG... --          Start through nix shell with nixpkgs packages.
  --flake [INSTALLABLE] --     Start through nix develop (default: .).

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
      local nixModeSet=0
      local flakeTargetSet=0
      local allowAllDirs=0
      local -a nixPackages=()
      local -a codexArgs=()
      local -a allowedDirs=()
      local -a wrapperArgs=()

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
          --allow-dir)
            requireValue "$@"
            allowedDirs+=("$2")
            shift 2
            ;;
          --allow-home)
            allowedDirs+=("$HOME")
            shift
            ;;
          --all-dirs)
            allowAllDirs=1
            shift
            ;;
          --full)
            if [ "$nixModeSet" = 1 ]; then
              echo "only one Nix mode may be selected" >&2
              exit 2
            fi
            nixModeSet=1
            shift
            ;;
          --nixpkgs)
            if [ "$nixModeSet" = 1 ]; then
              echo "only one Nix mode may be selected" >&2
              exit 2
            fi
            nixMode=nixpkgs
            nixModeSet=1
            shift
            ;;
          --flake)
            if [ "$nixModeSet" = 1 ]; then
              echo "only one Nix mode may be selected" >&2
              exit 2
            fi
            nixMode=flake
            nixModeSet=1
            shift
            ;;
          nix)
            case "''${2:-}" in
              --full|--nixpkgs|--flake)
                echo "'codex nix ...' was removed; use the Nix mode option directly" >&2
                exit 2
                ;;
            esac
            codexArgs=("$@")
            break
            ;;
          -h|--help)
            printBwrapHelp
            exit 0
            ;;
          --)
            shift
            codexArgs=("$@")
            break
            ;;
          *)
            case "$nixMode" in
              full)
                codexArgs=("$@")
                break
                ;;
              nixpkgs)
                nixPackages+=("nixpkgs#$1")
                shift
                ;;
              flake)
                if [ "$flakeTargetSet" = 0 ]; then
                  flakeTarget="$1"
                  flakeTargetSet=1
                  shift
                else
                  codexArgs=("$@")
                  break
                fi
                ;;
            esac
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

      if [ "$allowAllDirs" = 1 ] && [ "''${#allowedDirs[@]}" -gt 0 ]; then
        echo "--all-dirs cannot be combined with --allow-dir or --allow-home" >&2
        exit 2
      fi

      if [ "$allowAllDirs" = 1 ]; then
        wrapperArgs=(--all-dirs)
      else
        for allowedDir in "''${allowedDirs[@]}"; do
          wrapperArgs+=(--allow-dir "$allowedDir")
        done
      fi

      case "$nixMode" in
        full)
          runBwrap "$wrapper" "''${wrapperArgs[@]}" -- "''${codexArgs[@]}"
          ;;
        nixpkgs)
          if [ "''${#nixPackages[@]}" -eq 0 ]; then
            echo "--nixpkgs requires at least one package" >&2
            exit 2
          fi

          exec ${lib.getExe nix} --extra-experimental-features "nix-command flakes" shell "''${nixPackages[@]}" --command \
            ${coreutils}/bin/env \
            CODEX_BWRAP_MEMORY_MAX="$memoryMax" \
            CODEX_BWRAP_CPU_QUOTA="$cpuQuota" \
            CODEX_BWRAP_TASKS_MAX="$tasksMax" \
            CODEX_BWRAP_DISABLE_NESTED_USERNS="$disableNestedUserns" \
            CODEX_BWRAP_IMPORT_DEV_ENV=0 \
            "$wrapper" "''${wrapperArgs[@]}" -- "''${codexArgs[@]}"
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
            "$wrapper" "''${wrapperArgs[@]}" -- "''${codexArgs[@]}"
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
