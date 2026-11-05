# SPDX-License-Identifier: MIT
#
# buildElmProject: the sandboxed builds of an Elm project, from elm.json
# and the lockfile `elm-purifier lock` writes.
#
# This file is a package for callPackage. It takes the packages it needs by
# name: `stdenvNoCC`, `callPackage`, `elmPackages`, the scope `elm-purifier`
# (the packages of pkgs/) and the shared library `purifier`. The default
# overlay of the flake adds the builder it returns to the scope as
# `elm-purifier.buildElmProject`, so `.override` on the builder replaces any
# of them, and a package written for callPackage takes the scope by name:
#
#   { elm-purifier }: (elm-purifier.buildElmProject { src = ./.; }).packages.Main
#
# Every attribute name of the result is known at evaluation time, from the
# lockfile and elm.json. The result has
#
#   packages.<module>  for an application, the compiled JavaScript of each
#                      entry module the lockfile records, at <module>.js
#   packages.docs      for a package, its docs.json
#   release            for a package, what `elm-purifier publish` checks
#                      before it publishes: docs.json and the files the
#                      package server takes from the tag (elm.json,
#                      README.md, LICENSE and src/)
#   tests              elm-test on tests/, when the lock covers them
#   fetches            the entries of the lock that `readLock` returns: an
#                      archive entry of the shared library for each
#                      package, at its path in the package cache
#
# `release` of an application and `tests` of a lock without tests stop
# evaluation with a message that says why.
{
  lib,
  stdenvNoCC,
  callPackage,
  elmPackages,
  elm-purifier,
  purifier,
  runCommand,
  python3,
}:
{
  # The tree the project is in, as a path: the flake's own source, or a
  # source fetched while Nix evaluates (a flake input, builtins.fetchTarball).
  # The builder reads elm.json and the lockfile during evaluation, so a
  # source that is a derivation, such as fetchFromGitHub, would have to be
  # built first (import from derivation).
  src,
  webjars ? { },
  # The directory of elm.json, relative to `src`. A project whose
  # source-directories reach outside its directory takes the enclosing tree
  # as `src` and its own directory here.
  subdirectory ? ".",
  # The lockfile. The default is the one `elm-purifier lock` writes beside
  # elm.json; a lockfile kept outside the project, such as in a packaging
  # flake, is passed here, and the build then ignores any copy in `src`.
  lockFile ? src + "/${subdirectory}/elm-purifier.lock.json",
  # The fetchers that the shared library's `fetchEntry` and `tree` take,
  # such as a `fetchurl` that sends credentials or asks a company mirror.
  fetchers ? { },
  # Compiles applications with --optimize. An application that uses
  # Debug cannot be optimized.
  optimize ? true,
  # The Elm compiler. The default is the one of the version the lock was
  # made with.
  elm ? null,
  # The elm-test that `tests` runs. The default is the release for the
  # compiler version the lock was made with and the major version of
  # elm-explorations/test in elm.json (see toolchains.nix).
  elm-test ? null,
  # Filters `src` before it is copied into the store, as the `filter` of
  # builtins.path. The default leaves out version control, elm-stuff,
  # node_modules, the results of nix build and elm-purifier lockfiles, so
  # a lockfile passed as `lockFile` is the only one the build sees.
  srcFilter ? null,
}:
let
  projectDir = src + "/${subdirectory}";
  elmJsonFile = projectDir + "/elm.json";
  elmJson = builtins.fromJSON (builtins.readFile elmJsonFile);

  # Where the project is, for messages: the directory in the source, which
  # a developer recognizes, rather than its path in the store.
  location = if subdirectory == "." then "the project directory" else "the directory ${subdirectory}";
  read = import ./lock.nix { inherit lockFile elmJsonFile location; };
  # The lock in memory, checked by the shared library: a lockfile that is
  # not valid for elm.json stops evaluation with its problems.
  lock = purifier.checkLock read.lock;
  # The rest of what lock.nix read, once the lock passed the check.
  checked = builtins.seq lock read;

  toolchain =
    (import ./toolchains.nix { inherit elm-purifier elmPackages; }).${checked.elmVersion} or {
      elm = throw "elm-purifier: there is no Elm ${checked.elmVersion} compiler for the lock; pass `elm`.";
      elm-test = { };
      elmTestOfflineArgs = [ ];
    };
  compiler = if elm != null then elm else toolchain.elm;
  testMajor = import ./test-major.nix elmJson;
  elm-test' =
    if elm-test != null then
      elm-test
    else if testMajor == null then
      throw "elm-purifier: the tests need elm-explorations/test in the test-dependencies of elm.json."
    else
      toolchain.elm-test.${testMajor}
        or (throw "elm-purifier: there is no elm-test for Elm ${checked.elmVersion} with elm-explorations/test ${testMajor}.x; pass `elm-test`.");

  elmHome = callPackage ./elm-home.nix {
    inherit
      lockFile
      elmJsonFile
      location
      fetchers
      purifier
      ;
  };

  defaultSrcFilter =
    path: type:
    let
      base = baseNameOf path;
    in
    !(
      base == ".git"
      || base == "elm-stuff"
      || base == "node_modules"
      || base == "elm-purifier.lock.json"
      || lib.hasPrefix "result" base
    );

  filteredSrc = builtins.path {
    path = src;
    name = "elm-source";
    filter = if srcFilter != null then srcFilter else defaultSrcFilter;
  };

  # The setup every build shares: a writable copy of the package cache as
  # ELM_HOME, and the project directory as the working directory.
  setup = ''
    export HOME="$TMPDIR/home"
    export ELM_HOME="$TMPDIR/elm-home"
    mkdir -p "$HOME"
    cp -r --no-preserve=mode ${elmHome} "$ELM_HOME"
    cd ${lib.escapeShellArg subdirectory}
  '';

  isApplication = elmJson.type == "application";

  # Every build checks the lock first, so a lockfile that is not valid for
  # elm.json stops evaluation with the problems lock.nix found.
  mkBuild =
    name: attrs:
    assert builtins.isAttrs lock;
    stdenvNoCC.mkDerivation (
      {
        inherit name;
        src = filteredSrc;
        dontConfigure = true;
        dontFixup = true;
      }
      // attrs
    );

  rawApplications = lib.mapAttrs (
    module:
    { main }:
    mkBuild "elm-${module}" {
      nativeBuildInputs = [ compiler ];
      buildPhase = ''
        runHook preBuild
        ${setup}
        elm make ${lib.escapeShellArg main} ${lib.optionalString optimize "--optimize"} \
          --output="$TMPDIR/${module}.js"
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        install -Dm644 "$TMPDIR/${module}.js" "$out/${module}.js"
        runHook postInstall
      '';
    }
  ) lock.outputs;

  applications = lib.mapAttrs (
    module: package:
    package
    // {
      projections =
        (purifier.resourceProjections {
          producer = package;
          roots."${module}.js" = "${module}.js";
          inherit runCommand python3;
        })
        // lib.optionalAttrs (builtins.hasAttr module webjars) (
          purifier.webjarProjections (
            webjars.${module}
            // {
              producer = package;
              assets = package;
              inherit runCommand python3;
            }
          )
        );
    }
  ) rawApplications;

  packageName = "elm-${lib.replaceStrings [ "/" ] [ "-" ] elmJson.name}-${elmJson.version}";

  rawDocs = mkBuild "${packageName}-docs" {
    nativeBuildInputs = [ compiler ];
    buildPhase = ''
      runHook preBuild
      ${setup}
      elm make --docs="$TMPDIR/docs.json"
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      install -Dm644 "$TMPDIR/docs.json" "$out/docs.json"
      runHook postInstall
    '';
  };

  docs = rawDocs // {
    projections = purifier.resourceProjections {
      producer = rawDocs;
      roots."docs.json" = "docs.json";
      inherit runCommand python3;
    };
  };

  release = mkBuild packageName {
    dontBuild = true;
    installPhase = ''
      runHook preInstall
      cd ${lib.escapeShellArg subdirectory}
      mkdir -p "$out"
      cp ${docs}/docs.json "$out/docs.json"
      cp -r elm.json src "$out/"
      for file in README.md LICENSE; do
        if [ -e "$file" ]; then cp "$file" "$out/"; fi
      done
      runHook postInstall
    '';
  };

  tests = mkBuild "elm-tests" {
    nativeBuildInputs = [
      compiler
      elm-test'
    ];
    buildPhase = ''
      runHook preBuild
      ${setup}
      # elm-test solves the test dependencies itself, and the arguments of
      # the toolchain keep it to the locked packages (see toolchains.nix).
      elm-test --compiler ${compiler}/bin/elm ${lib.escapeShellArgs toolchain.elmTestOfflineArgs}
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      touch "$out"
      runHook postInstall
    '';
  };

in
assert
  builtins.all (module: builtins.hasAttr module lock.outputs) (builtins.attrNames webjars)
  || throw "elm-purifier: webjars must name compiled application entry modules";
assert
  isApplication
  || webjars == { }
  || throw "elm-purifier: only compiled applications have WebJar projections";
{
  packages = if isApplication then applications else { inherit docs; };
  release =
    if isApplication then
      throw "elm-purifier: ${location} holds an application, and only a package has a release to publish."
    else
      release;
  tests =
    if checked.tests then
      tests
    else
      throw "elm-purifier: the lockfile ${baseNameOf lockFile} of ${location} does not cover the tests. Run `elm-purifier lock --tests` there.";
  fetches = lock.entries;
}
