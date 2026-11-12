# SPDX-License-Identifier: MIT
#
# What `elm-purifier publish` builds: buildElmProject on a project
# directory, outside any flake, with the compiler the CLI runs. Its
# `release` attribute is the release the publish checks against.
{
  # The project directory, as an absolute path string.
  projectDir,
  # The lockfile, which may lie outside the project.
  lockFile,
  # The nixpkgs the CLI was built with.
  nixpkgs,
  # The shared purifier library, as pinned in this flake's flake.lock.
  purifierSrc,
  # The store path of the compiler the lock was made with.
  elm,
}:
let
  standalone = import ./standalone.nix { inherit nixpkgs purifierSrc; };
in
standalone.buildElmProject {
  inherit lockFile;
  src = /. + projectDir;
  elm = builtins.storePath elm;
}
