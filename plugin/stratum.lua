if vim.g.loaded_stratum == 1 then
    return
end

vim.g.loaded_stratum = 1

vim.api.nvim_create_user_command('StratumInstallGitseer', function(opts)
    require('stratum').install_gitseer({ force = opts.bang }, function(result)
        if result.ok then
            local action = result.installed and 'installed' or 'validated'
            vim.notify(('Gitseer %s at %s'):format(action, result.command), vim.log.levels.INFO)
        else
            vim.notify(result.error or 'Gitseer installation failed', vim.log.levels.ERROR)
        end
    end)
end, {
    bang = true,
    desc = 'Install or validate the configured Gitseer executable',
})
