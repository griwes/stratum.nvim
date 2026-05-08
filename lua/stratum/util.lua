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

---@param root string
---@param path string
---@return string
function M.relative_path(root, path)
    local normalized_root = M.normalize_path(root):gsub('/+$', '')
    local normalized_path = M.normalize_path(path)
    if vim.fs.relpath ~= nil then
        local relative = vim.fs.relpath(normalized_root, normalized_path)
        if type(relative) == 'string' and relative ~= '' then
            return relative
        end
    end

    local prefix = normalized_root .. '/'
    if normalized_path:sub(1, #prefix) == prefix then
        return normalized_path:sub(#prefix + 1)
    end

    return normalized_path
end

return M
