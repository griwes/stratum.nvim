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

return M
