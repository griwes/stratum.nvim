#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"

if ! command -v nvim >/dev/null 2>&1; then
    printf 'CI tests require Neovim.\n' >&2
    exit 1
fi

xdg_root="$(mktemp -d "${TMPDIR:-/tmp}/nvim-plugin-ci.XXXXXX")"
trap 'rm -rf -- "${xdg_root}"' EXIT

export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-${xdg_root}/config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-${xdg_root}/data}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-${xdg_root}/state}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-${xdg_root}/cache}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-${xdg_root}/runtime}"

mkdir -p "${XDG_CONFIG_HOME}" "${XDG_DATA_HOME}" "${XDG_STATE_HOME}" "${XDG_CACHE_HOME}" "${XDG_RUNTIME_DIR}"
chmod 700 "${XDG_RUNTIME_DIR}"

nvim --headless -i NONE -u tests/minimal_init.lua -l tests/run.lua
