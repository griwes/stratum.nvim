describe('stratum', function()
    it('loads and exposes setup', function()
        local plugin = require('stratum')

        assert(type(plugin.setup) == 'function')
    end)
end)
