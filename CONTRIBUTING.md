# Contributing

## Licensing and provenance

Contributions are accepted under Apache-2.0. Do not copy source from a project unless its license is compatible with Apache-2.0, and identify any externally derived implementation or data in the pull request. Dependency changes must preserve the repository's license policy.

## Development

- Install a supported Neovim version and Stylua 2.5.2.
- Run `scripts/ci/run.sh` before submitting a change. It checks formatting, the headless test suite, and the clean-install smoke.
- Add LuaLS annotations to public and structurally important Lua interfaces.

Keep changes focused and include tests for observable behavior. Use your configured Git author identity and write imperative commit subjects that end with a period.

## Pull requests

Describe the user-visible behavior, compatibility implications, and validation performed. Update the README and Vim help when public configuration, commands, or APIs change. Security-sensitive changes should explain the trust boundary they alter without publishing an active vulnerability.

