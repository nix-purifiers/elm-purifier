#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# conformance-relock: locks every fixture under tests/fixtures, the reactor
# of the Elm 0.19.1 compiler source, and the projects under tests/real-world
# at their pinned commits, and compares each result with the committed
# lockfile. A relock of an unchanged project reproduces its lockfile byte
# for byte.
#
#   tests/conformance-relock.sh           compares
#   tests/conformance-relock.sh --write   writes the new lockfiles, after a
#                                         change to the lock format
#
# Run it from the repository root; it needs the network.
set -euo pipefail
cd "$(dirname "$0")/.."
write=false
[ "${1:-}" = --write ] && write=true
cli=$(nix build --no-link --print-out-paths .#cli)/bin/elm-purifier
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export NODE_USE_ENV_PROXY=1

# Locks the project in $1 into the lockfile $2, and compares it with the
# committed lockfile $3, or replaces that. Start from the committed lock:
# without it a package's ranges legitimately resolve newer releases, and
# multi-entry applications lose their recorded entry-module selection.
relock() {
  local project=$1 lockfile=$2 committed=$3
  cp "$committed" "$lockfile"
  (cd "$project" && "$cli" lock --lockfile "$lockfile")
  if $write; then
    cp "$lockfile" "$committed"
  else
    cmp "$lockfile" "$committed" || {
      echo "conformance-relock: the lock of $committed differs from the committed one" >&2
      exit 1
    }
  fi
}

# The lockfiles of the fixtures lie beside their elm.json, except the
# external fixture, whose lockfile is kept in tests/external.
cp -r tests/fixtures "$work/fixtures"
chmod -R u+w "$work/fixtures"
for project in app package shared/app; do
  relock "$work/fixtures/$project" "$work/fixtures/$project/elm-purifier.lock.json" \
    "tests/fixtures/$project/elm-purifier.lock.json"
done
relock "$work/fixtures/external" "$work/external.lock.json" tests/external/elm-purifier.lock.json

# The reactor of the compiler source, whose packages the Elm 0.19.1
# compiler is built with.
src=$(nix build --no-link --print-out-paths .#elm_0_19_1.src)
cp -r "$src/reactor" "$work/reactor"
chmod -R u+w "$work/reactor"
relock "$work/reactor" "$work/reactor.lock.json" pkgs/elm_0_19_1/reactor.lock.json

# The pinned commits are the ones tests/default.nix fetches.
for project in rtfeldman/elm-spa-example/cb32acd73c3d346d0064e7923049867d8ce67193 \
  elm-community/list-extra/46a4817f2df99ce3379390db21348177ac95056d; do
  name=$(echo "$project" | cut -d/ -f2)
  source=$(nix flake prefetch --json "github:$project" | nix shell 'nixpkgs#jq' -c jq -r .storePath)
  cp -r "$source" "$work/$name"
  chmod -R u+w "$work/$name"
  relock "$work/$name" "$work/$name.lock.json" "tests/real-world/$name/elm-purifier.lock.json"
done
echo "conformance-relock: passed"
