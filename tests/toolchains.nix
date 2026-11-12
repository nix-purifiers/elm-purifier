# SPDX-License-Identifier: MIT
let
  pinned = {
    elm_0_19_1 = "pinned-compiler";
    "elm-test_0_19_1-revision9" = "old-tests";
    elm-test_0_19_1 = "pinned-tests";
    elm-test = "current-tests";
  };
  toolchains =
    version:
    import ../pkgs/build-elm-project/toolchains.nix {
      elm-purifier = pinned;
      elmPackages.elm = { inherit version; };
    };
  old = toolchains "0.19.1";
  current = toolchains "0.19.2";
in
assert builtins.attrNames old == [ "0.19.1" ];
assert old."0.19.1".elm == "pinned-compiler";
assert old."0.19.1".elm-test."1" == "old-tests";
assert old."0.19.1".elmTestOfflineArgs == [ ];
assert
  builtins.attrNames current == [
    "0.19.1"
    "0.19.2"
  ];
assert current."0.19.1".elm == "pinned-compiler";
assert current."0.19.2".elm.version == "0.19.2";
assert current."0.19.2".elmTestOfflineArgs == [ "--offline" ];
true
