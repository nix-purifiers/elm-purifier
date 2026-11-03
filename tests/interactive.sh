#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Tests the developer's loop on a real project, outside the Nix sandbox:
# prefetch, then the tools it links on the locked packages, the editor,
# the stale-lockfile messages and the publish check. The sandboxed
# equivalent on a fixture is the conformance-offline check. Run it from the
# repository root; prefetch needs the network.
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD
cli=$(nix build --no-link --print-out-paths .#cli)/bin/elm-purifier
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
  echo "interactive.sh: $*" >&2
  exit 1
}

# The package directories under the ELM_HOME that prefetch keeps for a
# project.
installed() {
  (cd "$1/elm-stuff/elm-purifier/home" && find . -mindepth 5 -maxdepth 5 -type d -path './*/packages/*' | sort)
}

# The real application and the real package, at their pinned commits.
project_of() {
  nix flake prefetch --json "github:$1" | nix shell 'nixpkgs#jq' -c jq -r .storePath
}
spa="$work/elm-spa-example"
cp -r "$(project_of rtfeldman/elm-spa-example/cb32acd73c3d346d0064e7923049867d8ce67193)" "$spa"
chmod -R u+w "$spa"
cp tests/real-world/elm-spa-example/elm-purifier.lock.json "$spa/"
cp -r tests/fixtures/package "$work/package"
chmod -R u+w "$work/package"

echo "== prefetch, then the compiler and the tests run on the locked packages"
(cd "$spa" && "$cli" prefetch)
bin="$spa/elm-stuff/elm-purifier/bin"
(cd "$spa" && PATH="$bin:$PATH" elm make src/Main.elm --output="$work/spa.js")
(cd "$spa" && PATH="$bin:$PATH" elm-test)
locked=$(nix shell 'nixpkgs#jq' -c jq -r '.hashes | keys[]' "$spa/elm-purifier.lock.json" | wc -l)
[ "$(installed "$spa" | wc -l)" -eq "$locked" ] || fail "the project holds packages the lock does not record"

echo "== elm-format runs"
cp "$spa/src/Main.elm" "$work/Main.elm"
(cd "$spa" && PATH="$bin:$PATH" elm-format --yes "$work/Main.elm" >/dev/null)
grep -q '^module Main' "$work/Main.elm" || fail "elm-format did not write a module"

echo "== the editor reports the planted error"
cp -r tests/fixtures/app "$work/lsp"
chmod -R u+w "$work/lsp"
printf '\n\nprobe : Int\nprobe =\n    notDefinedAnywhere\n' >> "$work/lsp/src/Main.elm"
(cd "$work/lsp" && "$cli" prefetch)
(cd "$work/lsp" && PATH="$work/lsp/elm-stuff/elm-purifier/bin:$PATH" nix shell 'nixpkgs#python3' -c \
  python3 -I "$root/tests/lsp-probe.py" src/Main.elm -- elm-language-server --stdio) |
  grep -q notDefinedAnywhere || fail "elm-language-server reported nothing about the planted error"

echo "== publish checks the documentation against the Nix build"
(cd "$work/package" && "$cli" publish --check)

echo "== a changed elm.json is refused with the command to run"
sed 's/"1.0.0"/"1.0.1"/' "$work/package/elm.json" >"$work/elm.json"
mv "$work/elm.json" "$work/package/elm.json"
(cd "$work/package" && PATH="$work/package/elm-stuff/elm-purifier/bin:$PATH" "$cli" prefetch 2>&1 || true) |
  grep -q 'run `elm-purifier lock`' || fail "prefetch did not name the command that writes the lockfile"

echo "== a tampered hash names the lockfile and the command to run"
cp -r tests/fixtures/app "$work/tampered"
chmod -R u+w "$work/tampered"
# Tampers the first hash only.
awk '!done && sub(/"sha256-/, "\"sha256-AAAA") { done = 1 } 1' \
  "$work/tampered/elm-purifier.lock.json" >"$work/tampered.lock.json"
mv "$work/tampered.lock.json" "$work/tampered/elm-purifier.lock.json"
(cd "$work/tampered" && "$cli" prefetch 2>&1 || true) |
  grep -q 'run `elm-purifier lock`' || fail "a tampered hash gave no lock hint"

echo "== a lockfile that does not parse names the command to run"
cp -r tests/fixtures/app "$work/malformed"
chmod -R u+w "$work/malformed"
echo '{ "version": 3,' > "$work/malformed/elm-purifier.lock.json"
(cd "$work/malformed" && "$cli" prefetch 2>&1 || true) |
  grep -q 'run `elm-purifier lock`' || fail "a malformed lockfile gave no lock hint"

echo "interactive.sh: all passed"
