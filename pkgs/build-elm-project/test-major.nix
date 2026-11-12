# SPDX-License-Identifier: MIT
#
# The major version of elm-explorations/test that a project's tests use,
# as a string, read from its elm.json: the exact version an application
# names, or the lower bound of the range a package names. null when the
# project has no elm-explorations/test. bin/elm-purifier applies the same
# rule (test_major), so the CLI and Nix pick the same elm-test.
elmJson:
let
  tests = elmJson."test-dependencies" or { };
  version =
    if elmJson.type == "application" then
      ((tests.direct or { }) // (tests.indirect or { }))."elm-explorations/test" or null
    else
      tests."elm-explorations/test" or null;
in
if version == null then null else builtins.head (builtins.match "[^0-9]*([0-9]+).*" version)
