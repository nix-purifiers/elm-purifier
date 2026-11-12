# SPDX-License-Identifier: MIT
#
# What `elm-purifier prefetch` builds outside a flake: the tree of
# prefetch-tree.nix for a lockfile, with the CLI that runs.
{
  lockFile,
  # The elm.json the lockfile was made for.
  elmJsonFile,
  # The nixpkgs the CLI was built with.
  nixpkgs,
  # The shared purifier library, as pinned in this flake's flake.lock.
  purifierSrc,
  # The store path of the CLI, as a string.
  cli,
}:
let
  pkgs = import nixpkgs { };
in
pkgs.callPackage ./prefetch-tree.nix {
  home = import ./realize.nix {
    inherit
      lockFile
      elmJsonFile
      nixpkgs
      purifierSrc
      ;
  };
  cli = builtins.storePath cli;
}
