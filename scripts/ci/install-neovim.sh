#!/usr/bin/env bash
set -euo pipefail

version="${1:?usage: install-neovim.sh VERSION}"
install_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/neovim-${version}"
archive="${install_root}.tar.gz"
url="https://github.com/neovim/neovim/releases/download/${version}/nvim-linux-x86_64.tar.gz"

mkdir -p "${install_root}"
curl --fail --location --retry 5 --retry-delay 2 --output "${archive}" "${url}"
tar --extract --gzip --file "${archive}" --directory "${install_root}" --strip-components=1

printf '%s\n' "${install_root}/bin" >> "${GITHUB_PATH:?GITHUB_PATH is required}"
"${install_root}/bin/nvim" --version
