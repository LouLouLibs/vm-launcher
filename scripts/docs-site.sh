#!/usr/bin/env bash
# Build or preview the documentation site (VitePress; sources in docs/).
#   scripts/docs-site.sh build     # site/.vitepress/dist, fails on dead links
#   scripts/docs-site.sh preview   # build, then serve at http://localhost:4173/vm-launcher/
# The built dist/ is static files; serve it with any web server.
# Node comes from nixpkgs when it isn't on PATH; nothing in site/ ships.
# Optional: VMLAUNCHER_DOCS_BASE (default /vm-launcher/).
set -Eeuo pipefail
trap 'echo "docs-site.sh: line $LINENO failed" >&2' ERR

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SITE="$ROOT/site"

usage() { sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
[[ $# -eq 1 ]] || usage

# Run a command in site/ with node/npm available (nixpkgs#nodejs if missing).
with_node() {
    if command -v npm >/dev/null; then
        (cd "$SITE" && bash -c "$1")
    else
        (cd "$SITE" && nix shell nixpkgs#nodejs -c bash -c "$1")
    fi
}

build() {
    if [[ ! -d "$SITE/node_modules" ]]; then
        if [[ -f "$SITE/package-lock.json" ]]; then
            with_node "npm ci --no-fund --no-audit"
        else
            with_node "npm install --no-fund --no-audit"
        fi
    fi
    with_node "npx vitepress build"
}

case "$1" in
    build) build ;;
    preview) build && with_node "npx vitepress preview" ;;
    *) usage ;;
esac
