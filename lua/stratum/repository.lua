local util = require('stratum.util')

local M = {}

---@class stratum.Repository
---@field id string
---@field root string
---@field status 'installing'|'starting'|'connected'|'stale'|'disconnected'|'unavailable'
---@field stale boolean
---@field snapshot? table
---@field last_error? string

---@param path string
---@return string?, string?
function M.default_locator(path)
    if type(path) ~= 'string' or path == '' then
        return nil, 'path must be a non-empty string'
    end

    local start = util.parent_dir(path)
    local git_markers = vim.fs.find('.git', {
        path = start,
        upward = true,
        type = 'file',
    })

    if #git_markers == 0 then
        git_markers = vim.fs.find('.git', {
            path = start,
            upward = true,
            type = 'directory',
        })
    end

    if #git_markers == 0 then
        return nil, ('path is not inside a Git repository: %s'):format(path)
    end

    return util.normalize_path(vim.fn.fnamemodify(git_markers[1], ':h'))
end

return M
