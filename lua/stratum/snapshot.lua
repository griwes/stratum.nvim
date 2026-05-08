local M = {}

---@class stratum.SnapshotSummaryOptions
---@field detached_length? integer
---@field unknown_text? string

---@class stratum.SnapshotSummary
---@field head_label string
---@field head_kind? string
---@field branch? string
---@field oid? string
---@field operation? string
---@field staged integer
---@field unstaged integer
---@field untracked integer
---@field conflicted integer
---@field ahead integer
---@field behind integer

---@class stratum.PathSummary
---@field path string
---@field dirty boolean
---@field staged boolean
---@field unstaged boolean
---@field untracked boolean
---@field ignored boolean
---@field conflicted boolean
---@field categories string[]
---@field added integer
---@field changed integer
---@field removed integer
---@field entry? table

---@param value any
---@return table
local function table_or_empty(value)
    return type(value) == 'table' and value or {}
end

---@param value any
---@return integer
local function list_length(value)
    return type(value) == 'table' and #value or 0
end

---@param values any
---@param needle string
---@return boolean
local function contains(values, needle)
    if type(values) ~= 'table' then
        return false
    end

    for _, value in ipairs(values) do
        if value == needle then
            return true
        end
    end

    return false
end

---@param entries any
---@param path string
---@return table?
local function find_entry(entries, path)
    if type(entries) ~= 'table' then
        return nil
    end

    for _, entry in ipairs(entries) do
        if
            type(entry) == 'table'
            and (
                entry.path == path
                or entry.stagedOldPath == path
                or entry.stagedNewPath == path
                or entry.workdirOldPath == path
                or entry.workdirNewPath == path
            )
        then
            return entry
        end
    end

    return nil
end

---@param snapshot table
---@param opts stratum.SnapshotSummaryOptions
---@return string
local function head_label(snapshot, opts)
    local head = table_or_empty(snapshot.head)
    if type(head.branch) == 'string' and head.branch ~= '' then
        return head.branch
    end

    if type(head.oid) == 'string' and head.oid ~= '' then
        return head.oid:sub(1, opts.detached_length or 7)
    end

    if type(head.kind) == 'string' and head.kind ~= '' then
        return head.kind
    end

    return opts.unknown_text or 'unknown'
end

---@param snapshot? table
---@param opts? stratum.SnapshotSummaryOptions
---@return stratum.SnapshotSummary
function M.summarize(snapshot, opts)
    opts = opts or {}
    snapshot = table_or_empty(snapshot)
    local head = table_or_empty(snapshot.head)
    local paths = table_or_empty(snapshot.paths)
    local upstream = table_or_empty(snapshot.upstream)
    local operation = table_or_empty(snapshot.operation)
    local operation_kind = type(operation.kind) == 'string' and operation.kind or nil
    if operation_kind == 'clean' then
        operation_kind = nil
    end

    return {
        head_label = head_label(snapshot, opts),
        head_kind = type(head.kind) == 'string' and head.kind or nil,
        branch = type(head.branch) == 'string' and head.branch or nil,
        oid = type(head.oid) == 'string' and head.oid or nil,
        operation = operation_kind,
        staged = list_length(paths.staged),
        unstaged = list_length(paths.unstaged),
        untracked = list_length(paths.untracked),
        conflicted = list_length(paths.conflicted),
        ahead = type(upstream.ahead) == 'number' and upstream.ahead or 0,
        behind = type(upstream.behind) == 'number' and upstream.behind or 0,
    }
end

---@param snapshot? table
---@param path string
---@return stratum.PathSummary
function M.path_summary(snapshot, path)
    snapshot = table_or_empty(snapshot)
    local paths = table_or_empty(snapshot.paths)
    local entry = find_entry(paths.entries, path)
    local status = table_or_empty(entry and entry.status)
    local diff = table_or_empty(entry and entry.diff)
    local categories = {
        staged = contains(paths.staged, path)
            or status.indexNew == true
            or status.indexModified == true
            or status.indexDeleted == true
            or status.indexRenamed == true
            or status.indexTypechange == true,
        unstaged = contains(paths.unstaged, path)
            or status.workdirModified == true
            or status.workdirDeleted == true
            or status.workdirTypechange == true
            or status.workdirRenamed == true
            or status.workdirUnreadable == true,
        untracked = contains(paths.untracked, path) or status.workdirNew == true,
        ignored = contains(paths.ignored, path) or status.ignored == true,
        conflicted = contains(paths.conflicted, path) or status.conflicted == true,
    }
    local category_names = {}
    for _, key in ipairs({ 'staged', 'unstaged', 'untracked', 'ignored', 'conflicted' }) do
        if categories[key] then
            category_names[#category_names + 1] = key
        end
    end

    return {
        path = path,
        dirty = #category_names > 0,
        staged = categories.staged,
        unstaged = categories.unstaged,
        untracked = categories.untracked,
        ignored = categories.ignored,
        conflicted = categories.conflicted,
        categories = category_names,
        added = type(diff.added) == 'number' and diff.added or 0,
        changed = type(diff.changed) == 'number' and diff.changed or 0,
        removed = type(diff.removed) == 'number' and diff.removed or 0,
        entry = entry,
    }
end

return M
