local versions = require('stratum.gitseer.versions')

local M = {}

---@param values string[]
---@param needle string
---@return boolean
local function list_contains(values, needle)
    for _, value in ipairs(values) do
        if value == needle then
            return true
        end
    end
    return false
end

---@param capabilities? table
---@return boolean, string?
function M.validate(capabilities)
    if type(capabilities) ~= 'table' then
        return false, 'gitseer returned no capabilities'
    end

    local protocol = capabilities.protocol or {}
    local repository = capabilities.repository or {}
    if capabilities.name ~= 'gitseer' then
        return false, 'gitseer returned an unexpected process name'
    end
    if type(capabilities.version) ~= 'string' or capabilities.version == '' then
        return false, 'gitseer did not advertise its package version'
    end
    if protocol.jsonrpc ~= '2.0' or protocol.version ~= versions.protocol or protocol.transport ~= 'stdio' then
        return false, ('gitseer requires protocol revision %d over JSON-RPC stdio'):format(versions.protocol)
    end
    if repository.single_repository_process ~= true then
        return false, 'gitseer did not confirm single-repository mode'
    end
    for _, method in ipairs({
        'gitseer/getSnapshot',
        'gitseer/refresh',
        'gitseer/subscribe',
        'gitseer/unsubscribe',
    }) do
        if not list_contains(protocol.methods or {}, method) then
            return false, ('gitseer did not advertise %s support'):format(method)
        end
    end
    for _, notification in ipairs({ 'gitseer/snapshot', 'gitseer/delta', 'gitseer/goodbye' }) do
        if not list_contains(protocol.notifications or {}, notification) then
            return false, ('gitseer did not advertise %s notifications'):format(notification)
        end
    end

    return true
end

return M
