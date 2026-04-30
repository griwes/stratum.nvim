# Stratum.nvim

Neovim Git substrate backed by gitseer.

## Status

Early development. The current implementation provides the initial lifecycle and
state API skeleton:

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

Stratum expects Gitseer to send a full snapshot for initial subscription,
explicit snapshot/refresh requests, and resync/error recovery. Ordinary watched
repository updates should arrive as versioned deltas. Stratum should apply those
deltas to its cached state and request a fresh snapshot only when version
continuity is broken or a full refresh is explicitly requested.

Gitseer is also expected to filter ignored worktree churn and refresh only the
state domains affected by a repository event. Stratum should not depend on, or
normalize around, receiving full snapshots for every file change.

## Installation

Example local `lazy.nvim` spec:

```lua
{
    dir = vim.fn.expand("~/projects/neovim-plugin-orchestration/stratum.nvim"),
    name = 'stratum.nvim',
    opts = {
        gitseer = {
            command = 'gitseer',
        },
    },
}
```

## API

```lua
local stratum = require('stratum')

stratum.setup({
    gitseer = {
        command = 'gitseer',
        args = {},
        auto_start = true,
    },
})

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

- tests live in `tests/`
- formatting is enforced with Stylua
- Lua modules should carry LuaLS annotations and doc comments
- CI lives in `.github/workflows/ci.yml`
