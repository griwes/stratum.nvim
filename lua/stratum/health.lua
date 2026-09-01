local M = {}

function M.check()
    vim.health.start('stratum.nvim')

    if vim.fn.has('nvim-0.11') == 1 then
        vim.health.ok('Neovim 0.11 or newer')
    else
        vim.health.error('Neovim 0.11 or newer is required')
    end

    local config = require('stratum').config
    local command = config.gitseer.command
    if vim.fn.executable(command) == 1 then
        vim.health.ok('Gitseer is executable: ' .. command)
    else
        vim.health.error('Gitseer is not executable: ' .. command)
    end

    if pcall(require, 'statuesque') then
        vim.health.ok('Statuesque integration is available')
    else
        vim.health.info('Statuesque integration is not installed')
    end
end

return M
