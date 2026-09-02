local M = {
    repository = 'griwes/gitseer',
    protocol = 1,
    github_release = 'nightly',
    cargo_ref = 'main',
    linux_amd64_asset = 'gitseer-linux-amd64',
}

---@param source 'github'|'cargo'|'path'
---@return string
function M.default_for(source)
    if source == 'github' then
        return M.github_release
    end
    if source == 'cargo' then
        return M.cargo_ref
    end
    return 'manual'
end

return M
