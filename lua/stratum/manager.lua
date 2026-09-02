local config_mod = require('stratum.config')
local capabilities_mod = require('stratum.gitseer.capabilities')
local installer = require('stratum.gitseer.install')
local repository = require('stratum.repository')
local snapshot_mod = require('stratum.snapshot')
local transport = require('stratum.transport')
local util = require('stratum.util')

---@class stratum.Update
---@field kind 'snapshot'|'delta'|'disconnect'
---@field repo stratum.Repository
---@field snapshot? table
---@field delta? table
---@field version? integer
---@field reason? string

---@class stratum.RepositoryState
---@field repo stratum.Repository
---@field stale boolean
---@field status string
---@field snapshot? table
---@field snapshot_version? integer
---@field last_error? string

---@class stratum.Status
---@field state 'stopped'|'ready'|'installing'|'starting'|'connected'|'degraded'|'unavailable'
---@field repos integer
---@field last_error? string

local M = {}

---@type stratum.Config
M.config = config_mod.normalize()

---@type stratum.Status
local status = {
    state = 'stopped',
    repos = 0,
}

---@type table<string, stratum.Repository>
local repos_by_root = {}

---@type table<string, stratum.Repository>
local repos_by_id = {}

---@type table<string, stratum.Worker>
local workers_by_id = {}

---@type table<string, table<integer, fun(update: stratum.Update)>>
local subscribers_by_id = {}

local next_subscriber_id = 0
local next_worker_token = 0
local lifecycle_generation = 0
local expected_exits_by_token = {}
local patch_keys = {
    'identity',
    'head',
    'paths',
    'operation',
    'remotes',
    'branches',
    'tags',
    'stashes',
    'worktrees',
    'submodules',
}
local optional_patch_keys = {
    'headCommit',
    'upstream',
}

---@param repo stratum.Repository
---@return stratum.Repository
local function public_repo(repo)
    return util.deepcopy(repo)
end

---@param repo stratum.Repository
---@param update stratum.Update
local function dispatch(repo, update)
    local subscribers = subscribers_by_id[repo.id] or {}
    for _, callback in pairs(subscribers) do
        callback(util.deepcopy(update))
    end

    vim.api.nvim_exec_autocmds('User', {
        pattern = 'StratumRepositoryUpdated',
        data = {
            repo_id = repo.id,
            kind = update.kind,
        },
    })
end

---@param repo stratum.Repository
---@param payload table
local function snapshot_payload(payload)
    if type(payload) == 'table' and type(payload.snapshot) == 'table' then
        return payload.snapshot, payload.version
    end

    return payload, nil
end

---@param value any
---@return any
local function nil_if_vim_nil(value)
    if value == vim.NIL then
        return nil
    end

    return value
end

---@param table_value table
---@param key string
---@return boolean
local function has_key(table_value, key)
    return type(table_value) == 'table' and rawget(table_value, key) ~= nil
end

---@param patch table
---@return boolean
local function has_applicable_patch_keys(patch)
    if type(patch) ~= 'table' then
        return false
    end

    for _, key in ipairs(patch_keys) do
        if has_key(patch, key) then
            return true
        end
    end
    for _, key in ipairs(optional_patch_keys) do
        if has_key(patch, key) then
            return true
        end
    end

    return false
end

---@param repo stratum.Repository
---@param payload table
local function record_snapshot(repo, payload)
    local snapshot, version = snapshot_payload(payload)
    repo.snapshot = util.deepcopy(snapshot)
    repo.snapshot_version = version
    repo.stale = false
    repo.status = 'connected'
    repo.last_error = nil
    status.state = 'connected'

    dispatch(repo, {
        kind = 'snapshot',
        repo = public_repo(repo),
        snapshot = util.deepcopy(snapshot),
        version = version,
    })
end

---@param repo stratum.Repository
---@param patch table
---@return table?
local function apply_patch(repo, patch)
    if type(repo.snapshot) ~= 'table' or type(patch) ~= 'table' then
        return nil
    end

    local snapshot = util.deepcopy(repo.snapshot)
    for _, key in ipairs(patch_keys) do
        if has_key(patch, key) then
            snapshot[key] = util.deepcopy(nil_if_vim_nil(patch[key]))
        end
    end
    if has_key(patch, 'headCommit') then
        snapshot.headCommit = util.deepcopy(nil_if_vim_nil(patch.headCommit))
    end
    if has_key(patch, 'upstream') then
        snapshot.upstream = util.deepcopy(nil_if_vim_nil(patch.upstream))
    end

    return snapshot
