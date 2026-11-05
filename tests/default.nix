# SPDX-License-Identifier: MIT
#
# The checks: the CLI; the fixtures under tests/fixtures built from their
# committed lockfiles in the sandbox, each output run where it can run,
# with the test suites of the fixtures that have them; two published
# projects; and the conformance checks of the purifier contract
# (CONTRACT.md of the shared purifier library). conformance-relock needs
# the package server, so it is a job of the CI workflow instead
# (tests/conformance-relock.sh).
{
  # A package set with the default overlay of this flake applied, which has
  # the scope `elm-purifier` with `buildElmProject`.
  pkgs,
  cli,
  # The source of the shared purifier library, as pinned in flake.lock.
  purifierSrc,
}:
let
  inherit (pkgs) lib runCommand nodejs;
  purifier = import purifierSrc { inherit lib; };
  build = pkgs.elm-purifier.buildElmProject;

  app = build { src = ./fixtures/app; };
  package = build { src = ./fixtures/package; };
  shared = build {
    src = ./fixtures/shared;
    subdirectory = "app";
  };

  # Runs the worker MODULE of a compiled application with the flags "Nix"
  # and compares what it prints.
  runsWorker =
    name: application: module: expected:
    runCommand name { nativeBuildInputs = [ nodejs ]; } ''
      actual=$(node ${./run-worker.js} ${application}/${module}.js ${module} Nix)
      if [ "$actual" != ${lib.escapeShellArg expected} ]; then
        echo "${module} printed: $actual" >&2
        echo "expected: "${lib.escapeShellArg expected} >&2
        exit 1
      fi
      touch $out
    '';

  # Published projects, pinned to a commit, with lockfiles `elm-purifier
  # lock` wrote for those commits (tests/real-world/<project>). The builder
  # reads elm.json while Nix evaluates, so the sources are fetched during
  # evaluation, with builtins.fetchTarball, rather than built as
  # derivations.
  github =
    repository: rev: sha256:
    builtins.fetchTarball {
      url = "https://github.com/${repository}/archive/${rev}.tar.gz";
      inherit sha256;
    };
  realWorld = {
    # An Elm 0.19.1 single-page application with elm-explorations/test 1.x.
    elm-spa-example = build {
      src =
        github "rtfeldman/elm-spa-example" "cb32acd73c3d346d0064e7923049867d8ce67193"
          "sha256-iYd7/fzdkd3KoGLLcBTVNa6O1KcYgrlIWll4xkwI72o=";
      lockFile = ./real-world/elm-spa-example/elm-purifier.lock.json;
    };
    # A widely used package with elm-explorations/test 2.x.
    list-extra = build {
      src =
        github "elm-community/list-extra" "46a4817f2df99ce3379390db21348177ac95056d"
          "sha256-gPMFO2b+XApTjDifbNo9p5lDZcK9sy5IXY1lPhnEOmM=";
      lockFile = ./real-world/list-extra/elm-purifier.lock.json;
    };
  };

  # The checks of the lockfile messages. Each case evaluates
  # `packages.Main` of the app fixture (or of `src`) with an edited
  # lockfile, with nix-instantiate on a store in the build directory, and
  # the check reads the error it prints. A control case with the committed
  # lockfile must evaluate, so the errors come from the edits.
  appLockFile = ./fixtures/app/elm-purifier.lock.json;
  appLock = builtins.fromJSON (builtins.readFile appLockFile);
  # A lock with its contentHash written again, as an edit by hand that
  # also fixes the hash.
  rehashed = lock: lock // { contentHash = import ../nix/lib/lock-hash.nix lock; };
  lockFileOf = name: lock: builtins.toFile "${name}.lock.json" (builtins.toJSON lock);
  messageCheck =
    name: patterns: cases:
    let
      expression = args: ''
        let
          standalone = import ${../.}/nix/lib/standalone.nix {
            nixpkgs = ${pkgs.path};
            purifierSrc = ${purifierSrc};
          };
          project = standalone.buildElmProject ({ src = ${./fixtures/app}; } // ${args});
        in
        builtins.seq project.packages.Main "evaluated"
      '';
      file = caseName: args: builtins.toFile "${name}-${caseName}.nix" (expression args);
    in
    runCommand name { nativeBuildInputs = [ pkgs.nix ]; } ''
      export HOME="$TMPDIR/home" NIX_STATE_DIR="$TMPDIR/state" NIX_STORE_DIR="$TMPDIR/store"
      export NIX_LOG_DIR="$TMPDIR/log" NIX_CONF_DIR="$TMPDIR/conf"
      unset NIX_REMOTE
      mkdir -p "$HOME" "$NIX_CONF_DIR"
      nix-instantiate --eval --strict ${file "control" "{ lockFile = ${appLockFile}; }"} | grep -qx '"evaluated"'
      ${lib.concatStrings (
        lib.mapAttrsToList (caseName: args: ''
          echo "== ${caseName}"
          if nix-instantiate --eval --strict ${file caseName args} 2> error; then
            echo "${caseName}: the edited lockfile evaluated" >&2
            exit 1
          fi
          cat error
          ${lib.concatMapStrings (pattern: ''
            grep -qF ${lib.escapeShellArg pattern} error
          '') patterns}
        '') cases
      )}
      touch $out
    '';

  # `nix build --rebuild` of an output: a second build of the same
  # derivation with one more attribute, which gives the same files.
  rebuilds =
    name: outputs:
    runCommand name { } ''
      ${lib.concatMapStrings (output: ''
        diff -r ${output} ${
          output.overrideAttrs (_: {
            rebuildProbe = "second build";
          })
        }
      '') outputs}
      touch $out
    '';

  # What `elm-purifier prefetch` builds for the app fixture, and a
  # nix-build in its place that links it, for the offline check. The
  # sandbox has no network, so the everyday loop there runs on what the
  # prefetch put in the project.
  prefetched = pkgs.callPackage ../nix/lib/prefetch-tree.nix {
    home = pkgs.callPackage ../nix/lib/elm-home.nix {
      lockFile = appLockFile;
      elmJsonFile = ./fixtures/app/elm.json;
      inherit purifier;
    };
    inherit cli;
  };
  prefetchedNixBuild = pkgs.writeShellScriptBin "nix-build" ''
    while [ $# -gt 0 ]; do
      if [ "$1" = --out-link ]; then link=$2; fi
      shift
    done
    ln -sfn ${prefetched} "$link"
    echo ${prefetched}
  '';

  # A fixture kept external: its directory holds only elm.json and its
  # source, and its lockfile is kept in tests/external.
  external = build {
    src = ./fixtures/external;
    lockFile = ./external/elm-purifier.lock.json;
  };
in
{
  documentation-resources = import ./resource-consumer.nix {
    inherit pkgs;
    projection = package.packages.docs.projections.resources;
  };
  browser-projections = import ./browser-projections.nix { inherit pkgs build; };
  inherit cli;

  toolchains =
    assert import ./toolchains.nix;
    runCommand "elm-toolchains" { } "touch $out";

  app-main = runsWorker "app-main" app.packages.Main "Main" "Hello, Nix!";
  app-report =
    runsWorker "app-report" app.packages."Report.Json" "Report.Json"
      ''{"greeting":"Hello, Nix!"}'';
  # Fresh dependency caches exercise the compiler's initial d.dat write,
  # which must finish before compiling the project's modules updates it.
  compiler-cache-writes = app.packages."Report.Json".overrideAttrs (old: {
    name = "compiler-cache-writes";
    env = (old.env or { }) // {
      GHCRTS = "-N2";
    };
    buildPhase = ''
      for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
        rm -rf elm-stuff "$TMPDIR/elm-home"
        ${old.buildPhase}
      done
    '';
  });
  app-tests = app.tests;
  app-outputs =
    assert
      lib.attrNames app == [
        "fetches"
        "packages"
        "release"
        "tests"
      ];
    assert
      lib.attrNames app.packages == [
        "Main"
        "Report.Json"
      ];
    assert !(builtins.tryEval app.release).success;
    # `fetches` holds the shared library's entries, at their paths in the
    # package cache, and the library fetches each of them.
    assert lib.all (entry: lib.hasPrefix "0.19.1/packages/" entry.path) app.fetches;
    assert builtins.length app.fetches == builtins.length (lib.attrNames appLock.hashes);
    runCommand "app-outputs" { } ''
      ${lib.concatMapStrings (entry: ''
        test -s ${purifier.fetchEntry { inherit pkgs; } entry}/elm.json
      '') app.fetches}
      touch $out
    '';

  package-docs =
    runCommand "package-docs"
      {
        nativeBuildInputs = [ pkgs.jq ];
      }
      ''
        jq -e '.[0].name == "Greeting" and ([.[0].values[].name] | sort) == ["encode", "greeting"]' \
          ${package.packages.docs}/docs.json
        cmp ${package.packages.docs}/docs.json ${package.release}/docs.json
        for file in elm.json README.md LICENSE src/Greeting.elm; do
          test -f ${package.release}/$file
        done
        touch $out
      '';
  package-tests = package.tests;

  shared-main =
    runsWorker "shared-main" shared.packages.Main "Main"
      ''"Hello from the shared directory, Nix!"'';

  real-world-elm-spa-example = runCommand "real-world-elm-spa-example" { } ''
    grep -q Conduit ${realWorld.elm-spa-example.packages.Main}/Main.js
    touch $out
  '';
  real-world-elm-spa-example-tests = realWorld.elm-spa-example.tests;
  real-world-list-extra = runCommand "real-world-list-extra" { nativeBuildInputs = [ pkgs.jq ]; } ''
    jq -e '.[0].name == "List.Extra"' ${realWorld.list-extra.packages.docs}/docs.json
    touch $out
  '';
  real-world-list-extra-tests = realWorld.list-extra.tests;

  # A lockfile beside an elm.json it was not made for.
  conformance-stale = messageCheck "conformance-stale" [ "changed since" "`elm-purifier lock`" ] {
    other-elm-json = "{ src = ${./fixtures/shared}; subdirectory = \"app\"; lockFile = ${appLockFile}; }";
  };

  # A package hash changed by hand, with the contentHash left as it was.
  conformance-tampered = messageCheck "conformance-tampered" [ "was edited" "`elm-purifier lock`" ] {
    changed-hash = "{ lockFile = ${
      lockFileOf "changed-hash" (
        appLock
        // {
          hashes = appLock.hashes // {
            "elm/core" = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
          };
        }
      )
    }; }";
  };

  # The hash of a package elm.json needs is gone, and the contentHash was
  # written again to match.
  conformance-missing =
    messageCheck "conformance-missing" [ "does not lock elm/json 1.1.4" "`elm-purifier lock`" ]
      {
        missing-package = "{ lockFile = ${
          lockFileOf "missing-package" (
            rehashed (appLock // { hashes = removeAttrs appLock.hashes [ "elm/json" ]; })
          )
        }; }";
      };

  # Lockfiles that are not valid: one that does not parse, one without a
  # field every lockfile has, an application's without its entry modules,
  # and one of another format version.
  conformance-malformed = messageCheck "conformance-malformed" [ "`elm-purifier lock`" ] {
    does-not-parse = "{ lockFile = ${builtins.toFile "does-not-parse.lock.json" ''{ "version": 3,''}; }";
    missing-field = "{ lockFile = ${
      lockFileOf "missing-field" (rehashed (removeAttrs appLock [ "hashes" ]))
    }; }";
    missing-applications = "{ lockFile = ${
      lockFileOf "missing-applications" (rehashed (removeAttrs appLock [ "applications" ]))
    }; }";
    other-version = "{ lockFile = ${
      lockFileOf "other-version" (rehashed (appLock // { version = 99; }))
    }; }";
  };

  conformance-rebuild = rebuilds "conformance-rebuild" [
    app.packages.Main
    app.packages."Report.Json"
    package.packages.docs
    package.release
  ];

  # `elm-purifier prefetch` on the app fixture, then its everyday loop with
  # the tools it linked: the compiler, the tests, the formatter and the
  # language server. The build sandbox has no network.
  conformance-offline =
    runCommand "conformance-offline"
      {
        nativeBuildInputs = [
          nodejs
          pkgs.python3
        ];
      }
      ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"
        cp -r ${./fixtures/app} app
        chmod -R u+w app
        cd app
        PATH=${prefetchedNixBuild}/bin:$PATH ${cli}/bin/elm-purifier prefetch
        export PATH="$PWD/elm-stuff/elm-purifier/bin:$PATH"
        elm make src/Main.elm --output="$TMPDIR/main.js"
        test "$(node ${./run-worker.js} "$TMPDIR/main.js" Main Nix)" = 'Hello, Nix!'
        elm-test
        elm-format --stdin < src/Main.elm > /dev/null
        printf '\n\nprobe : Int\nprobe =\n    notDefinedAnywhere\n' >> src/Main.elm
        python3 -I ${./lsp-probe.py} src/Main.elm -- elm-language-server --stdio | grep -q notDefinedAnywhere
        touch $out
      '';

  conformance-external = runCommand "conformance-external" { } ''
    test ! -e ${./fixtures/external}/elm-purifier.lock.json
    ln -s ${
      runsWorker "external-main" external.packages.Main "Main" ''"Hello from an external lockfile, Nix!"''
    } $out
  '';

  # The unit tests of bin/elm-purifier and nix/lib/elm-home.py.
  unit = runCommand "unit" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    ELM_PURIFIER_REPO=${../.} python3 -I -m unittest discover -s ${./unit} -v
    touch $out
  '';

  # The compiler built by this flake compiles the probe it was built with.
  elm_0_19_1-version = runCommand "elm_0_19_1-version" { } ''
    test "$(${pkgs.elm-purifier.elm_0_19_1}/bin/elm --version)" = 0.19.1
    touch $out
  '';
}
