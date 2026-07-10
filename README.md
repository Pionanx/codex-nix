# codex-nix

Nix flake for [OpenAI Codex CLI](https://github.com/openai/codex), the Rust coding agent for your terminal.

The package tracks the latest stable GitHub release and installs the official standalone bundle. That bundle includes `codex`, `codex-code-mode-host`, `rg`, the Codex resources, and `bwrap` on Linux.

## Quick Start

```bash
nix run github:Pionanx/codex-nix -- --version
nix profile install github:Pionanx/codex-nix
```

## Using as a Flake Input

```nix
{
  inputs.codex-nix.url = "github:Pionanx/codex-nix";

  outputs = { nixpkgs, codex-nix, ... }: { ... };
}
```

### nix-darwin / NixOS

```nix
{ inputs, pkgs, ... }:
{
  environment.systemPackages = [
    inputs.codex-nix.packages.${pkgs.system}.default
  ];
}
```

### Home Manager

```nix
{ inputs, pkgs, ... }:
{
  home.packages = [
    inputs.codex-nix.packages.${pkgs.system}.default
  ];
}
```

A consuming flake pins this repository in its own `flake.lock`. Refresh it with:

```bash
nix flake update codex-nix
```

## Platforms

| Platform | Architecture | GitHub Actions runner |
|----------|--------------|-----------------------|
| Linux | x86_64 | `ubuntu-24.04` |
| Linux | aarch64 | `ubuntu-24.04-arm` |
| macOS | x86_64 | `macos-15-intel` |
| macOS | aarch64 (Apple Silicon) | `macos-15` |

All four platforms are built natively before an automated update is published.

## Updates

`sources.json` is the single source of truth for the Codex version and release hashes. The updater reads GitHub's latest non-draft, non-prerelease release and verifies the official `codex-package_SHA256SUMS` manifest before changing that file.

```bash
./scripts/update.sh          # update to the latest stable release
./scripts/update.sh --check  # exit non-zero when version or hashes are stale
./scripts/update.sh 0.144.1  # update to a specific release
```

The scheduled workflow checks hourly. When an update exists, it builds all four supported systems, rechecks that the release is still current, and atomically publishes `main`, `v<version>`, and `latest`.

GitHub disables Actions on a newly created fork until its owner enables them. Enable workflows for this repository once so the scheduled updater can run.

## Verification

```bash
nix flake check --print-build-logs
nix run .# -- --version
```

## Related

- [openai/codex](https://github.com/openai/codex) - upstream project
