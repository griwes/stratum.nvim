describe('stratum', function()
    it('loads and exposes setup', function()
        local plugin = require('stratum')

        assert(type(plugin.setup) == 'function')
        assert(type(plugin.install_gitseer) == 'function')
        assert(type(plugin.gitseer_installation) == 'function')
    end)
end)
