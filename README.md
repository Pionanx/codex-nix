# codex-nix

Nix flake for [OpenAI Codex CLI](https://github.com/openai/codex), the Rust coding agent for your terminal.

The package tracks the latest stable GitHub release and installs the official standalone bundle. That bundle includes `codex`, `codex-code-mode-host`, `rg`, the Codex resources, and `bwrap` on Linux.

## Quick Start

```bash
nix run github:Pionanx/codex-nix -- --unwrapped --version
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

## Sandbox Modes (Linux)

On Linux, the default `codex` command starts the upstream CLI inside a resource-
limited Bubblewrap sandbox. The workspace is mounted read-only by default. The
host home directory, sibling directories, SSH agent, D-Bus, and Nix daemon are
not mounted. Network access remains available for Codex API requests.

```bash
cd /path/to/project
codex                         # read-only workspace, full /nix/store
codex --write                 # explicitly allow workspace changes
codex --allow-dir "$HOME/Projects/client"  # allow one additional directory
codex --allow-home             # allow the complete home directory
codex --all-dirs               # allow the complete host filesystem
codex --unwrapped             # run upstream Codex without the outer sandbox
```

`--unwrapped` bypasses Bubblewrap but still sets `CODEX_HOME` to the XDG location
so it shares authentication, configuration, and sessions with sandboxed Codex.

`--allow-dir` is repeatable and mounts each supplied absolute path read-write at
its original location. `--allow-home` is shorthand for `--allow-dir "$HOME"`.
`--all-dirs` bind-mounts host `/` read-write and therefore disables filesystem
isolation; it cannot be combined with either directory-specific option.

### Resource Limits

Each sandbox runs through `systemd-run --user --scope` with these defaults:

| Limit | Default |
|-------|---------|
| `MemoryMax` | `8G` |
| `CPUQuota` | `200%` |
| `TasksMax` | `512` |

Override them for one invocation:

```bash
codex bwrap --memory 12G --cpu 400% --tasks 1024
```

This requires a working user systemd manager with delegated cgroup controllers.
The wrapper fails rather than silently dropping the limits when that is unavailable.

### Nix Environments

The default and `--full` modes mount the complete `/nix/store` read-only, so
all installed Nix software and runtime dependencies remain executable.

```bash
# Explicit full-store mode (equivalent to the default store policy)
codex --full

# Temporary Nixpkgs tools, mounted with only their runtime closure
codex --nixpkgs hello cargo --
codex --nixpkgs rustc cargo --write -- exec "run the tests"

# The current flake's default devShell, mounted with its runtime closure
codex --flake --

# A named devShell
codex --flake .#rust --
```

`--flake` invokes `nix develop` before entering Bubblewrap. Treat the current
flake and its development shell as trusted: evaluating or preparing a devShell is
outside the workspace filesystem sandbox.

### Hardened Mode

```bash
codex bwrap --disable-nested-userns
```

This experimental option adds Bubblewrap's `--disable-userns`. It reduces the
surface exposed to nested sandboxes, but may prevent Codex's internal Linux
sandbox from starting. It is intentionally opt-in.

### XDG State

Codex data is fixed at `$XDG_CONFIG_HOME/codex` (default:
`~/.config/codex`). There is no fallback to `~/.codex`: on first run, an existing
legacy directory is moved to the XDG path. If both directories exist, the wrapper
stops rather than guessing how to merge authentication and session state. Codex
currently stores config, auth, and session state under one `CODEX_HOME`, so it
cannot be split further without upstream support.

Direct package entry points remain available:

```bash
nix run github:Pionanx/codex-nix#codex-bwrap       # writable, full store
nix run github:Pionanx/codex-nix#codex-bwrap-ro    # read-only, full store
nix run github:Pionanx/codex-nix#codex-unwrapped   # upstream binary
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
nix run .# -- --unwrapped --version
```

## Related

- [openai/codex](https://github.com/openai/codex) - upstream project
