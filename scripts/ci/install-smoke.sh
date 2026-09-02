#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
work_root="$(mktemp -d)"
trap 'rm -rf -- "${work_root}"' EXIT

mkdir -p "${work_root}/config" "${work_root}/data" "${work_root}/state" "${work_root}/cache" "${work_root}/doc"
cp -R "${repo_root}/doc/." "${work_root}/doc/"
PLUGIN_ROOT="${repo_root}" \
XDG_CONFIG_HOME="${work_root}/config" \
XDG_DATA_HOME="${work_root}/data" \
XDG_STATE_HOME="${work_root}/state" \
XDG_CACHE_HOME="${work_root}/cache" \
nvim --headless -u NONE -i NONE --cmd 'set loadplugins' \
    --cmd 'lua vim.opt.runtimepath:prepend(vim.env.PLUGIN_ROOT)' \
    -c "helptags ${work_root}/doc" \
    -c "lua require('stratum').setup({ gitseer = { install = { source = 'path', path = '/bin/false' }, args = {}, auto_start = false } })" \
    -c 'silent checkhealth stratum' \
    -c 'qa!'
