---@class stratum.GitseerConfig
---@field command string
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
        command = 'gitseer',
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

    local config = vim.tbl_deep_extend('force', M.defaults, opts or {})
    if type(config.gitseer) ~= 'table' then
        error('stratum.setup: gitseer must be a table')
    end

    if type(config.gitseer.command) ~= 'string' or config.gitseer.command == '' then
        error('stratum.setup: gitseer.command must be a non-empty string')
    end

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
