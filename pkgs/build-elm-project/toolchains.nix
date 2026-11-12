# SPDX-License-Identifier: MIT
#
# The Elm toolchains elm-purifier builds with, by compiler version: the
# compiler; the elm-test releases for it, by the major version of
# elm-explorations/test they run (test-major.nix reads it from elm.json);
# and the arguments that keep elm-test to the locked packages.
#
# One toolchain is nixpkgs' Elm, with nixpkgs' elm-test (pkgs/elm-test,
# which puts its socket where TMPDIR says). The other is Elm 0.19.1, which
# most published applications pin, built by this flake on the same package
# set (pkgs/elm_0_19_1), with elm-test 0.19.1-revision15 for test 2.x and
# 0.19.1-revision9, the last release that runs test 1.x.
#
# elm-test solves the test dependencies itself. The 0.19.1 releases always
# try the packages in ELM_HOME first. The later releases ask the package
# server first for a package project, unless they run with --offline.
{ elm-purifier, elmPackages }:
{
  "0.19.1" = {
    elm = elm-purifier.elm_0_19_1;
    elm-test = {
      "1" = elm-purifier."elm-test_0_19_1-revision9";
      "2" = elm-purifier.elm-test_0_19_1;
    };
    elmTestOfflineArgs = [ ];
  };
}
// (
  if elmPackages.elm.version == "0.19.1" then
    { }
  else
    {
      ${elmPackages.elm.version} = {
        inherit (elmPackages) elm;
        elm-test = {
          "2" = elm-purifier.elm-test;
        };
        elmTestOfflineArgs = [ "--offline" ];
      };
    }
)
