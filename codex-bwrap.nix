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
  ripgrep,
  codex,
}:

let
  runtimePackages = [
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
    codex
  ];

  runtimeClosure = closureInfo {
    rootPaths = runtimePackages;
  };

  sandboxPath = lib.makeBinPath runtimePackages;
  certificateBundle = "${cacert}/etc/ssl/certs/ca-bundle.crt";
in
writeShellApplication {
  name = "codex-bwrap";
  runtimeInputs = runtimePackages;

  text = ''
    workspace="$(pwd -P)"

    if [ "$workspace" = / ]; then
      echo "codex-bwrap must be started from a directory below /" >&2
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
      echo "both $legacyCodexHome and $hostCodexHome exist; merge them manually before running codex-bwrap" >&2
      exit 2
    fi

    mkdir -p "$hostCodexHome"
    hostCodexHome="$(realpath -e "$hostCodexHome")"

    declare -A mountedStorePaths=()
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
      --bind "$workspace" /workspace
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

    while IFS= read -r storePath; do
      bwrapArgs+=(--ro-bind "$storePath" "$storePath")
      mountedStorePaths["$storePath"]=1
    done < ${runtimeClosure}/store-paths

    sandboxPath="${sandboxPath}"
    while IFS= read -r pathEntry; do
      pathEntry="''${pathEntry%/}"
      case "$pathEntry" in
        /nix/store/*/bin)
          storePath="''${pathEntry%/bin}"
          if [ -d "$storePath" ] && [ -z "''${mountedStorePaths[$storePath]+x}" ]; then
            bwrapArgs+=(--ro-bind "$storePath" "$storePath")
            mountedStorePaths["$storePath"]=1
            sandboxPath="$sandboxPath:$pathEntry"
          fi
          ;;
      esac
    done < <(printf '%s' "$PATH" | tr ':' '\n')

    bwrapArgs+=(
      --setenv PATH "$sandboxPath"
      --chdir /workspace
      --
      ${lib.getExe codex}
      "$@"
    )

    exec ${lib.getExe bubblewrap} "''${bwrapArgs[@]}"
  '';

  meta = {
    description = "Run Codex in a bubblewrap sandbox limited to the current directory";
    homepage = "https://github.com/Pionanx/codex-nix";
    license = lib.licenses.asl20;
    platforms = lib.platforms.linux;
    mainProgram = "codex-bwrap";
  };
}
