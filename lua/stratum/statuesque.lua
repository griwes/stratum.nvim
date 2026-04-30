local M = {}

local snapshot_mod = require('stratum.snapshot')

---@class stratum.StatuesqueRepoStatusOptions
---@field icon? string
---@field max_width? integer
---@field auto_start? boolean
---@field empty_text? string
---@field unavailable_text? string
---@field disconnected_text? string
---@field disconnected_hl? string|table
---@field unknown_text? string
---@field detached_length? integer
---@field staged_icon? string
---@field unstaged_icon? string
---@field untracked_icon? string
---@field conflicted_icon? string
---@field ahead_icon? string
---@field behind_icon? string
---@field operation_icon? string
---@field stale_text? string

---@param context? table
---@return string?
local function buffer_path(context)
    local bufnr = context and (context.bufnr or context.buf or context.buffer)
    if type(bufnr) ~= 'number' or not vim.api.nvim_buf_is_valid(bufnr) then
        bufnr = vim.api.nvim_get_current_buf()
    end

    local path = vim.api.nvim_buf_get_name(bufnr)
    if path == '' then
        return nil
    end

    return path
end

---@param state table
---@param opts stratum.StatuesqueRepoStatusOptions
---@return string[]
local function repo_parts(state, opts)
    local summary = snapshot_mod.summarize(state.snapshot, opts)
    local parts = {
        (opts.icon or '') .. ' ' .. summary.head_label,
    }

    if summary.operation ~= nil then
        parts[#parts + 1] = (opts.operation_icon or '↯') .. summary.operation
    end

    if summary.staged > 0 then
        parts[#parts + 1] = (opts.staged_icon or '+') .. summary.staged
    end
    if summary.unstaged > 0 then
        parts[#parts + 1] = (opts.unstaged_icon or '~') .. summary.unstaged
    end
    if summary.untracked > 0 then
        parts[#parts + 1] = (opts.untracked_icon or '?') .. summary.untracked
    end
    if summary.conflicted > 0 then
        parts[#parts + 1] = (opts.conflicted_icon or '!') .. summary.conflicted
    end
    if summary.ahead > 0 then
        parts[#parts + 1] = (opts.ahead_icon or '↑') .. summary.ahead
    end
    if summary.behind > 0 then
        parts[#parts + 1] = (opts.behind_icon or '↓') .. summary.behind
    end
    if state.stale then
        parts[#parts + 1] = opts.stale_text or 'stale'
    end

    return parts
end

---@param opts? stratum.StatuesqueRepoStatusOptions
---@return table
function M.repo_status(opts)
    opts = opts or {}
    return {
        statuesque_component = true,
        render = function(_, context)
            local stratum = require('stratum')
            local path = buffer_path(context)
            if path == nil then
                return opts.empty_text and { role = 'git-repo', text = opts.empty_text } or false
            end

            local repo, err
            if opts.auto_start == false then
                repo, err = stratum.repo_for_path(path)
            else
                repo, err = stratum.ensure_repo(path)
            end

            if repo == nil then
                return opts.empty_text and { role = 'git-repo', text = opts.empty_text, title = err } or false
            end

            local state = type(stratum.state) == 'function' and stratum.state(repo.id) or nil
            if type(state) ~= 'table' then
                return opts.empty_text and { role = 'git-repo', text = opts.empty_text } or false
            end

            if state.status == 'unavailable' or state.status == 'disconnected' then
                return {
                    role = 'git-repo',
                    text = opts.disconnected_text or opts.unavailable_text or 'git unavailable',
                    hl = opts.disconnected_hl or 'StatuesqueWarning',
                    title = state.last_error,
                }
            end

            if state.snapshot == nil and state.status ~= 'connected' then
                return opts.empty_text and { role = 'git-repo', text = opts.empty_text } or false
            end

            return {
                role = 'git-repo',
                text = table.concat(repo_parts(state, opts), ' '),
                max_width = opts.max_width or 40,
                truncate = 'right',
            }
        end,
        subscribe = function(_, notify)
            local group = vim.api.nvim_create_augroup('stratum-statuesque-repo-status', { clear = false })
            local buffer_autocmd = vim.api.nvim_create_autocmd(
                { 'BufEnter', 'BufFilePost', 'BufWritePost', 'DirChanged' },
                {
                    group = group,
                    callback = notify,
                }
            )
            local stratum_autocmd = vim.api.nvim_create_autocmd('User', {
                group = group,
                pattern = 'StratumRepositoryUpdated',
                callback = notify,
            })

            return function()
                pcall(vim.api.nvim_del_autocmd, buffer_autocmd)
                pcall(vim.api.nvim_del_autocmd, stratum_autocmd)
            end
        end,
    }
end

return M
