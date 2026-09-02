local capabilities_mod = require('stratum.gitseer.capabilities')

local M = {}

---@class stratum.GitseerInstallResult
---@field ok boolean
---@field command string
---@field source 'github'|'cargo'|'path'
---@field version string
---@field installed boolean
---@field error? string

---@class stratum.PendingGitseerInstall
---@field callbacks fun(result: stratum.GitseerInstallResult)[]
---@field force boolean

---@type table<string, stratum.PendingGitseerInstall>
local pending = {}

---@param path string
---@return string
local function normalize(path)
    return vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
end

---@param install stratum.GitseerInstallConfig
---@return string
function M.command(install)
    if install.source == 'path' then
        return install.path
    end

    return vim.fs.joinpath(install.root, install.source, install.version, 'bin', 'gitseer')
end

---@param callback fun(...)
---@param ... any
local function schedule(callback, ...)
    local args = { ... }
    vim.schedule(function()
        callback(unpack(args))
    end)
end

---@param argv string[]
---@param opts table
---@param callback fun(result: vim.SystemCompleted)
local function run(argv, opts, callback)
    local ok, result = pcall(vim.system, argv, opts, function(completed)
        schedule(callback, completed)
    end)
    if not ok then
        schedule(callback, {
            code = -1,
            signal = 0,
            stdout = '',
            stderr = tostring(result),
        })
    end
end

---@param result vim.SystemCompleted
---@param action string
---@return string
local function process_error(result, action)
    local detail = result.stderr
    if detail == nil or detail == '' then
        detail = result.stdout
    end
    detail = vim.trim(detail or '')
    if detail == '' then
        detail = ('exit code %s'):format(tostring(result.code))
    end
    return ('%s: %s'):format(action, detail)
end

---@param command string
---@param callback fun(ok: boolean, error?: string)
local function validate(command, callback)
    if vim.fn.executable(command) ~= 1 then
        schedule(callback, false, ('gitseer executable not found: %s'):format(command))
        return
    end

    run({ command, 'capabilities' }, { text = true }, function(result)
        if result.code ~= 0 then
            callback(false, process_error(result, 'gitseer capability validation failed'))
            return
        end

        local ok, capabilities = pcall(vim.json.decode, result.stdout or '')
        if not ok or type(capabilities) ~= 'table' then
            callback(false, 'gitseer capability validation returned invalid JSON')
            return
        end

        local valid, validation_error = capabilities_mod.validate(capabilities)
        if not valid then
            callback(false, 'gitseer capability validation failed: ' .. validation_error)
            return
        end

        callback(true)
    end)
end

---@param path string
local function delete_tree(path)
    if vim.uv.fs_stat(path) ~= nil then
        vim.fn.delete(path, 'rf')
    end
end

---@param staging string
---@param destination string
---@return boolean, string?
local function activate(staging, destination)
    local parent = vim.fs.dirname(destination)
    vim.fn.mkdir(parent, 'p')

    local backup = destination .. '.old-' .. tostring(vim.uv.hrtime())
    local had_destination = vim.uv.fs_stat(destination) ~= nil
    if had_destination then
        local moved, move_error = vim.uv.fs_rename(destination, backup)
        if not moved then
            return false, ('could not preserve the previous gitseer installation: %s'):format(tostring(move_error))
        end
    end

    local installed, install_error = vim.uv.fs_rename(staging, destination)
    if not installed then
        if had_destination then
            vim.uv.fs_rename(backup, destination)
        end
        return false, ('could not activate the gitseer installation: %s'):format(tostring(install_error))
    end

    delete_tree(backup)
    return true
end

---@param install stratum.GitseerInstallConfig
---@return string?, string?
local function github_asset(install)
    local uname = vim.uv.os_uname()
    local machine = uname.machine:lower()
    if uname.sysname ~= 'Linux' or (machine ~= 'x86_64' and machine ~= 'amd64') then
        return nil, ('no Gitseer GitHub release asset is available for %s/%s'):format(uname.sysname, uname.machine)
    end
    return install.github.asset
end

