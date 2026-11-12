# SPDX-License-Identifier: MIT
#
# Elm 0.19.1, built with nixpkgs' recipe for its own Elm compiler on the
# same GHC package set. Elm 0.19.1 needs file-embed and raw-strings-qq,
# which later versions dropped.
#
# The compiler embeds the Elm reactor's front end, which it compiles from
# Elm during its own build. The packages that front end uses come from
# reactor.lock.json, a lockfile `elm-purifier lock` wrote for the reactor/
# directory of the compiler source, through the same package cache that
# buildElmProject uses. The lockfile takes the package versions from
# reactor/elm.json, so the source is fetched while Nix evaluates, with
# builtins.fetchTarball, rather than built as a derivation.
{
  haskell,
  elmPackages,
  callPackage,
  # The shared nix-purifiers library.
  purifier,
}:
let
  inherit (haskell.lib.compose) overrideCabal addBuildDepends;
  haskellPackages = haskell.packages.ghc98;
  src = builtins.fetchTarball {
    url = "https://github.com/elm/compiler/archive/2f6dd29258e880dbb7effd57a829a0470d8da48b.tar.gz";
    sha256 = "sha256-6PXucwc9nFN6TxxsSBuwEkKelThtJ6CLshjfsCmHMsE=";
  };
  reactorHome = callPackage ../build-elm-project/elm-home.nix {
    lockFile = ./reactor.lock.json;
    elmJsonFile = src + "/reactor/elm.json";
    location = "the reactor/ directory of the compiler source";
    inherit purifier;
  };
in
addBuildDepends
  [
    haskellPackages.file-embed
    haskellPackages.raw-strings-qq
  ]
  (
    overrideCabal (drv: {
      version = "0.19.1";
      inherit src;
      # Build.writeDetails writes the same file before the background
      # writer's scope ends. Finish the initial write before returning
      # from dependency setup, so the two writes cannot race or deadlock.
      patches = (drv.patches or [ ]) ++ [ ./details-write.patch ];
      preConfigure = ''
        export ELM_HOME="$PWD/.elm"
        cp -r --no-preserve=mode ${reactorHome} "$ELM_HOME"
      '';
    }) elmPackages.elm
  )
