local M = {}

---@class stratum.WorkerSpec
---@field command string
---@field args string[]
---@field repo_root string

---@class stratum.WorkerHandlers
---@field on_notification fun(message: table)
---@field on_exit fun(reason: string)
---@field on_error fun(message: string)

---@class stratum.Worker
---@field request fun(method: string, params?: table, callback?: fun(result?: table, err?: string))
---@field stop fun()
---@field status? fun(): string

---@param argv string[]
---@param value string[]
local function append_all(argv, value)
    for _, item in ipairs(value) do
        table.insert(argv, item)
    end
end

---@param pending table<integer|string, fun(result?: table, err?: string)>
---@param handlers stratum.WorkerHandlers
---@param line string
local function dispatch_line(pending, handlers, line)
    if line == '' then
        return
    end

    local ok, message = pcall(vim.json.decode, line)
    if not ok then
        handlers.on_error(('invalid gitseer JSON-RPC line: %s'):format(line))
        return
    end

    if message.method ~= nil then
        handlers.on_notification(message)
    elseif message.id ~= nil then
        local callback = pending[message.id]
        pending[message.id] = nil
        if callback then
            if message.error then
                callback(nil, message.error.message or 'gitseer request failed')
            else
                callback(message.result)
            end
        end
    end
end

---@param spec stratum.WorkerSpec
---@param handlers stratum.WorkerHandlers
---@return stratum.Worker
function M.spawn(spec, handlers)
    local argv = { spec.command }
    append_all(argv, spec.args)
    append_all(argv, { 'serve', '--repo', spec.repo_root })

    local next_id = 0
    local pending = {}
    local buffer = ''
    local closed = false
    local handle

    ---@param callback fun(result?: table, err?: string)
    ---@param result? table
    ---@param err? string
    local function schedule_callback(callback, result, err)
        vim.schedule(function()
            callback(result, err)
        end)
    end

    ---@param reason string
    local function fail_pending(reason)
        local callbacks = pending
        pending = {}
        for _, callback in pairs(callbacks) do
            if callback then
                schedule_callback(callback, nil, reason)
            end
        end
    end

    ---@param handler fun(...)
    ---@return fun(...)
    local function scheduled(handler)
        return function(...)
            local args = { ... }
            vim.schedule(function()
                handler(unpack(args))
            end)
        end
    end

    local scheduled_handlers = {
        on_notification = scheduled(handlers.on_notification),
        on_exit = scheduled(handlers.on_exit),
        on_error = scheduled(handlers.on_error),
    }

    local function on_stdout(err, data)
        if err then
            scheduled_handlers.on_error(tostring(err))
            return
        end

        if data == nil then
            return
        end

        buffer = buffer .. data
        while true do
            local newline = buffer:find('\n', 1, true)
            if newline == nil then
                break
            end

            local line = buffer:sub(1, newline - 1)
            buffer = buffer:sub(newline + 1)
            vim.schedule(function()
                dispatch_line(pending, handlers, line)
            end)
        end
    end

    handle = vim.system(argv, {
        stdin = true,
        stdout = on_stdout,
        stderr = function(err, data)
            if err then
                scheduled_handlers.on_error(tostring(err))
            elseif data and data ~= '' then
                scheduled_handlers.on_error(data)
            end
        end,
        text = true,
    }, function(result)
        local reason = ('gitseer exited with code %s'):format(tostring(result.code))
        closed = true
        fail_pending(reason)
        scheduled_handlers.on_exit(reason)
    end)

    ---@type stratum.Worker
    local worker = {}

    function worker.request(method, params, callback)
        if closed then
            if callback then
                schedule_callback(callback, nil, 'gitseer process is not running')
            end
            return
        end

        next_id = next_id + 1
        local id = next_id
        pending[id] = callback
        local ok, err = pcall(handle.write, handle, vim.json.encode({
            jsonrpc = '2.0',
            id = id,
            method = method,
            params = params,
        }) .. '\n')
        if not ok then
            pending[id] = nil
            local message = tostring(err)
            scheduled_handlers.on_error(message)
            if callback then
                schedule_callback(callback, nil, message)
            end
        end
    end

    function worker.stop()
        closed = true
        fail_pending('gitseer process stopped')
        pcall(handle.kill, handle, 15)
    end

    function worker.status()
        return 'running'
    end

    return worker
end

---@param config stratum.Config
---@param repo_root string
---@param handlers stratum.WorkerHandlers
---@return stratum.Worker
function M.create(config, repo_root, handlers)
    local spec = {
        command = config.gitseer.command,
        args = config.gitseer.args,
        repo_root = repo_root,
    }

    if config.gitseer.process_factory then
        return config.gitseer.process_factory(spec, handlers)
    end

    return M.spawn(spec, handlers)
end

return M
