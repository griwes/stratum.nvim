local M = {}

---@generic T
---@param value T
---@return T
function M.deepcopy(value)
    return vim.deepcopy(value)
end

---@param path string
---@return string
function M.normalize_path(path)
    return vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
end

---@param path string
---@return string
function M.parent_dir(path)
    local stat = vim.uv.fs_stat(path)
    if stat and stat.type == 'directory' then
        return M.normalize_path(path)
    end

    return M.normalize_path(vim.fn.fnamemodify(path, ':h'))
end

return M
