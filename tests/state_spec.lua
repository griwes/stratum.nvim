local stratum = require('stratum')

local function assert_equal(actual, expected)
    assert(actual == expected, ('expected %q, got %q'):format(tostring(expected), tostring(actual)))
end

local function assert_contains(actual, expected)
    assert(tostring(actual):find(expected, 1, true), ('expected %q to contain %q'):format(tostring(actual), expected))
end

local function make_harness()
    local harness = {
        workers = {},
        starts = {},
    }

    local function snapshot_for(root, suffix)
        return {
            identity = {
                id = 'gitseer:' .. root,
                worktreeRoot = root,
            },
            head = {
                kind = suffix or 'attached',
            },
        }
    end

    local function snapshot_params_for(root, suffix, version)
        return {
            version = version or 1,
            snapshot = snapshot_for(root, suffix),
        }
    end

    local function capabilities()
        return {
            name = 'gitseer',
            protocol = {
                jsonrpc = '2.0',
                version = 1,
                transport = 'stdio',
                methods = {
                    'initialize',
                    'gitseer/refresh',
                    'gitseer/subscribe',
                },
                notifications = {
                    'gitseer/snapshot',
                    'gitseer/delta',
                    'gitseer/goodbye',
                },
            },
            repository = {
                single_repository_process = true,
            },
        }
    end

    function harness.factory(spec, handlers)
        table.insert(harness.starts, spec)
        local worker = {
            spec = spec,
            handlers = handlers,
            requests = {},
            stopped = false,
        }
        table.insert(harness.workers, worker)

        function worker.request(method, params, callback)
            table.insert(worker.requests, {
                method = method,
                params = params,
            })

            if method == 'initialize' and callback then
                callback(capabilities())
            elseif method == 'gitseer/subscribe' then
                handlers.on_notification({
                    jsonrpc = '2.0',
                    method = 'gitseer/snapshot',
                    params = snapshot_params_for(spec.repo_root),
                })
            elseif method == 'gitseer/refresh' and callback then
                callback(snapshot_params_for(spec.repo_root, 'refreshed', 2))
            end
        end

        function worker.stop()
            worker.stopped = true
            handlers.on_notification({
                jsonrpc = '2.0',
                method = 'gitseer/goodbye',
                params = { reason = 'intentional shutdown' },
            })
            handlers.on_exit('terminated')
        end

        return worker
    end

    return harness
end

local function setup_harness(harness)
    stratum._reset_for_tests()
    stratum.setup({
        gitseer = {
            command = 'fake-gitseer',
            process_factory = function(spec, handlers)
                return harness.factory(spec, handlers)
            end,
            repository_locator = function(path)
                if path == '/outside/file.txt' then
                    return nil, 'not a repository'
                end

                if path:find('/beta/', 1, true) then
                    return '/repos/beta'
                end

                return '/repos/alpha'
            end,
        },
    })
end

