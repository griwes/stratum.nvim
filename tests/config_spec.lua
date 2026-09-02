local stratum = require('stratum')

local function assert_equal(actual, expected)
    assert(actual == expected, ('expected %q, got %q'):format(tostring(expected), tostring(actual)))
end

describe('stratum config', function()
    it('normalizes default setup without side effects', function()
        stratum._reset_for_tests()

        local config = stratum.setup()
        local status = stratum.status()

        assert_equal(config.gitseer.install.source, 'github')
        assert_equal(config.gitseer.install.version, 'nightly')
        assert(config.gitseer.command:find('/github/nightly/bin/gitseer', 1, true))
        assert_equal(config.gitseer.auto_start, true)
        assert_equal(status.state, 'stopped')
        assert_equal(status.repos, 0)
    end)

    it('defaults Cargo installs to Gitseer main', function()
        stratum._reset_for_tests()

        local config = stratum.setup({
            gitseer = {
                install = {
                    source = 'cargo',
                },
            },
        })

        assert_equal(config.gitseer.install.version, 'main')
        assert(config.gitseer.command:find('/cargo/main/bin/gitseer', 1, true))
    end)

    it('accepts an explicit user-managed executable path', function()
        stratum._reset_for_tests()

        local config = stratum.setup({
            gitseer = {
                install = {
                    source = 'path',
                    path = '/tmp/gitseer',
                },
                args = { '--trace' },
            },
        })

        assert_equal(config.gitseer.command, '/tmp/gitseer')
        assert_equal(config.gitseer.install.version, 'manual')
        assert_equal(config.gitseer.args[1], '--trace')
    end)

    it('rejects malformed config with clear errors', function()
        stratum._reset_for_tests()

        local ok, err = pcall(stratum.setup, {
            gitseer = {
                install = {
                    source = 'path',
                },
            },
        })

        assert(not ok)
        assert(tostring(err):find('gitseer.install.path', 1, true))
    end)
end)
