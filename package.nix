{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  ncurses,
}:

let
  source = builtins.fromJSON (builtins.readFile ./sources.json);
  inherit (source) version;
  repo = "openai/codex";

  platformMap = {
    "x86_64-linux" = "x86_64-unknown-linux-musl";
    "aarch64-linux" = "aarch64-unknown-linux-musl";
    "x86_64-darwin" = "x86_64-apple-darwin";
    "aarch64-darwin" = "aarch64-apple-darwin";
  };

  platform =
    platformMap.${stdenv.hostPlatform.system}
      or (throw "Unsupported system: ${stdenv.hostPlatform.system}");

  hash = source.hashes.${platform} or (throw "Missing source hash for platform: ${platform}");

  isLinux = stdenv.hostPlatform.isLinux;
in

stdenv.mkDerivation {
  pname = "codex";
  inherit version;

  src = fetchurl {
    url = "https://github.com/${repo}/releases/download/rust-v${version}/codex-package-${platform}.tar.gz";
    inherit hash;
  };

  sourceRoot = ".";
  strictDeps = true;

  nativeBuildInputs = lib.optionals isLinux [ autoPatchelfHook ];

  # The Linux package is static except for its bundled zsh, which needs libtinfo.
  buildInputs = lib.optionals isLinux [ ncurses ];

  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    cp -R bin codex-package.json codex-path codex-resources "$out/"

    runHook postInstall
  '';

  # Preserve upstream Mach-O binaries and signatures on Darwin.
  dontFixup = !isLinux;

  meta = {
    description = "OpenAI Codex CLI - an AI coding agent for your terminal";
    homepage = "https://github.com/openai/codex";
    changelog = "https://github.com/${repo}/releases/tag/rust-v${version}";
    license = lib.licenses.asl20;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = builtins.attrNames platformMap;
    mainProgram = "codex";
  };
}
