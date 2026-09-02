local source = assert(vim.env.STRATUM_GITSEER_INSTALL_SOURCE, 'STRATUM_GITSEER_INSTALL_SOURCE is required')
local install_root = assert(vim.env.STRATUM_GITSEER_INSTALL_ROOT, 'STRATUM_GITSEER_INSTALL_ROOT is required')

local install = {
    source = source,
    auto = false,
    root = install_root,
}

if source == 'cargo' then
    install.cargo = {
        path = assert(vim.env.GITSEER_CARGO_PATH, 'GITSEER_CARGO_PATH is required for Cargo installation'),
    }
end

local stratum = require('stratum')
local config = stratum.setup({
    gitseer = {
        auto_start = false,
        install = install,
    },
})

local result
local command = stratum.install_gitseer({}, function(completed)
    result = completed
end)

assert(
    vim.wait(600000, function()
        return result ~= nil
    end, 20),
    'timed out waiting for Stratum to install Gitseer'
)
assert(result.ok, result.error)
assert(result.installed, 'the smoke expected Stratum to create a managed installation')
assert(command == config.gitseer.command, 'the public install API returned the wrong command')
assert(result.command == command, 'the install result returned the wrong command')
assert(vim.fn.executable(command) == 1, 'the installed Gitseer command is not executable')

local installation = stratum.gitseer_installation()
assert(installation.source == source, 'the installation reports the wrong source')
assert(installation.command == command, 'the installation reports the wrong command')
assert(installation.installed, 'the installation does not report the installed executable')

local capabilities = vim.system({ command, 'capabilities' }, { text = true }):wait()
assert(capabilities.code == 0, capabilities.stderr)
local document = vim.json.decode(capabilities.stdout)
assert(document.name == 'gitseer', 'the installed executable returned the wrong capability name')
assert(document.protocol.version == 1, 'the installed executable returned an incompatible protocol revision')

io.write(('Stratum installed and discovered Gitseer from %s\n'):format(source))
