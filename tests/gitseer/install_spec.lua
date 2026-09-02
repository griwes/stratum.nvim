local installer = require('stratum.gitseer.install')
local stratum = require('stratum')

local function assert_equal(actual, expected)
    assert(actual == expected, ('expected %q, got %q'):format(tostring(expected), tostring(actual)))
end

local function write_file(path, contents)
    vim.fn.mkdir(vim.fs.dirname(path), 'p')
    local file = assert(io.open(path, 'wb'))
    file:write(contents)
    file:close()
end

local function capability_script(protocol_version)
    return ([=[#!/usr/bin/env sh
if [ "${1:-}" = capabilities ]; then
    printf '%%s\n' '{"name":"gitseer","version":"0.1.0","protocol":{"jsonrpc":"2.0","version":%d,"transport":"stdio","methods":["gitseer/getSnapshot","gitseer/refresh","gitseer/subscribe","gitseer/unsubscribe"],"notifications":["gitseer/snapshot","gitseer/delta","gitseer/goodbye"]},"repository":{"single_repository_process":true}}'
    exit 0
fi
exit 2
]=]):format(protocol_version)
end

local function wait_for_install(install, force)
    local completed
    installer.install(install, force or false, function(result)
        completed = result
    end)
    assert(
        vim.wait(15000, function()
            return completed ~= nil
        end, 20),
        'timed out waiting for Gitseer installation'
    )
    return completed
end

local function release_fixture(protocol_version)
    local root = vim.fn.tempname()
    local asset_dir = vim.fs.joinpath(root, 'griwes', 'gitseer', 'releases', 'download', 'nightly')
    local asset = vim.fs.joinpath(asset_dir, 'gitseer-linux-amd64')
    write_file(asset, capability_script(protocol_version))

    local checksum = vim.system({ 'sha256sum', vim.fs.basename(asset) }, {
        cwd = asset_dir,
        text = true,
    }):wait()
    assert_equal(checksum.code, 0)
    write_file(asset .. '.sha256', checksum.stdout)
    return root
end

describe('stratum Gitseer installer', function()
    it('downloads, validates, and resolves a GitHub release binary', function()
        stratum._reset_for_tests()
        local fixture = release_fixture(1)
        local install_root = vim.fn.tempname()
        local config = stratum.setup({
            gitseer = {
                auto_start = false,
                install = {
                    source = 'github',
                    root = install_root,
                    github = {
                        base_url = 'file://' .. fixture,
                    },
                },
            },
        })

        local result
        local command = stratum.install_gitseer({}, function(completed)
            result = completed
        end)
        assert(
            vim.wait(15000, function()
                return result ~= nil
            end, 20),
            'timed out waiting for public Gitseer installation API'
        )

        assert_equal(result.ok, true)
        assert_equal(result.installed, true)
        assert_equal(command, config.gitseer.command)
        assert_equal(result.command, config.gitseer.command)
        assert_equal(vim.fn.executable(result.command), 1)
        assert_equal(stratum.gitseer_installation().installed, true)
        local capabilities = vim.system({ result.command, 'capabilities' }, { text = true }):wait()
        assert_equal(capabilities.code, 0)

        vim.fn.delete(fixture, 'rf')
        vim.fn.delete(install_root, 'rf')
    end)

    it('rejects a release binary with an incompatible protocol revision', function()
        stratum._reset_for_tests()
        local fixture = release_fixture(99)
        local install_root = vim.fn.tempname()
        local config = stratum.setup({
            gitseer = {
                auto_start = false,
                install = {
                    source = 'github',
                    root = install_root,
                    github = {
                        base_url = 'file://' .. fixture,
                    },
                },
            },
        })

        local result = wait_for_install(config.gitseer.install)

        assert_equal(result.ok, false)
        assert(result.error:find('protocol revision 1', 1, true))
        assert_equal(vim.fn.executable(config.gitseer.command), 0)

        vim.fn.delete(fixture, 'rf')
        vim.fn.delete(install_root, 'rf')
    end)

    it('validates user-managed paths without copying them', function()
        stratum._reset_for_tests()
        local command = vim.fn.tempname()
        write_file(command, capability_script(1))
        assert(vim.uv.fs_chmod(command, 493))
        local config = stratum.setup({
            gitseer = {
                install = {
                    source = 'path',
                    path = command,
                },
            },
        })

        local result = wait_for_install(config.gitseer.install)

        assert_equal(result.ok, true)
        assert_equal(result.installed, false)
        assert_equal(result.command, command)
        vim.uv.fs_unlink(command)
    end)

    it('preserves a forced update across coalesced validation', function()
        stratum._reset_for_tests()
        local fixture = release_fixture(1)
        local install_root = vim.fn.tempname()
        local config = stratum.setup({
            gitseer = {
                auto_start = false,
                install = {
                    source = 'github',
                    root = install_root,
                    github = {
                        base_url = 'file://' .. fixture,
                    },
                },
            },
        })
        local command = config.gitseer.command
        write_file(command, capability_script(1))
        assert(vim.uv.fs_chmod(command, 493))

        local first
        local forced
        installer.install(config.gitseer.install, false, function(result)
            first = result
        end)
        installer.install(config.gitseer.install, true, function(result)
            forced = result
        end)
        assert(
            vim.wait(15000, function()
                return first ~= nil and forced ~= nil
            end, 20),
            'timed out waiting for coalesced Gitseer installation'
        )

        assert_equal(first.ok, true)
        assert_equal(first.installed, true)
        assert_equal(forced.ok, true)
        assert_equal(forced.installed, true)

        vim.fn.delete(fixture, 'rf')
        vim.fn.delete(install_root, 'rf')
    end)
end)
