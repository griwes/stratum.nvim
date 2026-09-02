# Stratum.nvim

Neovim Git substrate backed by gitseer.

## Status

Early development. The current implementation provides the initial lifecycle and
state API:

- repository-root discovery for paths
- one owned `gitseer serve --repo <root>` worker per repository
- cached repository state seeded from `gitseer/snapshot` notifications and
  updated by versioned `gitseer/delta` notifications
- local summary helpers for common head, path-status, operation, and upstream
  facts
- Lua subscriptions and `User StratumRepositoryUpdated` events
- explicit stale/disconnected/unavailable state when a worker exits or cannot be
  started
- optional Statuesque `git_repo` widget module on runtimepath

Stratum is not a Git UI. It is a shared substrate for plugins that need live Git
state without each shelling out to `git status`.

## Gitseer Stream Contract

Gitseer sends a full snapshot for initial subscription, explicit
snapshot/refresh requests, and resync/error recovery. Ordinary watched
repository updates arrive as versioned deltas. Stratum applies those deltas to
its cached state and requests a fresh snapshot when version continuity is
broken or a full refresh is explicitly requested.

During initialization, Stratum requires the current single-repository Gitseer
protocol: `gitseer/getSnapshot`, `gitseer/refresh`, `gitseer/subscribe`, and
`gitseer/unsubscribe`, plus `gitseer/snapshot`, `gitseer/delta`, and
`gitseer/goodbye` notifications. Stratum uses `gitseer/refresh` for stream
resync because refresh responses carry versioned snapshot metadata.

Gitseer filters ignored worktree churn and classifies repository events into
affected state domains. Stratum consumes that targeted stream and does not
treat full snapshots as the ordinary response to each file change.

## Requirements

- Neovim 0.11 or newer
- `curl` and `sha256sum` for the default GitHub release installation, or a Rust
  toolchain for Cargo installation
- optional: `statuesque.nvim` for the runtimepath Git widget

Linux is the primary supported and CI-tested platform. The project is in early
development and currently publishes from `main` without a stable release tag.

## Installation

Stratum installs Gitseer from the rolling `nightly` GitHub release by default.
The first repository worker request installs the binary into Stratum's Neovim
data directory, verifies its checksum, and requires the current Gitseer
capability protocol before activating it:

```lua
{
    'griwes/stratum.nvim',
    opts = {},
}
```

The source can instead build Gitseer from its `main` branch with Cargo, or use a
user-managed executable without copying it:

```lua
-- Build and install Gitseer from main with Cargo.
require('stratum').setup({
    gitseer = {
        install = { source = 'cargo' },
    },
})

-- Use an executable managed outside Stratum.
require('stratum').setup({
    gitseer = {
        install = {
            source = 'path',
            path = '/usr/local/bin/gitseer',
        },
    },
})
```

On `main`, the known development versions are GitHub release `nightly` and
Cargo branch `main`. An explicit `install.version` overrides the source default;
GitHub versions name release tags, while non-`main` Cargo versions name Git
tags. `install.root` overrides the managed installation directory. Set
`install.auto = false` to require an explicit installation.

Run `:StratumInstallGitseer` to install or validate the configured source.
`:StratumInstallGitseer!` forces a replacement, which is how a mutable nightly
or `main` installation is updated.

Run `:checkhealth stratum` after installation. See `:help stratum` for the
worker lifecycle and state API.

## API

```lua
local stratum = require('stratum')

stratum.setup({
    gitseer = {
        install = {
            source = 'github',
        },
        args = {},
        auto_start = true,
    },
})

stratum.install_gitseer({ force = false }, function(result)
    if not result.ok then
        vim.notify(result.error, vim.log.levels.ERROR)
    end
end)

stratum.start()

local repo, err = stratum.ensure_repo(vim.api.nvim_buf_get_name(0))
if repo then
    local state = stratum.state(repo.id)
    local summary = stratum.summary(repo.id)
    local unsubscribe = stratum.subscribe(repo.id, function(update)
        -- update.kind is "snapshot", "delta", or "disconnect"
    end)

    stratum.refresh(repo.id)
    unsubscribe()
else
    vim.notify(err, vim.log.levels.WARN)
end
```

`repo_for_path(path)` maps a path to a stable repository record without starting
a worker. `ensure_repo(path)` maps and starts the worker when `auto_start` is
enabled. `snapshot_summary(snapshot)` summarizes a raw Gitseer snapshot, while
`summary(repo_id_or_path)` summarizes Stratum's cached state for a repository.

## Statuesque Integration

Stratum ships `lua/statuesque/widgets/git_repo.lua`, so Statuesque's default
preset can discover the richer Git widget through normal runtimepath module
loading. The widget itself lives in Stratum because it interprets Stratum
repository state and Gitseer lifecycle states:

```lua
local widget = require('stratum.statuesque').repo_status({
    max_width = 40,
})
```

Statuesque remains the renderer; Stratum remains the Git-state owner.

## Development

Run `scripts/ci/run.sh` for the repository-local Stylua, test, and clean-install
smoke checks. GitHub Actions runs the tests and clean-install smoke checks on
Neovim 0.11.5, stable, and nightly. A separate lint job runs Stylua and
validates workflow syntax with actionlint, and additional jobs verify both
managed Gitseer installation paths. Tests live under `tests/`; the workflow is
`.github/workflows/ci.yml`.

## License

Apache-2.0. See [`LICENSE`](LICENSE).
