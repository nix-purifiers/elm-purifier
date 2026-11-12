# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds one attribute to the package set, the
# scope `pkgs.elm-purifier`, made with lib.makeScope. The scope holds the
# packages of pkgs/ (`.elm_0_19_1` and the elm-test releases), the command
# `.cli`, and the builder `.buildElmProject` (nix/lib/build-elm-project.nix).
# The builder is a package for callPackage in the scope: it takes the packages
# it needs by name, and `.buildElmProject.override` replaces any of them.
# `elm-purifier.overrideScope` replaces what everything in the scope shares.
# A package written for callPackage takes the scope by name. A consumer that
# lists this flake in `projects` holds the overlay as `elm-purifier/default`,
# which its package sets apply by default.
#
# The command carries the source of the purifier input of this flake, pinned
# in flake.lock, for what it builds outside a flake build.
{ closure-lib, closure-inputs, ... }:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "elm-purifier";
in
{
  overlay =
    final: prev:
    let
      base = packages final prev;
    in
    base
    // {
      elm-purifier = base.elm-purifier.overrideScope (
        self: _: {
          cli = self.callPackage ../../pkgs/cli {
            version = import ../../pkgs/version.nix;
            purifierSrc = closure-inputs.purifier;
          };
          buildElmProject = self.callPackage ../../nix/lib/build-elm-project.nix {
            inherit (closure-lib) purifier;
          };
        }
      );
    };
}