end

---@param repo stratum.Repository
---@param worker stratum.Worker
local function request_resync(repo, worker)
    worker.request('gitseer/refresh', nil, function(payload, request_err)
        if workers_by_id[repo.id] ~= worker then
            return
        end

        if request_err then
            repo.last_error = request_err
            repo.stale = true
            return
        end

        if payload then
            record_snapshot(repo, payload)
        end
    end)
end

---@param repo stratum.Repository
---@param worker stratum.Worker
---@param payload any
local function record_delta(repo, worker, payload)
    if type(payload) ~= 'table' then
        repo.stale = true
        request_resync(repo, worker)
        return
    end

    local previous_version = payload.previousVersion
    local version = payload.version
    if
        type(repo.snapshot_version) ~= 'number'
        or type(previous_version) ~= 'number'
        or type(version) ~= 'number'
        or previous_version ~= repo.snapshot_version
        or version ~= repo.snapshot_version + 1
        or not has_applicable_patch_keys(payload.patch)
    then
        repo.stale = true
        request_resync(repo, worker)
        return
    end

    local patched = apply_patch(repo, payload.patch)
    if patched == nil then
        repo.stale = true
        request_resync(repo, worker)
        return
    end

    repo.snapshot = patched
    repo.snapshot_version = version
    repo.stale = false
    repo.status = 'connected'
    repo.last_error = nil
    status.state = 'connected'

    dispatch(repo, {
        kind = 'delta',
        repo = public_repo(repo),
        delta = util.deepcopy(payload.delta or payload),
        snapshot = util.deepcopy(repo.snapshot),
        version = repo.snapshot_version,
    })
end

---@param repo stratum.Repository
---@param reason string
local function mark_disconnected(repo, reason)
    repo.stale = true
    repo.status = 'disconnected'
    repo.last_error = reason
    status.state = 'degraded'
    status.last_error = reason

    dispatch(repo, {
        kind = 'disconnect',
        repo = public_repo(repo),
        reason = reason,
    })
end

---@param repo stratum.Repository
---@param message string
local function mark_unavailable(repo, message)
    repo.status = 'unavailable'
    repo.stale = true
    repo.last_error = message
    status.state = 'unavailable'
    status.last_error = message

    dispatch(repo, {
        kind = 'disconnect',
        repo = public_repo(repo),
        reason = message,
    })
end

---@param root string
---@return stratum.Repository
local function ensure_record(root)
    local normalized = util.normalize_path(root)
    local repo = repos_by_root[normalized]
    if repo then
        return repo
    end

    repo = {
        id = normalized,
        root = normalized,
        status = 'starting',
        stale = true,
    }
    repos_by_root[normalized] = repo
    repos_by_id[repo.id] = repo
    status.repos = status.repos + 1
    return repo
end

