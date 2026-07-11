{
  lib,
  writeShellApplication,
  closureInfo,
  bubblewrap,
  bash,
  cacert,
  coreutils,
  diffutils,
  findutils,
  gawk,
  git,
  gnugrep,
  gnused,
  nix,
  ripgrep,
  systemd,
  codex,
  name ? "codex-bwrap",
  workspaceWritable ? true,
  storeMode ? "full",
}:

assert lib.elem storeMode [ "full" "closure" ];

let
  baseRuntimePackages = [
    bash
    bubblewrap
    cacert
    coreutils
    diffutils
    findutils
    gawk
    git
    gnugrep
    gnused
    ripgrep
    systemd
    codex
  ];

  runtimePackages = baseRuntimePackages ++ lib.optionals (storeMode == "closure") [ nix ];
  runtimeClosure = closureInfo { rootPaths = runtimePackages; };
  sandboxPath = lib.makeBinPath runtimePackages;
  certificateBundle = "${cacert}/etc/ssl/certs/ca-bundle.crt";
  workspaceMount = if workspaceWritable then "--bind" else "--ro-bind";
in
writeShellApplication {
  inherit name;
  runtimeInputs = runtimePackages;

  text = ''
    workspace="$(pwd -P)"

    if [ "$workspace" = / ]; then
      echo "${name} must be started from a directory below /" >&2
      exit 2
    fi

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
      echo "both $legacyCodexHome and $hostCodexHome exist; merge them manually before running ${name}" >&2
      exit 2
    fi

    mkdir -p "$hostCodexHome"
    hostCodexHome="$(realpath -e "$hostCodexHome")"

    requireValue() {
      if [ "$#" -lt 2 ]; then
        echo "missing value for $1" >&2
        exit 2
      fi
    }

    addAllowedDirectory() {
      local directory="$1"

      case "$directory" in
        /*) ;;
        *)
          echo "--allow-dir requires an absolute path" >&2
          exit 2
          ;;
      esac

      if [ ! -d "$directory" ]; then
        echo "--allow-dir must name an existing directory: $directory" >&2
        exit 2
      fi

      allowedDirs+=("$(realpath -e "$directory")")
    }

    allowAllDirs=0
    declare -a allowedDirs=()
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --allow-dir)
          requireValue "$@"
          addAllowedDirectory "$2"
          shift 2
          ;;
        --allow-home)
          addAllowedDirectory "$HOME"
          shift
          ;;
        --all-dirs)
          allowAllDirs=1
          shift
          ;;
        --)
          shift
          break
          ;;
        *)
          break
          ;;
      esac
    done

    if [ "$allowAllDirs" = 1 ] && [ "''${#allowedDirs[@]}" -gt 0 ]; then
      echo "--all-dirs cannot be combined with --allow-dir or --allow-home" >&2
      exit 2
    fi

    if [ "$allowAllDirs" = 1 ]; then
      hostXdgDataHome="''${XDG_DATA_HOME:-$HOME/.local/share}"
      hostXdgStateHome="''${XDG_STATE_HOME:-$HOME/.local/state}"
      hostXdgCacheHome="''${XDG_CACHE_HOME:-$HOME/.cache}"

      bwrapArgs=(
        --unshare-all
        --share-net
        --die-with-parent
        --new-session
        --cap-drop ALL
        --clearenv
        --hostname codex-bwrap
        --setenv HOME "$HOME"
        --setenv CODEX_HOME "$hostCodexHome"
        --setenv XDG_CONFIG_HOME "$hostXdgConfigHome"
        --setenv XDG_DATA_HOME "$hostXdgDataHome"
        --setenv XDG_STATE_HOME "$hostXdgStateHome"
        --setenv XDG_CACHE_HOME "$hostXdgCacheHome"
        --setenv TMPDIR "''${TMPDIR:-/tmp}"
        --setenv SSL_CERT_FILE ${certificateBundle}
        --setenv NIX_SSL_CERT_FILE ${certificateBundle}
        --setenv TERM "''${TERM:-xterm-256color}"
        --bind / /
        --bind "$workspace" /workspace
        --proc /proc
        --dev /dev
      )
    else
      bwrapArgs=(
        --unshare-all
        --share-net
        --die-with-parent
        --new-session
        --cap-drop ALL
        --clearenv
        --hostname codex-bwrap
        --setenv HOME /home/codex
        --setenv CODEX_HOME /home/codex/.config/codex
        --setenv XDG_CONFIG_HOME /home/codex/.config
        --setenv XDG_DATA_HOME /home/codex/.local/share
        --setenv XDG_STATE_HOME /home/codex/.local/state
        --setenv XDG_CACHE_HOME /tmp/codex-cache
        --setenv TMPDIR /tmp
        --setenv SSL_CERT_FILE ${certificateBundle}
        --setenv NIX_SSL_CERT_FILE ${certificateBundle}
        --setenv TERM "''${TERM:-xterm-256color}"
        --dir /nix
        --dir /nix/store
        --dir /workspace
        ${workspaceMount} "$workspace" /workspace
        --dir /home
        --dir /home/codex
        --dir /home/codex/.config
        --bind "$hostCodexHome" /home/codex/.config/codex
        --dir /home/codex/.local
        --dir /home/codex/.local/share
        --dir /home/codex/.local/state
        --dir /etc
        --ro-bind-try /etc/resolv.conf /etc/resolv.conf
        --proc /proc
        --dev /dev
        --tmpfs /tmp
        --dir /bin
        --dir /usr
        --dir /usr/bin
        --symlink ${bash}/bin/bash /bin/bash
        --symlink ${bash}/bin/sh /bin/sh
        --symlink ${bash}/bin/bash /usr/bin/bash
        --symlink ${coreutils}/bin/env /usr/bin/env
      )

      declare -A sandboxDirectories=(
        [/nix]=1
        [/nix/store]=1
        [/workspace]=1
        [/home]=1
        [/home/codex]=1
        [/home/codex/.config]=1
        [/home/codex/.local]=1
        [/home/codex/.local/share]=1
        [/home/codex/.local/state]=1
        [/etc]=1
        [/bin]=1
        [/usr]=1
        [/usr/bin]=1
        [/tmp]=1
      )

      addSandboxDirectoryParents() {
        local directory="$1"
        local parent
        local index
        local -a parents=()

        parent="$(dirname "$directory")"
        while [ "$parent" != / ]; do
          parents+=("$parent")
          parent="$(dirname "$parent")"
        done

        for ((index = ''${#parents[@]} - 1; index >= 0; index--)); do
          parent="''${parents[$index]}"
          if [ -z "''${sandboxDirectories[$parent]+x}" ]; then
            bwrapArgs+=(--dir "$parent")
            sandboxDirectories["$parent"]=1
          fi
        done
      }

      for allowedDir in "''${allowedDirs[@]}"; do
        addSandboxDirectoryParents "$allowedDir"
        bwrapArgs+=(--bind "$allowedDir" "$allowedDir")
      done
    fi

    if [ "''${CODEX_BWRAP_DISABLE_NESTED_USERNS:-0}" = 1 ]; then
      bwrapArgs+=(--disable-userns)
    fi

    ${
      if storeMode == "full" then
        ''
          if [ "$allowAllDirs" = 0 ]; then
            bwrapArgs+=(--ro-bind /nix/store /nix/store)
          fi
        ''
      else
        ''
          declare -A mountedStorePaths=()

          mountStorePath() {
            local storePath="$1"

            [ "$allowAllDirs" = 0 ] || return 0

            if [ -z "''${mountedStorePaths[$storePath]+x}" ]; then
              bwrapArgs+=(--ro-bind "$storePath" "$storePath")
              mountedStorePaths["$storePath"]=1
            fi
          }

          mountStoreClosure() {
            local storePath="$1"
            local closurePath
            local closurePaths

            [ "$allowAllDirs" = 0 ] || return 0

            if ! closurePaths="$(${lib.getExe' nix "nix-store"} --extra-experimental-features nix-command --query --requisites "$storePath")"; then
              echo "could not resolve the Nix closure for $storePath" >&2
              exit 2
            fi

            while IFS= read -r closurePath; do
              mountStorePath "$closurePath"
            done <<< "$closurePaths"
          }

          if [ "$allowAllDirs" = 0 ]; then
            while IFS= read -r storePath; do
              mountStorePath "$storePath"
            done < ${runtimeClosure}/store-paths
          fi
        ''
    }

    sandboxPath="${sandboxPath}"

    addPathEntry() {
      local pathEntry="$1"
      local resolvedPath
      ${lib.optionalString (storeMode == "closure") "local storeRoot"}

      [ -n "$pathEntry" ] || pathEntry=.
      resolvedPath="$(realpath -m "$pathEntry")"
      case "$resolvedPath" in
        /nix/store/*)
          sandboxPath="$sandboxPath:$resolvedPath"
          ${lib.optionalString (storeMode == "closure") ''
            storeRoot="$(printf '%s\n' "$resolvedPath" | cut -d / -f 1-4)"
            mountStoreClosure "$storeRoot"
          ''}
          ;;
        "$workspace")
          sandboxPath="$sandboxPath:/workspace"
          ;;
        "$workspace"/*)
          sandboxPath="$sandboxPath:/workspace''${resolvedPath#"$workspace"}"
          ;;
      esac
    }

    while IFS= read -r pathEntry; do
      addPathEntry "$pathEntry"
    done < <(printf '%s' "$PATH" | tr ':' '\n')

    ${lib.optionalString (storeMode == "closure") ''
      addStorePathsFromValue() {
        local value="$1"
        local storePath

        while IFS= read -r storePath; do
          [ -n "$storePath" ] && mountStoreClosure "$storePath"
        done < <(printf '%s' "$value" | ${lib.getExe gnugrep} -oE '/nix/store/[a-z0-9]{32}-[A-Za-z0-9+._?=-]+')
      }

      importDevVariable() {
        local variable="$1"
        local value="''${!variable-}"

        [ -n "$value" ] || return 0
        value="''${value//"$workspace"/\/workspace}"
        addStorePathsFromValue "$value"
        bwrapArgs+=(--setenv "$variable" "$value")
      }

      if [ "''${CODEX_BWRAP_IMPORT_DEV_ENV:-0}" = 1 ]; then
        for variable in \
          ACLOCAL_PATH \
          C_INCLUDE_PATH \
          CMAKE_MODULE_PATH \
          CMAKE_PREFIX_PATH \
          CPATH \
          CPLUS_INCLUDE_PATH \
          LIBRARY_PATH \
          LD_LIBRARY_PATH \
          MANPATH \
          NIX_CFLAGS_COMPILE \
          NIX_LDFLAGS \
          NODE_PATH \
          PKG_CONFIG_LIBDIR \
          PKG_CONFIG_PATH \
          PYTHONHOME \
          PYTHONPATH \
          RUSTFLAGS \
          RUST_SRC_PATH \
          XDG_DATA_DIRS \
          CC CXX CPP AR AS LD NM OBJCOPY OBJDUMP RANLIB STRIP CARGO RUSTC RUSTDOC; do
          importDevVariable "$variable"
        done
      fi
    ''}

    bwrapArgs+=(
      --setenv PATH "$sandboxPath"
      --chdir /workspace
      --
      ${lib.getExe codex}
      "$@"
    )

    memoryMax="''${CODEX_BWRAP_MEMORY_MAX:-8G}"
    cpuQuota="''${CODEX_BWRAP_CPU_QUOTA:-200%}"
    tasksMax="''${CODEX_BWRAP_TASKS_MAX:-512}"

    exec ${lib.getExe' systemd "systemd-run"} \
      --user \
      --scope \
      --collect \
      --quiet \
      --property="MemoryMax=$memoryMax" \
      --property="CPUQuota=$cpuQuota" \
      --property="TasksMax=$tasksMax" \
      -- ${lib.getExe bubblewrap} "''${bwrapArgs[@]}"
  '';

  meta = {
    description = "Run Codex in a resource-limited Bubblewrap workspace sandbox";
    homepage = "https://github.com/Pionanx/codex-nix";
    license = lib.licenses.asl20;
    platforms = lib.platforms.linux;
    mainProgram = name;
  };
}
