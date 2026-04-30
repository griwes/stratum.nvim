local stratum = require('stratum')
local transport = require('stratum.transport')

local function assert_equal(actual, expected)
    assert(actual == expected, ('expected %q, got %q'):format(tostring(expected), tostring(actual)))
end

local function write_file(path, contents)
    local file = assert(io.open(path, 'w'))
    file:write(contents)
    file:close()
end

local function fixture_script(body)
    local path = vim.fn.tempname() .. '.lua'
    write_file(path, body)
    return path
end

local function wait_until(predicate, message)
    local ok = vim.wait(15000, predicate, 20)
    assert(ok, message)
end

local fake_gitseer = [[
local repo = ''
for index, value in ipairs(arg or {}) do
    if value == '--repo' then
        repo = arg[index + 1] or ''
    end
end

local function write(message)
    io.stdout:write(vim.json.encode(message) .. '\n')
    io.stdout:flush()
end

local function snapshot(kind)
    return {
        identity = {
            id = 'gitseer:' .. repo,
            worktreeRoot = repo,
        },
        head = {
            kind = kind or 'attached',
        },
    }
end

local function snapshot_params(kind, version)
    return {
        version = version or 1,
        snapshot = snapshot(kind),
    }
end

while true do
    local line = io.read('*l')
    if not line then
        break
    end

    local request = vim.json.decode(line)
    if request.method == 'initialize' then
        write({
            jsonrpc = '2.0',
            id = request.id,
            result = {
                name = 'gitseer',
                protocol = {
                    jsonrpc = '2.0',
                    version = 1,
                    transport = 'stdio',
                    methods = { 'initialize', 'gitseer/refresh', 'gitseer/subscribe' },
                    notifications = { 'gitseer/snapshot', 'gitseer/delta', 'gitseer/goodbye' },
                },
                repository = {
                    single_repository_process = true,
                },
            },
        })
    elseif request.method == 'gitseer/subscribe' then
        write({
            jsonrpc = '2.0',
            id = request.id,
            result = { subscribed = true },
        })
        write({
            jsonrpc = '2.0',
            method = 'gitseer/snapshot',
            params = snapshot_params(),
        })
    elseif request.method == 'gitseer/refresh' then
        write({
            jsonrpc = '2.0',
            id = request.id,
            result = snapshot_params('refreshed', 2),
        })
    end
end
]]

describe('stratum real transport', function()
    it('schedules process callbacks before touching Neovim API', function()
        stratum._reset_for_tests()
        local script = fixture_script(fake_gitseer)
        local root = vim.fn.tempname()
        vim.fn.mkdir(root, 'p')
        local events = 0
        local group = vim.api.nvim_create_augroup('StratumTransportEvents', { clear = true })
        vim.api.nvim_create_autocmd('User', {
            group = group,
            pattern = 'StratumRepositoryUpdated',
            callback = function()
                events = events + 1
            end,
        })

        stratum.setup({
            gitseer = {
                command = vim.v.progpath,
                args = { '--headless', '--clean', '-l', script },
                repository_locator = function()
                    return root
                end,
            },
        })

        local repo = assert(stratum.ensure_repo(root .. '/file.txt'))
        wait_until(function()
            local state = stratum.state(repo.id)
            return state and state.status == 'connected'
        end, 'expected fake gitseer snapshot')

        assert(events > 0)
        stratum.stop()
        wait_until(function()
            return stratum.status().state == 'stopped'
        end, 'expected clean Stratum shutdown')
    end)

    it('fails pending and post-exit requests deterministically', function()
        local script = fixture_script([[
local _ = io.read('*l')
]])
        local callback_err
        local exit_reason
        local worker = transport.create(
            {
                gitseer = {
                    command = vim.v.progpath,
                    args = { '--headless', '--clean', '-l', script },
                },
            },
            '/tmp/repo',
            {
                on_notification = function() end,
                on_exit = function(reason)
                    exit_reason = reason
                end,
                on_error = function() end,
            }
        )

        worker.request('initialize', nil, function(_, err)
            callback_err = err
        end)
        wait_until(function()
            return callback_err ~= nil and exit_reason ~= nil
        end, 'expected pending request to fail on process exit')

        local post_exit_err
        worker.request('gitseer/refresh', nil, function(_, err)
            post_exit_err = err
        end)
        wait_until(function()
            return post_exit_err ~= nil
        end, 'expected post-exit request to fail')

        assert(callback_err:find('gitseer exited', 1, true))
        assert_equal(post_exit_err, 'gitseer process is not running')
    end)

    it('can subscribe to a real Gitseer worker in this workspace', function()
        if vim.fn.filereadable('../gitseer/Cargo.toml') == 0 or vim.fn.executable('cargo') == 0 then
            return
        end

        stratum._reset_for_tests()
        local root = vim.fn.tempname()
        vim.fn.mkdir(root, 'p')
        vim.fn.system({ 'git', '-C', root, 'init' })
        assert_equal(vim.v.shell_error, 0)

        stratum.setup({
            gitseer = {
                command = 'env',
                args = {
                    'CARGO_HOME=/tmp/gitseer-cargo-home',
                    'cargo',
                    'run',
                    '--quiet',
                    '--manifest-path',
                    '../gitseer/Cargo.toml',
                    '--',
                },
                repository_locator = function()
                    return root
                end,
            },
        })

        local repo = assert(stratum.ensure_repo(root .. '/file.txt'))
        wait_until(function()
            local state = stratum.state(repo.id)
            return state and state.status == 'connected' and state.snapshot ~= nil
        end, 'expected real Gitseer snapshot')

        local state = assert(stratum.state(repo.id))
        assert(state.snapshot.identity)
        stratum.stop()
    end)
end)