---@param repo stratum.Repository
local function start_worker(repo)
    if workers_by_id[repo.id] ~= nil then
        return
    end

    if M.config.gitseer.process_factory == nil and vim.fn.executable(M.config.gitseer.command) == 0 then
        local install = M.config.gitseer.install
        if install.source ~= 'path' and install.auto then
            repo.status = 'installing'
            repo.last_error = nil
            status.state = 'installing'
            status.last_error = nil
            local generation = lifecycle_generation
            installer.install(install, false, function(result)
                if
                    generation ~= lifecycle_generation
                    or repos_by_id[repo.id] ~= repo
                    or workers_by_id[repo.id] ~= nil
                then
                    return
                end
                if not result.ok then
                    mark_unavailable(repo, result.error or 'Gitseer installation failed')
                    return
                end
                start_worker(repo)
            end)
            return
        end

        local message = ('gitseer executable not found: %s'):format(M.config.gitseer.command)
        mark_unavailable(repo, message)
        return
    end

    status.state = 'starting'
    repo.status = 'starting'
    next_worker_token = next_worker_token + 1
    local worker_token = next_worker_token
    local created_worker
    local ok, worker_or_error = pcall(transport.create, M.config, repo.root, {
        on_notification = function(message)
            if workers_by_id[repo.id] ~= created_worker then
                return
            end

            if message.method == 'gitseer/snapshot' then
                record_snapshot(repo, message.params or {})
            elseif message.method == 'gitseer/delta' then
                record_delta(repo, created_worker, message.params or {})
            elseif message.method == 'gitseer/goodbye' then
                if expected_exits_by_token[worker_token] then
                    return
                end
                local params = message.params or {}
                mark_disconnected(repo, params.reason or 'gitseer stopped')
            end
        end,
        on_exit = function(reason)
            if expected_exits_by_token[worker_token] then
                expected_exits_by_token[worker_token] = nil
                return
            end

            if workers_by_id[repo.id] ~= created_worker then
                return
            end

            workers_by_id[repo.id] = nil
            mark_disconnected(repo, reason)
        end,
        on_error = function(message)
            if workers_by_id[repo.id] ~= created_worker then
                return
            end

            repo.last_error = message
            status.last_error = message
        end,
    })
    if not ok then
        mark_unavailable(repo, tostring(worker_or_error))
        return
    end

    created_worker = worker_or_error
    created_worker._stratum_token = worker_token
    workers_by_id[repo.id] = created_worker
    created_worker.request('initialize', nil, function(capabilities, err)
        if workers_by_id[repo.id] ~= created_worker then
            return
        end

        if err then
            mark_unavailable(repo, err)
            expected_exits_by_token[worker_token] = true
            workers_by_id[repo.id] = nil
            created_worker.stop()
            return
        end

        local valid, message = capabilities_mod.validate(capabilities)
        if not valid then
            mark_unavailable(repo, message or 'gitseer initialize returned unsupported capabilities')
            expected_exits_by_token[worker_token] = true
            workers_by_id[repo.id] = nil
            created_worker.stop()
            return
        end

        created_worker.request('gitseer/subscribe')
    end)
end

---@param opts? stratum.Config
---@return stratum.Config
function M.setup(opts)
    lifecycle_generation = lifecycle_generation + 1
    M.config = config_mod.normalize(opts)
    return util.deepcopy(M.config)
end

---@param opts? { force?: boolean }
---@param callback? fun(result: stratum.GitseerInstallResult)
---@return string command
function M.install_gitseer(opts, callback)
    opts = opts or {}
    if type(opts) ~= 'table' then
        error('stratum.install_gitseer: opts must be a table or nil')
    end
    if opts.force ~= nil and type(opts.force) ~= 'boolean' then
        error('stratum.install_gitseer: force must be a boolean')
    end
    if callback ~= nil and type(callback) ~= 'function' then
        error('stratum.install_gitseer: callback must be a function or nil')
    end

    installer.install(M.config.gitseer.install, opts.force == true, callback or function() end)
    return M.config.gitseer.command
end

---@return table
function M.gitseer_installation()
    return {
        source = M.config.gitseer.install.source,
        version = M.config.gitseer.install.version,
        command = M.config.gitseer.command,
        installed = installer.is_installed(M.config.gitseer.install),
    }
end

---@return stratum.Status
function M.start()
    if status.state == 'stopped' then
        status.state = 'ready'
    end

    return M.status()
end

function M.stop()
    lifecycle_generation = lifecycle_generation + 1
    for repo_id, worker in pairs(workers_by_id) do
        expected_exits_by_token[worker._stratum_token] = true
        worker.stop()
        workers_by_id[repo_id] = nil
    end

    for _, repo in pairs(repos_by_id) do
        repo.status = 'disconnected'
        repo.stale = true
    end

    status.state = 'stopped'
end

function M._reset_for_tests()
    M.stop()
    M.config = config_mod.normalize()
    status = {
        state = 'stopped',
        repos = 0,
    }
    repos_by_root = {}
    repos_by_id = {}
    workers_by_id = {}
    subscribers_by_id = {}
    next_subscriber_id = 0
    next_worker_token = 0
    expected_exits_by_token = {}
end

---@return stratum.Status
function M.status()
    local current = util.deepcopy(status)
    current.repos = status.repos
    return current
