local versions = require('stratum.gitseer.versions')

---@alias stratum.GitseerInstallSource 'github'|'cargo'|'path'

---@class stratum.GitseerGithubConfig
---@field repository string
---@field base_url string
---@field asset string

---@class stratum.GitseerCargoConfig
---@field git string
---@field path? string

---@class stratum.GitseerInstallConfig
---@field source stratum.GitseerInstallSource
---@field version string
---@field auto boolean
---@field root string
---@field path? string
---@field github stratum.GitseerGithubConfig
---@field cargo stratum.GitseerCargoConfig

---@class stratum.GitseerConfig
---@field command string Resolved executable path; derived from `install`.
---@field install stratum.GitseerInstallConfig
---@field args string[]
---@field auto_start boolean
---@field process_factory? fun(spec: stratum.WorkerSpec, handlers: stratum.WorkerHandlers): stratum.Worker
---@field repository_locator? fun(path: string): string?, string?

---@class stratum.Config
---@field gitseer stratum.GitseerConfig

local M = {}

---@type stratum.Config
M.defaults = {
    gitseer = {
        install = {
            source = 'github',
            auto = true,
            root = vim.fs.joinpath(vim.fn.stdpath('data'), 'stratum', 'gitseer'),
            github = {
                repository = versions.repository,
                base_url = 'https://github.com',
                asset = versions.linux_amd64_asset,
            },
            cargo = {
                git = 'https://github.com/' .. versions.repository,
            },
        },
        args = {},
        auto_start = true,
    },
}

---@param opts? table
---@return stratum.Config
function M.normalize(opts)
    if opts ~= nil and type(opts) ~= 'table' then
        error('stratum.setup expected a table or nil')
    end

    local requested_install = type(opts) == 'table' and type(opts.gitseer) == 'table' and opts.gitseer.install or nil
    local requested_version = type(requested_install) == 'table' and rawget(requested_install, 'version') or nil
    local config = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts or {})
    if type(config.gitseer) ~= 'table' then
        error('stratum.setup: gitseer must be a table')
    end

    local install = config.gitseer.install
    if type(install) ~= 'table' then
        error('stratum.setup: gitseer.install must be a table')
    end
    if install.source ~= 'github' and install.source ~= 'cargo' and install.source ~= 'path' then
        error("stratum.setup: gitseer.install.source must be 'github', 'cargo', or 'path'")
    end
    if requested_version == nil then
        install.version = versions.default_for(install.source)
    end
    if type(install.version) ~= 'string' or install.version == '' or install.version:find('[^%w._-]') ~= nil then
        error('stratum.setup: gitseer.install.version must be a safe non-empty version name')
    end
    if type(install.auto) ~= 'boolean' then
        error('stratum.setup: gitseer.install.auto must be a boolean')
    end
    if type(install.root) ~= 'string' or install.root == '' then
        error('stratum.setup: gitseer.install.root must be a non-empty string')
    end
    install.root = vim.fs.normalize(install.root)

    if install.source == 'path' and (type(install.path) ~= 'string' or install.path == '') then
        error("stratum.setup: gitseer.install.path is required when source is 'path'")
    end
    if install.path ~= nil and type(install.path) ~= 'string' then
        error('stratum.setup: gitseer.install.path must be a string')
    end
    if type(install.github) ~= 'table' then
        error('stratum.setup: gitseer.install.github must be a table')
    end
    for _, key in ipairs({ 'repository', 'base_url', 'asset' }) do
        if type(install.github[key]) ~= 'string' or install.github[key] == '' then
            error(('stratum.setup: gitseer.install.github.%s must be a non-empty string'):format(key))
        end
    end
    if type(install.cargo) ~= 'table' then
        error('stratum.setup: gitseer.install.cargo must be a table')
    end
    if type(install.cargo.git) ~= 'string' or install.cargo.git == '' then
        error('stratum.setup: gitseer.install.cargo.git must be a non-empty string')
    end
    if install.cargo.path ~= nil and (type(install.cargo.path) ~= 'string' or install.cargo.path == '') then
        error('stratum.setup: gitseer.install.cargo.path must be a non-empty string')
    end

    config.gitseer.command = require('stratum.gitseer.install').command(install)

    if type(config.gitseer.args) ~= 'table' then
        error('stratum.setup: gitseer.args must be a list')
    end

    for index, arg in ipairs(config.gitseer.args) do
        if type(arg) ~= 'string' then
            error(('stratum.setup: gitseer.args[%d] must be a string'):format(index))
        end
    end

    if type(config.gitseer.auto_start) ~= 'boolean' then
        error('stratum.setup: gitseer.auto_start must be a boolean')
    end

    if config.gitseer.process_factory ~= nil and type(config.gitseer.process_factory) ~= 'function' then
        error('stratum.setup: gitseer.process_factory must be a function')
    end

    if config.gitseer.repository_locator ~= nil and type(config.gitseer.repository_locator) ~= 'function' then
        error('stratum.setup: gitseer.repository_locator must be a function')
    end

    return config
end

return M