describe('stratum state api', function()
    it('starts without launching a repository worker', function()
        local harness = make_harness()
        setup_harness(harness)

        local status = stratum.start()

        assert_equal(status.state, 'ready')
        assert_equal(#harness.starts, 0)
    end)

    it('maps paths to stable repo records without spawning workers', function()
        local harness = make_harness()
        setup_harness(harness)

        local repo = assert(stratum.repo_for_path('/repos/alpha/file.txt'))
        local same = assert(stratum.repo_for_path('/repos/alpha/other.txt'))

        assert_equal(repo.id, '/repos/alpha')
        assert_equal(same.id, repo.id)
        assert_equal(#harness.starts, 0)
    end)

    it('launches and reuses one worker per repository on demand', function()
        local harness = make_harness()
        setup_harness(harness)

        local alpha = assert(stratum.ensure_repo('/repos/alpha/file.txt'))
        local same_alpha = assert(stratum.ensure_repo('/repos/alpha/other.txt'))
        local beta = assert(stratum.ensure_repo('/repos/beta/file.txt'))

        assert_equal(alpha.id, same_alpha.id)
        assert_equal(beta.id, '/repos/beta')
        assert_equal(#harness.starts, 2)
        assert_equal(harness.starts[1].command, 'fake-gitseer')
        assert_equal(harness.starts[1].repo_root, '/repos/alpha')
        assert_equal(harness.workers[1].requests[1].method, 'initialize')
        assert_equal(harness.workers[1].requests[2].method, 'gitseer/subscribe')
    end)

    it('degrades on incompatible gitseer capabilities', function()
        stratum._reset_for_tests()
        stratum.setup({
            gitseer = {
                command = 'fake-gitseer',
                process_factory = function(_, _)
                    local worker = {
                        stopped = false,
                    }

                    function worker.request(_, _, callback)
                        callback({
                            name = 'not-gitseer',
                            protocol = {},
                            repository = {},
                        })
                    end

                    function worker.stop()
                        worker.stopped = true
                    end

                    return worker
                end,
                repository_locator = function()
                    return '/repos/alpha'
                end,
            },
        })

        local repo = assert(stratum.ensure_repo('/repos/alpha/file.txt'))
        local state = assert(stratum.state(repo.id))

        assert_equal(state.status, 'unavailable')
        assert(state.last_error:find('unexpected process name', 1, true))
    end)

    it('degrades when Gitseer does not advertise delta notifications', function()
        stratum._reset_for_tests()
        stratum.setup({
            gitseer = {
                command = 'fake-gitseer',
                process_factory = function(_, _)
                    local worker = {}

                    function worker.request(_, _, callback)
                        callback({
                            name = 'gitseer',
                            protocol = {
                                jsonrpc = '2.0',
                                version = 1,
                                transport = 'stdio',
                                methods = {
                                    'initialize',
                                    'gitseer/refresh',
                                    'gitseer/subscribe',
                                },
                                notifications = {
                                    'gitseer/snapshot',
                                },
                            },
                            repository = {
                                single_repository_process = true,
                            },
                        })
                    end

                    function worker.stop() end

                    return worker
                end,
                repository_locator = function()
                    return '/repos/alpha'
                end,
            },
        })

        local repo = assert(stratum.ensure_repo('/repos/alpha/file.txt'))
        local state = assert(stratum.state(repo.id))

        assert_equal(state.status, 'unavailable')
        assert(state.last_error:find('delta notifications', 1, true))
    end)

    it('summarizes Gitseer snapshots for consumers', function()
        local summary = stratum.snapshot_summary({
            head = {
                branch = 'main',
            },
            paths = {
                staged = { 'staged.lua' },
                unstaged = { 'changed.lua' },
                untracked = { 'new.lua' },
            },
            upstream = {
                ahead = 2,
                behind = 1,
            },
            operation = {
                kind = 'merge',
            },
        })

        assert_equal(summary.head_label, 'main')
        assert_equal(summary.staged, 1)
        assert_equal(summary.unstaged, 1)
        assert_equal(summary.untracked, 1)
        assert_equal(summary.ahead, 2)
        assert_equal(summary.behind, 1)
        assert_equal(summary.operation, 'merge')
    end)

    it('summarizes cached repository state by id or path', function()
        local harness = make_harness()
        setup_harness(harness)

        local repo = assert(stratum.ensure_repo('/repos/alpha/file.txt'))
        local by_id = assert(stratum.summary(repo.id))
        local by_path = assert(stratum.summary('/repos/alpha/other.txt'))

        assert_equal(by_id.head_label, 'attached')
        assert_equal(by_path.head_label, 'attached')
    end)

    it('degrades when initialize fails', function()
        stratum._reset_for_tests()
        stratum.setup({
            gitseer = {
                command = 'fake-gitseer',
                process_factory = function(_, _)
                    local worker = {
                        stopped = false,
                    }

                    function worker.request(_, _, callback)
                        callback(nil, 'initialize failed')
                    end

                    function worker.stop()
                        worker.stopped = true
                    end

                    return worker
                end,
                repository_locator = function()
                    return '/repos/alpha'
                end,
            },
        })

        local repo = assert(stratum.ensure_repo('/repos/alpha/file.txt'))
        local state = assert(stratum.state(repo.id))

        assert_equal(state.status, 'unavailable')
        assert_equal(state.last_error, 'initialize failed')
    end)
    it('stores snapshots defensively and marks stale disconnects explicitly', function()
        local harness = make_harness()
        setup_harness(harness)

        local repo = assert(stratum.ensure_repo('/repos/alpha/file.txt'))
        local state = assert(stratum.state(repo.id))

        assert_equal(state.stale, false)
        assert_equal(state.status, 'connected')
        state.snapshot.head.kind = 'mutated'

        local fresh = assert(stratum.state(repo.id))
        assert_equal(fresh.snapshot.head.kind, 'attached')

        harness.workers[1].handlers.on_notification({
            jsonrpc = '2.0',
            method = 'gitseer/goodbye',
            params = { reason = 'test shutdown' },
        })

        local disconnected = assert(stratum.state(repo.id))
        assert_equal(disconnected.stale, true)
        assert_equal(disconnected.status, 'disconnected')
        assert_equal(disconnected.last_error, 'test shutdown')
    end)

    it('applies version-contiguous Gitseer delta patches to cached state', function()
        local harness = make_harness()
        setup_harness(harness)

        local repo = assert(stratum.ensure_repo('/repos/alpha/file.txt'))
        harness.workers[1].handlers.on_notification({
            jsonrpc = '2.0',
            method = 'gitseer/snapshot',
            params = {
                version = 7,
                snapshot = {
                    identity = {
                        id = 'gitseer:/repos/alpha',
                        worktreeRoot = '/repos/alpha',
                    },
                    head = {
                        kind = 'attached',
                        branch = 'main',
                    },
                    paths = {
                        unstaged = {},
                        untracked = {},
                    },
                },
            },
        })

        local updates = {}
        local unsubscribe = stratum.subscribe(repo.id, function(update)
            table.insert(updates, update)
        end)
        harness.workers[1].handlers.on_notification({
            jsonrpc = '2.0',
            method = 'gitseer/delta',
            params = {
                previousVersion = 7,
                version = 8,
                delta = {
                    paths = {
                        unstaged = {
                            added = { 'README.md' },
                            removed = {},
                        },
                    },
                },
                patch = {
                    paths = {
                        unstaged = { 'README.md' },
                        untracked = {},
                    },
                },
            },
        })
        unsubscribe()

        local state = assert(stratum.state(repo.id))
        assert_equal(state.snapshot_version, 8)
        assert_equal(state.snapshot.head.branch, 'main')
        assert_equal(state.snapshot.paths.unstaged[1], 'README.md')
        assert_equal(#updates, 1)
        assert_equal(updates[1].kind, 'delta')
        assert_equal(updates[1].version, 8)
        assert_equal(updates[1].snapshot.paths.unstaged[1], 'README.md')
    end)

    it('requests a resync snapshot when Gitseer delta versions skip ahead', function()
        local harness = make_harness()
        setup_harness(harness)

        local repo = assert(stratum.ensure_repo('/repos/alpha/file.txt'))
        harness.workers[1].handlers.on_notification({
            jsonrpc = '2.0',
            method = 'gitseer/snapshot',
            params = {
                version = 2,
                snapshot = {
                    identity = {
                        id = 'gitseer:/repos/alpha',
                        worktreeRoot = '/repos/alpha',
                    },
                    head = {
                        kind = 'attached',
                        branch = 'main',
                    },
                },
            },
        })

        harness.workers[1].handlers.on_notification({
            jsonrpc = '2.0',
            method = 'gitseer/delta',
            params = {
                previousVersion = 99,
                version = 100,
                delta = {},
                patch = {
                    head = {
                        kind = 'attached',
                        branch = 'wrong',
                    },
                },
            },
        })

        local state = assert(stratum.state(repo.id))
        assert_equal(harness.workers[1].requests[#harness.workers[1].requests].method, 'gitseer/refresh')
        assert_equal(state.snapshot.head.kind, 'refreshed')
    end)

    it('rejects non-contiguous or patchless Gitseer deltas before dispatch', function()
        local cases = {
            {
                name = 'version jump',
                payload = {
                    previousVersion = 2,
                    version = 4,
                    delta = {},
                    patch = { head = { kind = 'attached', branch = 'jumped' } },
                },
            },
            {
                name = 'missing previous version',
                payload = {
                    version = 3,
                    delta = {},
                    patch = { head = { kind = 'attached', branch = 'missing-prev' } },
                },
            },
            {
                name = 'missing version',
                payload = {
                    previousVersion = 2,
                    delta = {},
                    patch = { head = { kind = 'attached', branch = 'missing-version' } },
                },
            },
            {
                name = 'missing patch',
                payload = {
                    previousVersion = 2,
                    version = 3,
                    delta = {},
                },
            },
            {
                name = 'empty patch',
                payload = {
                    previousVersion = 2,
                    version = 3,
                    delta = {},
                    patch = {},
                },
            },
            {
                name = 'unknown-only patch',
                payload = {
                    previousVersion = 2,
                    version = 3,
                    delta = {},
                    patch = { unknown = true },
                },
            },
            {
                name = 'non-table params',
                payload = 'malformed',
            },
        }

        for _, case in ipairs(cases) do
            local harness = make_harness()
            setup_harness(harness)
            local repo = assert(stratum.ensure_repo('/repos/alpha/file.txt'))
            harness.workers[1].handlers.on_notification({
                jsonrpc = '2.0',
                method = 'gitseer/snapshot',
                params = {
                    version = 2,
                    snapshot = {
                        identity = {
                            id = 'gitseer:/repos/alpha',
                            worktreeRoot = '/repos/alpha',
                        },
                        head = {
                            kind = 'attached',
                            branch = 'main',
                        },
                    },
                },
            })
            local delta_updates = 0
            local unsubscribe = stratum.subscribe(repo.id, function(update)
                if update.kind == 'delta' then
                    delta_updates = delta_updates + 1
                end
            end)

            harness.workers[1].handlers.on_notification({
                jsonrpc = '2.0',
                method = 'gitseer/delta',
                params = case.payload,
            })
            unsubscribe()

            local state = assert(stratum.state(repo.id))
            assert_equal(delta_updates, 0)
            assert_equal(harness.workers[1].requests[#harness.workers[1].requests].method, 'gitseer/refresh')
            assert_equal(state.snapshot.head.kind, 'refreshed')
        end
    end)

    it('requests resync instead of applying deltas without a versioned baseline', function()
        local harness = make_harness()
        setup_harness(harness)
        local repo = assert(stratum.ensure_repo('/repos/alpha/file.txt'))
        harness.workers[1].handlers.on_notification({
            jsonrpc = '2.0',
            method = 'gitseer/snapshot',
            params = {
                identity = {
                    id = 'legacy:/repos/alpha',
                    worktreeRoot = '/repos/alpha',
                },
                head = {
                    kind = 'attached',
                    branch = 'legacy',
                },
            },
        })
        local delta_updates = 0
        local unsubscribe = stratum.subscribe(repo.id, function(update)
            if update.kind == 'delta' then
                delta_updates = delta_updates + 1
            end
        end)

        harness.workers[1].handlers.on_notification({
            jsonrpc = '2.0',
            method = 'gitseer/delta',
            params = {
                previousVersion = 1,
                version = 2,
                delta = {},
                patch = {
                    head = {
                        kind = 'attached',
                        branch = 'without-baseline',
                    },
                },
            },
        })
        unsubscribe()

        local state = assert(stratum.state(repo.id))
        assert_equal(delta_updates, 0)
        assert_equal(harness.workers[1].requests[#harness.workers[1].requests].method, 'gitseer/refresh')
        assert_equal(state.snapshot.head.kind, 'refreshed')
    end)

    it('dispatches subscriptions, unsubscribe, refreshes, and User events', function()
        local harness = make_harness()
        setup_harness(harness)

        local repo = assert(stratum.ensure_repo('/repos/alpha/file.txt'))
        local updates = {}
        local events = 0
        local group = vim.api.nvim_create_augroup('StratumTestEvents', { clear = true })
        vim.api.nvim_create_autocmd('User', {
            group = group,
            pattern = 'StratumRepositoryUpdated',
            callback = function()
                events = events + 1
            end,
        })

        harness.workers[1].handlers.on_notification({
            jsonrpc = '2.0',
            method = 'gitseer/snapshot',
            params = {
                version = 1,
                snapshot = {
                    identity = {
                        id = 'gitseer:/repos/alpha',
                        worktreeRoot = '/repos/alpha',
                    },
                    head = {
                        kind = 'attached',
                    },
                    paths = {
                        unstaged = {},
                    },
                },
            },
        })
        local unsubscribe = stratum.subscribe(repo.id, function(update)
            table.insert(updates, update)
        end)

        harness.workers[1].handlers.on_notification({
            jsonrpc = '2.0',
            method = 'gitseer/delta',
            params = {
                previousVersion = 1,
                version = 2,
                delta = { changed = true },
                patch = {
                    paths = {
                        unstaged = { 'README.md' },
                    },
                },
            },
        })
        unsubscribe()
        harness.workers[1].handlers.on_notification({
            jsonrpc = '2.0',
            method = 'gitseer/delta',
            params = {
                previousVersion = 2,
                version = 3,
                delta = { changed = false },
                patch = {
                    paths = {
                        unstaged = {},
                    },
                },
            },
        })

        local ok = assert(stratum.refresh(repo.id))
        local refreshed = assert(stratum.state(repo.id))

        assert_equal(ok, true)
        assert_equal(#updates, 1)
        assert_equal(updates[1].kind, 'delta')
        assert_equal(refreshed.snapshot.head.kind, 'refreshed')
        assert(events >= 3)
    end)

    it('exports a Statuesque runtimepath git repo widget module', function()
        package.loaded['statuesque.widgets.git_repo'] = nil
        local provider = require('statuesque.widgets.git_repo')
        local widget = provider()

        assert_equal(type(provider), 'function')
        assert_equal(widget.statuesque_component, true)
    end)

    it('renders Stratum repository state as a Statuesque component', function()
        local harness = make_harness()
        setup_harness(harness)

        local bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_name(bufnr, '/repos/alpha/unavailable-file.txt')
        local widget = require('stratum.statuesque').repo_status()
        local rendered = widget:render({ bufnr = bufnr })

        assert_equal(rendered.role, 'git-repo')
        assert_contains(rendered.text, ' attached')
    end)

    it('renders Gitseer JSON null fields without treating them as tables', function()
        local harness = make_harness()
        setup_harness(harness)
        local worker_factory = harness.factory
        harness.factory = function(spec, handlers)
            local worker = worker_factory(spec, handlers)
            function worker.request(method, params, callback)
                table.insert(worker.requests, {
                    method = method,
                    params = params,
                })

                if method == 'initialize' and callback then
                    callback({
                        name = 'gitseer',
                        protocol = {
                            jsonrpc = '2.0',
                            version = 1,
                            transport = 'stdio',
                            methods = {
                                'initialize',
                                'gitseer/refresh',
                                'gitseer/subscribe',
                            },
                            notifications = {
                                'gitseer/snapshot',
                                'gitseer/delta',
                                'gitseer/goodbye',
                            },
                        },
                        repository = {
                            single_repository_process = true,
                        },
                    })
                elseif method == 'gitseer/subscribe' then
                    handlers.on_notification({
                        jsonrpc = '2.0',
                        method = 'gitseer/snapshot',
                        params = {
                            version = 1,
                            snapshot = {
                                identity = {
                                    id = 'gitseer:' .. spec.repo_root,
                                    worktreeRoot = spec.repo_root,
                                },
                                head = {
                                    branch = 'channels',
                                },
                                paths = {
                                    unstaged = { 'README.md' },
                                    untracked = {},
                                },
                                operation = vim.NIL,
                                upstream = vim.NIL,
                            },
                        },
                    })
                elseif method == 'gitseer/refresh' and callback then
                    callback(nil)
                end
            end
            return worker
        end

        local bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_name(bufnr, '/repos/alpha/README.md')
        local rendered = require('stratum.statuesque').repo_status():render({ bufnr = bufnr })

        assert_equal(rendered.role, 'git-repo')
        assert_equal(rendered.text, ' channels ~1')
    end)

    it('renders unavailable Stratum repository state without requiring a snapshot', function()
        stratum._reset_for_tests()
        stratum.setup({
            gitseer = {
                command = 'fake-gitseer',
                process_factory = function(_, _)
                    local worker = {}

                    function worker.request(_, _, callback)
                        callback(nil, 'initialize failed')
                    end

                    function worker.stop() end

                    return worker
                end,
                repository_locator = function()
                    return '/repos/alpha'
                end,
            },
        })

        local bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_name(bufnr, '/repos/alpha/file.txt')
        local rendered = require('stratum.statuesque').repo_status():render({ bufnr = bufnr })

        assert_equal(rendered.role, 'git-repo')
        assert_equal(rendered.text, 'git unavailable')
        assert_equal(rendered.title, 'initialize failed')
    end)

    it('returns typed nil and errors for non-repository paths', function()
        local harness = make_harness()
        setup_harness(harness)

        local repo, err = stratum.repo_for_path('/outside/file.txt')
        local state, state_err = stratum.state('/outside/file.txt')

        assert_equal(repo, nil)
        assert_equal(err, 'not a repository')
        assert_equal(state, nil)
        assert_equal(state_err, 'not a repository')
        assert_equal(#harness.starts, 0)
    end)

    it('reports unavailable when gitseer is absent', function()
        stratum._reset_for_tests()
        stratum.setup({
            gitseer = {
                command = 'definitely-missing-gitseer-for-stratum-tests',
                repository_locator = function()
                    return '/repos/alpha'
                end,
            },
        })

        local repo = assert(stratum.ensure_repo('/repos/alpha/file.txt'))
        local state = assert(stratum.state(repo.id))

        assert_equal(state.status, 'unavailable')
        assert(state.last_error:find('gitseer executable not found', 1, true))
        assert_equal(stratum.status().state, 'unavailable')
    end)

    it('stops owned workers cleanly', function()
        local harness = make_harness()
        setup_harness(harness)

        stratum.ensure_repo('/repos/alpha/file.txt')
        stratum.stop()

        assert_equal(harness.workers[1].stopped, true)
        assert_equal(stratum.status().state, 'stopped')
    end)

    it('ignores delayed callbacks from old workers after replacement', function()
        local harness = {
            starts = {},
            workers = {},
        }

        function harness.factory(spec, handlers)
            table.insert(harness.starts, spec)
            local worker = {
                handlers = handlers,
                stopped = false,
                requests = {},
            }
            table.insert(harness.workers, worker)

            function worker.request(method, _, callback)
                table.insert(worker.requests, method)
                if method == 'initialize' then
                    callback({
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
                    })
                elseif method == 'gitseer/subscribe' then
                    handlers.on_notification({
                        jsonrpc = '2.0',
                        method = 'gitseer/snapshot',
                        params = {
                            version = 1,
                            snapshot = {
                                identity = { id = 'gitseer:' .. spec.repo_root },
                                head = { kind = 'worker-' .. tostring(#harness.workers) },
                            },
                        },
                    })
                elseif method == 'gitseer/refresh' then
                    if worker.defer_refresh then
                        worker.deferred_refresh = callback
                    else
                        callback({
                            version = 2,
                            snapshot = {
                                identity = { id = 'gitseer:' .. spec.repo_root },
                                head = { kind = 'refreshed' },
                            },
                        })
                    end
                end
            end

            function worker.stop()
                worker.stopped = true
            end

            return worker
        end

        setup_harness(harness)
        local first = assert(stratum.ensure_repo('/repos/alpha/file.txt'))
        local updates = {}
        local collecting = false
        local unsubscribe = stratum.subscribe(first.id, function(update)
            if collecting then
                table.insert(updates, update)
            end
        end)
        harness.workers[1].defer_refresh = true
        local old_refresh_ok = stratum.refresh(first.id)
        assert_equal(old_refresh_ok, true)
        stratum.stop()

        local second = assert(stratum.ensure_repo('/repos/alpha/file.txt'))
        local before_old_events = assert(stratum.state(second.id))
        collecting = true
        local update_count = #updates
        harness.workers[1].handlers.on_notification({
            jsonrpc = '2.0',
            method = 'gitseer/snapshot',
            params = {
                version = 99,
                snapshot = {
                    identity = { id = 'old-worker' },
                    head = { kind = 'old-snapshot' },
                },
            },
        })
        harness.workers[1].handlers.on_notification({
            jsonrpc = '2.0',
            method = 'gitseer/delta',
            params = {
                stale = true,
            },
        })
        harness.workers[1].handlers.on_error('old stderr')
        harness.workers[1].deferred_refresh({
            version = 100,
            snapshot = {
                identity = { id = 'old-worker' },
                head = { kind = 'old-refresh' },
            },
        })
        harness.workers[1].handlers.on_exit('old exit')
        local after_old_events = assert(stratum.state(second.id))

        assert_equal(first.id, second.id)
        assert_equal(before_old_events.snapshot.head.kind, 'worker-2')
        assert_equal(after_old_events.snapshot.head.kind, 'worker-2')
        assert_equal(after_old_events.last_error, nil)
        assert_equal(#harness.workers, 2)
        assert_equal(#updates, update_count)

        local ok, err = stratum.refresh(second.id)
        local state = assert(stratum.state(second.id))

        assert_equal(ok, true)
        assert_equal(err, nil)
        assert_equal(state.status, 'connected')
        assert_equal(state.snapshot.head.kind, 'refreshed')
        unsubscribe()
    end)
end)