end

---@param path string
---@return stratum.Repository?, string?
function M.repo_for_path(path)
    local locator = M.config.gitseer.repository_locator or repository.default_locator
    local root, err = locator(path)
    if not root then
        return nil, err
    end

    return public_repo(ensure_record(root))
end

---@param path string
---@return stratum.Repository?, string?
function M.ensure_repo(path)
    local locator = M.config.gitseer.repository_locator or repository.default_locator
    local root, err = locator(path)
    if not root then
        return nil, err
    end

    local repo = ensure_record(root)
    if M.config.gitseer.auto_start then
        start_worker(repo)
    end

    return public_repo(repo)
end

---@param repo_id_or_path string
---@return stratum.RepositoryState?, string?
function M.state(repo_id_or_path)
    local repo = repos_by_id[repo_id_or_path]
    if repo == nil then
        local public, err = M.ensure_repo(repo_id_or_path)
        if not public then
            return nil, err
        end
        repo = repos_by_id[public.id]
    end

    if repo == nil then
        return nil, ('unknown repository: %s'):format(repo_id_or_path)
    end

    return {
        repo = public_repo(repo),
        stale = repo.stale,
        status = repo.status,
        snapshot = util.deepcopy(repo.snapshot),
        snapshot_version = repo.snapshot_version,
        last_error = repo.last_error,
    }
end

---@param snapshot? table
---@param opts? stratum.SnapshotSummaryOptions
---@return stratum.SnapshotSummary
function M.snapshot_summary(snapshot, opts)
    return snapshot_mod.summarize(snapshot, opts)
end

---@param snapshot table
---@param path string
---@return stratum.PathSummary
function M.snapshot_path_summary(snapshot, path)
    return snapshot_mod.path_summary(snapshot, path)
end

---@param repo_id_or_path string
---@param opts? stratum.SnapshotSummaryOptions
---@return stratum.SnapshotSummary?, string?
function M.summary(repo_id_or_path, opts)
    local state, err = M.state(repo_id_or_path)
    if state == nil then
        return nil, err
    end

    return snapshot_mod.summarize(state.snapshot, opts)
end

---@param path string
---@return stratum.PathSummary?, string?
function M.path_summary(path)
    local state, err = M.state(path)
    if state == nil then
        return nil, err
    end
    if state.status ~= 'connected' or type(state.snapshot) ~= 'table' then
        return nil, state.last_error or ('repository state is not ready: %s'):format(state.status)
    end

    local relative = util.relative_path(state.repo.root, path)
    return snapshot_mod.path_summary(state.snapshot, relative)
end

---@param repo_id_or_path string
---@param callback fun(update: stratum.Update)
---@return fun()
function M.subscribe(repo_id_or_path, callback)
    if type(callback) ~= 'function' then
        error('stratum.subscribe: callback must be a function')
    end

    local repo = repos_by_id[repo_id_or_path]
    if repo == nil then
        local public = assert(M.ensure_repo(repo_id_or_path))
        repo = repos_by_id[public.id]
    end

    next_subscriber_id = next_subscriber_id + 1
    local subscriber_id = next_subscriber_id
    subscribers_by_id[repo.id] = subscribers_by_id[repo.id] or {}
    subscribers_by_id[repo.id][subscriber_id] = callback

    return function()
        local subscribers = subscribers_by_id[repo.id]
        if subscribers then
            subscribers[subscriber_id] = nil
        end
    end
end

---@param repo_id_or_path string
---@return boolean, string?
function M.refresh(repo_id_or_path)
    local repo = repos_by_id[repo_id_or_path]
    if repo == nil then
        local public, err = M.ensure_repo(repo_id_or_path)
        if not public then
            return false, err
        end
        repo = repos_by_id[public.id]
    end

    local worker = workers_by_id[repo.id]
    if not worker then
        return false, 'repository worker is not running'
    end

    worker.request('gitseer/refresh', nil, function(snapshot, request_err)
        if workers_by_id[repo.id] ~= worker then
            return
        end

        if request_err then
            repo.last_error = request_err
            return
        end

        if snapshot then
            record_snapshot(repo, snapshot)
        end
    end)
    return true
end

return M
