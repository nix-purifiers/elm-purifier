# SPDX-License-Identifier: MIT
#
# The package cache of a lockfile, built outside a flake: the same
# derivation the sandboxed build uses (elm-home.nix). `elm-purifier lock`
# checks a new lockfile against it, `elm-purifier publish` compiles the
# documentation on it, and `elm-purifier prefetch` links it into the
# project (prefetch.nix).
{
  lockFile,
  # The elm.json the lockfile was made for.
  elmJsonFile,
  # The nixpkgs the CLI was built with.
  nixpkgs,
  # The shared purifier library, as pinned in this flake's flake.lock.
  # Its root default.nix is its entry point for code outside a flake.
  purifierSrc,
}:
let
  pkgs = import nixpkgs { };
  purifier = import purifierSrc { inherit (pkgs) lib; };
in
pkgs.callPackage ./elm-home.nix { inherit lockFile elmJsonFile purifier; }