---@param install stratum.GitseerInstallConfig
---@param staging string
---@param callback fun(ok: boolean, error?: string)
local function install_from_github(install, staging, callback)
    if vim.fn.executable('curl') ~= 1 then
        schedule(callback, false, 'installing Gitseer from GitHub requires curl')
        return
    end
    if vim.fn.executable('sha256sum') ~= 1 then
        schedule(callback, false, 'installing Gitseer from GitHub requires sha256sum')
        return
    end

    local asset, asset_error = github_asset(install)
    if asset == nil then
        schedule(callback, false, asset_error)
        return
    end

    local bin_dir = vim.fs.joinpath(staging, 'bin')
    vim.fn.mkdir(bin_dir, 'p')
    local downloaded_binary = vim.fs.joinpath(bin_dir, asset)
    local binary = vim.fs.joinpath(bin_dir, 'gitseer')
    local checksum = vim.fs.joinpath(bin_dir, asset .. '.sha256')
    local base_url = install.github.base_url:gsub('/+$', '')
    local release_url = table.concat({
        base_url,
        install.github.repository,
        'releases',
        'download',
        install.version,
        asset,
    }, '/')

    run({
        'curl',
        '--fail',
        '--location',
        '--silent',
        '--show-error',
        '--retry',
        '3',
        '--output',
        downloaded_binary,
        release_url,
    }, {
        text = true,
    }, function(download_result)
        if download_result.code ~= 0 then
            callback(false, process_error(download_result, 'could not download Gitseer'))
            return
        end

        run({
            'curl',
            '--fail',
            '--location',
            '--silent',
            '--show-error',
            '--retry',
            '3',
            '--output',
            checksum,
            release_url .. '.sha256',
        }, { text = true }, function(checksum_result)
            if checksum_result.code ~= 0 then
                callback(false, process_error(checksum_result, 'could not download the Gitseer checksum'))
                return
            end

            run({ 'sha256sum', '--check', vim.fs.basename(checksum) }, {
                cwd = bin_dir,
                text = true,
            }, function(verify_result)
                if verify_result.code ~= 0 then
                    callback(false, process_error(verify_result, 'Gitseer checksum verification failed'))
                    return
                end

                local renamed, rename_error = vim.uv.fs_rename(downloaded_binary, binary)
                if not renamed then
                    callback(false, ('could not name the Gitseer executable: %s'):format(tostring(rename_error)))
                    return
                end
                local chmod_ok, chmod_error = vim.uv.fs_chmod(binary, 493)
                if not chmod_ok then
                    callback(false, ('could not make Gitseer executable: %s'):format(tostring(chmod_error)))
                    return
                end
                callback(true)
            end)
        end)
    end)
end

---@param install stratum.GitseerInstallConfig
---@param staging string
---@param callback fun(ok: boolean, error?: string)
local function install_from_cargo(install, staging, callback)
    if vim.fn.executable('cargo') ~= 1 then
        schedule(callback, false, 'installing Gitseer from Cargo requires cargo')
        return
    end

    local argv = { 'cargo', 'install', '--locked', '--root', staging }
    if install.cargo.path ~= nil then
        vim.list_extend(argv, { '--path', normalize(install.cargo.path) })
    else
        vim.list_extend(argv, { '--git', install.cargo.git })
        if install.version == 'main' then
            vim.list_extend(argv, { '--branch', 'main' })
        else
            vim.list_extend(argv, { '--tag', install.version })
        end
        table.insert(argv, 'gitseer')
    end

    run(argv, { text = true }, function(result)
        if result.code ~= 0 then
            callback(false, process_error(result, 'Cargo could not install Gitseer'))
            return
        end
        callback(true)
    end)
end

---@param install stratum.GitseerInstallConfig
---@param force boolean
---@param callback fun(result: stratum.GitseerInstallResult)
function M.install(install, force, callback)
    local command = M.command(install)
    local result = {
        ok = false,
        command = command,
        source = install.source,
        version = install.version,
        installed = false,
    }

    if install.source == 'path' then
        validate(command, function(ok, validation_error)
            result.ok = ok
            result.error = validation_error
            callback(result)
        end)
        return
    end

    local existing = pending[command]
    if existing ~= nil then
        table.insert(existing.callbacks, callback)
        existing.force = existing.force or force
        return
    end
    pending[command] = {
        callbacks = { callback },
        force = force,
    }

    ---@param completed stratum.GitseerInstallResult
    local function finish(completed)
        local current = pending[command]
        pending[command] = nil
        for _, waiting in ipairs(current and current.callbacks or {}) do
            waiting(vim.deepcopy(completed))
        end
    end

    ---@param reinstall boolean
    local function begin_install(reinstall)
        if not reinstall then
            result.ok = true
            finish(result)
            return
        end

        local destination = vim.fs.dirname(vim.fs.dirname(command))
        local staging = destination .. '.tmp-' .. tostring(vim.uv.hrtime())
        delete_tree(staging)
        vim.fn.mkdir(vim.fs.dirname(staging), 'p')

        local function installed(ok, install_error)
            if not ok then
                delete_tree(staging)
                result.error = install_error
                finish(result)
                return
            end

            local staged_command = vim.fs.joinpath(staging, 'bin', 'gitseer')
            validate(staged_command, function(valid, validation_error)
                if not valid then
                    delete_tree(staging)
                    result.error = validation_error
                    finish(result)
                    return
                end

                local activated, activation_error = activate(staging, destination)
                if not activated then
                    delete_tree(staging)
                    result.error = activation_error
                    finish(result)
                    return
                end

                result.ok = true
                result.installed = true
                finish(result)
            end)
        end

        if install.source == 'github' then
            install_from_github(install, staging, installed)
        else
            install_from_cargo(install, staging, installed)
        end
    end

    if not force and vim.fn.executable(command) == 1 then
        validate(command, function(ok)
            local current = pending[command]
            begin_install(not ok or (current ~= nil and current.force))
        end)
    else
        begin_install(true)
    end
end

---@param install stratum.GitseerInstallConfig
---@return boolean
function M.is_installed(install)
    return vim.fn.executable(M.command(install)) == 1
end

return M
