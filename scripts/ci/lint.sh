#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"

if ! command -v stylua >/dev/null 2>&1; then
    printf 'CI lint requires stylua.\n' >&2
    exit 1
fi

stylua --check .
