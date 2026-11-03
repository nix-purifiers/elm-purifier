#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# conformance-update: `elm-purifier update` on a fixture that pins an old
# version moves it, and both files then pass the stale check: elm.json
# names the newer version, and the lockfile is valid for that elm.json, so
# prefetch accepts it and a lock run reproduces it byte for byte. Run it
# from the repository root; it needs the network.
set -euo pipefail
cd "$(dirname "$0")/.."
cli=$(nix build --no-link --print-out-paths .#cli)/bin/elm-purifier
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cp -r tests/fixtures/update "$work/project"
chmod -R u+w "$work/project"
cd "$work/project"

"$cli" lock --lockfile "$work/lock.json"
grep -q '"elm/json": "1.1.2"' elm.json || { echo "the fixture does not pin elm/json 1.1.2" >&2; exit 1; }
cp "$work/lock.json" "$work/lock-before.json"

"$cli" update --lockfile "$work/lock.json"
if grep -q '"elm/json": "1.1.2"' elm.json; then
  echo "update left elm/json at 1.1.2" >&2
  exit 1
fi
cmp -s "$work/lock.json" "$work/lock-before.json" && {
  echo "update left the lockfile as it was" >&2
  exit 1
}

# The stale check: prefetch refuses a lockfile that does not match elm.json.
"$cli" prefetch --lockfile "$work/lock.json"

# A lock run on the updated project reproduces the lockfile.
cp "$work/lock.json" "$work/lock-updated.json"
"$cli" lock --lockfile "$work/lock.json"
cmp "$work/lock.json" "$work/lock-updated.json"

# Named packages: pin elm/json back, then update only it.
sed 's|"elm/json": "[0-9.]*"|"elm/json": "1.1.2"|' elm.json >elm.json.new
mv elm.json.new elm.json
"$cli" lock --lockfile "$work/lock.json"
"$cli" update --lockfile "$work/lock.json" elm/json
grep -q '"elm/json": "1.1.4"' elm.json
"$cli" prefetch --lockfile "$work/lock.json"
echo "conformance-update: passed"
