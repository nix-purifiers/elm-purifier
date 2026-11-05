# elm-purifier

elm-purifier keeps Elm's development workflow on locked,
Nix-resolved dependencies. Use the normal build and test commands in your
working tree; building the project itself in the Nix sandbox is an
optional next step.

It runs on x86_64-linux and aarch64-linux.

## Quickstart

From the project root:

```zsh
nix shell 'github:nix-purifiers/elm-purifier'
elm-purifier lock
elm-purifier prefetch
export PATH="$PWD/elm-stuff/elm-purifier/bin:$PATH"
elm make src/Main.elm
elm-test
```

Commit the lockfiles that the lock command writes, including the build
tool's own lockfile when it has one. Keep using the project's usual build,
test and editor commands with this setup. Nix provides the locked
dependencies; the development commands above run outside the Nix sandbox.
No project Nix files are needed for this workflow.

Sandboxed builds of the whole project are an optional
[next step](#building-the-project-with-nix).

The shell provides the `elm / elm-test` wrappers. Use them for the locked
development workflow. With no purifier lockfile, it warns on standard
error and runs the ordinary tool with impure resolution.

For persistent use, add these packages through your usual Nix configuration.


## Development loop

```zsh
nix shell 'github:nix-purifiers/elm-purifier'
elm-purifier prefetch
export PATH="$PWD/elm-stuff/elm-purifier/bin:$PATH"
elm make src/Main.elm
elm-test
```

Elm has no plugin mechanism, so `elm-purifier` is a command of its own that
runs the Elm compiler and elm-test. `prefetch` builds the locked packages
and the tools with Nix, and links the tools into
`elm-stuff/elm-purifier/bin`. The linked `elm` and `elm-test` are
the real compiler and test runner, running on the locked packages. Elm
commands that talk to the package server run with the usual `ELM_HOME`:
`elm init`, `install`, `bump` and `diff`, and `elm-test init` and
`install`. After `elm install` and `elm-test install`, the command reminds
you to lock again.

Changing dependencies takes two commands:

```zsh
elm install elm/regex
elm-purifier lock
elm-purifier prefetch
```

`elm-purifier update` moves the project to newer versions and locks it. Elm
has no update command, so for an application it runs `elm-json upgrade`, which moves every package within
its major version, or `elm-json install` for the packages you name
(`elm-purifier update elm/json`). For a package project it locks the newest
versions that the ranges in `elm.json` admit, where `lock` keeps the
versions its current lockfile records. The tool `elm-json` knows only Elm
0.19.0 and 0.19.1, so for an application on another compiler it solves a
copy of `elm.json` that names 0.19.1, and then restores the version.

Publishing a package takes one command:

```zsh
nix shell 'github:nix-purifiers/elm-purifier'
elm-purifier publish
```

Elm publishes by registering a pushed git tag with the package server, which
fetches the release from GitHub. So `publish` cannot upload the `release`
that Nix built, because `elm publish` takes no prebuilt files. The command
builds the `release` with Nix, compiles the documentation on the locked
packages, and stops unless the two are identical. It then runs `elm
publish`, which registers the tag. `publish --check` stops before `elm
publish`.

## Building the project with Nix

Once the native development workflow is working, you can also build and
test the whole project in the Nix sandbox. For this step, keep a flake or
another Nix build definition in the project's repository, or maintain an
external packaging repository that points at its sources and lockfiles.
The builder consumes the same lockfiles as the development workflow.

`result/Main.js` is the compiled application. For a package, build
`.packages.docs` instead, and for the tests, build `.tests`.

The default overlay of the flake adds one attribute to the package set, the
scope `elm-purifier`. The scope holds the builder `buildElmProject`, the
command and the Elm toolchains. A flake that packages the project, for a
project whose authors want one, calls the builder directly. It can live in
the repository of the project or in another one:

```nix
# flake.nix
{
  inputs.elm-purifier.url =
    "github:nix-purifiers/elm-purifier";
  inputs.nixpkgs.follows = "elm-purifier/nixpkgs";

  outputs =
    { nixpkgs, elm-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ elm-purifier.overlays.default ];
      };
      project = pkgs.elm-purifier.buildElmProject {
        src = ./.;
      };
    in
    {
      packages.${system}.default =
        project.packages.Main;
      checks.${system}.tests = project.tests;
    };
}
```

A flake sees only files that git tracks, so run `git add flake.nix
elm-purifier.lock.json` before `nix build`. A package in an overlay takes
the scope by name with `{ elm-purifier }:`. Every attribute name of the
builder's result is known when Nix evaluates:

| Attribute | What it is |
| --- | --- |
| `packages.<module>` | For an application, the compiled JavaScript of each entry module, built with `--optimize`, at `<module>.js`. |
| `packages.docs` | For a package, its `docs.json`. |
| `tests` | elm-test on `tests/`, when the lock covers the tests. |
| `release` | For a package, what `elm-purifier publish` checks before it publishes: `docs.json`, `elm.json`, `README.md`, `LICENSE` and `src/`. |
| `fetches` | The shared library entry for each package archive, which SBOM and license tools read. |

The builder takes these arguments:

- `src`, the tree the project is in, as a path: the source of the flake, a
  flake input, or `builtins.fetchTarball`. The builder reads `elm.json` and
  the lockfile while Nix evaluates, so a source built as a derivation, such
  as `fetchFromGitHub`, would make Nix build it during evaluation.
- `subdirectory`, the directory of `elm.json` inside `src`, for a project
  whose source directories reach outside its own directory, such as
  `"../shared/src"`.
- `lockFile`, which defaults to `elm-purifier.lock.json` beside `elm.json`.
  We recommend committing that lockfile to the repository, which is the
  default. A flake can instead keep the lockfile outside `src`, as in a
  packaging flake for a project that its author does not change, and the
  build then uses it in place of any copy inside `src`. The command takes
  the same path as `--lockfile`, or from the environment variable
  `ELM_PURIFIER_LOCKFILE`, which a dev shell can set. Elm has no lockfile of
  its own, so the builder has no argument for one.
- `fetchers`, passed to the shared library for a company mirror or
  credentials. `fetchers.fetchurl` replaces the `fetchurl` of nixpkgs.
- `optimize`, on by default. An application that uses `Debug` needs it
  off.
- `elm`, `elm-test` and `srcFilter`, to replace the toolchain or the source
  filter.

`elm-purifier.buildElmProject.override` replaces what the builder takes from
the package set: `stdenvNoCC`, `elmPackages`, the scope `elm-purifier` and
the shared library `purifier`. `elm-purifier.overrideScope` replaces what
everything in the scope shares, such as the Elm toolchains.
`elm-purifier.lib.elm-purifier.readLock { src, subdirectory, lockFile }` in
the flake returns the lock in the shape of the contract, for tools that read
every purifier.

### One-off builds without a project Nix file

For an ad hoc build, the builder can also be evaluated directly from the
project root. Replace the example package name with one from your project:

```zsh
nix build --impure --expr 'let
  purifier = builtins.getFlake "github:nix-purifiers/elm-purifier";
  pkgs = import purifier.inputs.nixpkgs {
    system = builtins.currentSystem;
    overlays = [ purifier.overlays.default ];
  };
in
(pkgs.elm-purifier.buildElmProject { src = ./.; }).packages.Main'
```

This uses the purifier's pinned nixpkgs, matching the lock command above.
To build with ambient `<nixpkgs>` from your Nix search path instead,
replace `import purifier.inputs.nixpkgs` with `import <nixpkgs>`.
Both forms need no Nix files in your project. The build tool and language
versions must match the lockfile; with ambient nixpkgs, lock with the
purifier from that package set or pass a compatible toolchain to the builder.

## Working offline

After `prefetch`, the compiler, elm-test, elm-format and the language server
run with the network cut off. `prefetch` realizes in the Nix store every
locked package for the current system, the tools for the Elm version of the
lock, and the editor tools. It keeps them alive with a garbage-collector
root, `.elm-purifier.lock.json.gcroot` beside the lockfile, and puts a
writable copy of the package cache at `elm-stuff/elm-purifier/home`, because
the compiler writes its build artifacts into each package directory.

## Editor

Editors and language servers find `elm`, `elm-test` and `elm-format` on
`PATH`, and the packages through `ELM_HOME`. The tools in
`elm-stuff/elm-purifier/bin` set `ELM_HOME` themselves, so putting that
directory first on `PATH` is all an editor needs. The same directory holds
`elm-language-server`, which runs the language server with that `PATH`:

```zsh
PATH="$PWD/elm-stuff/elm-purifier/bin:$PATH" code .
```

With direnv, the line `PATH_add elm-stuff/elm-purifier/bin` in `.envrc`
does the same. The language server sometimes hangs while it starts, and
restarting it from the editor fixes that.

## Troubleshooting

Each of these stops with a message that names the lockfile and the command
that fixes it, in the Nix build and in the command:

| What happened | What the message says |
| --- | --- |
| `elm.json` changed since the lock was made. | The lockfile was made for another `elm.json`. Run `elm-purifier lock`. |
| An application names a package that the lockfile has no hash for, or the lockfile was edited by hand. | The lockfile does not lock the package, or was edited after `elm-purifier lock` wrote it. Run `elm-purifier lock`. |
| The lockfile does not parse, lacks a field, or has another format version. | The lockfile has no such field, or reads another version. Run `elm-purifier lock`. |
| An archive does not match its hash, because it changed on GitHub. | Nix reports the hash mismatch for the package. Run `elm-purifier lock`. |
| The package server names a URL that is not the GitHub zipball of the tag. | The lock run stops and names the package, because the builder derives that URL. |

The message says to add `--lockfile` when the lockfile is kept outside the
project.

The Elm compiler sometimes fails with `resource busy (file is locked)` or
`thread blocked indefinitely in an MVar operation`, which come from its own
threads. The lock run starts the compiler again, up to four times. A
`nix build` that fails with one of these builds again.

## Supported language repositories

Elm installs packages only from the package server, and a package there is
a zip archive of a tagged GitHub release. Every package an Elm project can
depend on is therefore a locked archive, and the builder derives its URL as
`https://github.com/<author>/<project>/zipball/<version>/`. The lock run
checks each archive against the SHA-1 that the package server publishes, and
records the SHA-256.

- Applications and packages, on Elm 0.19.1 and 0.19.2.
- Source directories outside the project, such as `"../shared/src"`, when
  `src` is the enclosing tree and `subdirectory` is the directory of the
  project.
- Test suites on elm-explorations/test 1.x and 2.x.
- A lockfile kept outside the source tree.

Elm 0.19.0 has no toolchain here, so a project on 0.19.0 passes its own
`elm` and `elm-test` to the builder. A package whose server entry names a
URL other than the GitHub zipball of its tag cannot be locked. A `src` that
is a derivation cannot be read.

The compilers are Elm 0.19.2 from nixpkgs, with elm-test 0.19.2-1 from
nixpkgs, and Elm 0.19.1, which most published applications pin. The flake
builds Elm 0.19.1 as `elm-purifier.elm_0_19_1` with the nixpkgs recipe for
Elm. Elm 0.19.1 tests run on elm-test 0.19.1-revision15 for
elm-explorations/test 2.x, and on 0.19.1-revision9, the last release that
runs test 1.x. The elm-test release follows the major version of
elm-explorations/test that `elm.json` names. Every elm-test package of this
flake puts its socket in the directory that `TMPDIR` names.

## Examples

For day-to-day work on these projects, use the native-tool setup and
commands in [Quickstart](#quickstart) and [Development loop](#development-loop).
The Nix expressions below show optional sandboxed packaging of those
projects.

### An application: elm-spa-example

[elm-spa-example](https://github.com/rtfeldman/elm-spa-example) is a
single-page application. In a clone of it, write the lockfile and build the
application and its tests:

```zsh
nix shell 'github:nix-purifiers/elm-purifier'
git clone https://github.com/rtfeldman/elm-spa-example
cd elm-spa-example
elm-purifier lock
nix build --impure --expr 'let
  purifier = builtins.getFlake "github:nix-purifiers/elm-purifier";
  pkgs = import purifier.inputs.nixpkgs {
    system = builtins.currentSystem;
    overlays = [ purifier.overlays.default ];
  };
in
(pkgs.elm-purifier.buildElmProject { src = ./.; }).packages.Main'
nix build --impure --expr 'let
  purifier = builtins.getFlake "github:nix-purifiers/elm-purifier";
  pkgs = import purifier.inputs.nixpkgs {
    system = builtins.currentSystem;
    overlays = [ purifier.overlays.default ];
  };
in
(pkgs.elm-purifier.buildElmProject { src = ./.; }).tests'
```

`result/Main.js` is the compiled application, and the second build runs its
tests.

### A package: list-extra

[list-extra](https://github.com/elm-community/list-extra) is a package. In a
clone of it, write the lockfile and build the documentation and the tests:

```zsh
nix shell 'github:nix-purifiers/elm-purifier'
git clone https://github.com/elm-community/list-extra
cd list-extra
elm-purifier lock
nix build --impure --expr 'let
  purifier = builtins.getFlake "github:nix-purifiers/elm-purifier";
  pkgs = import purifier.inputs.nixpkgs {
    system = builtins.currentSystem;
    overlays = [ purifier.overlays.default ];
  };
in
(pkgs.elm-purifier.buildElmProject { src = ./.; }).packages.docs'
nix build --impure --expr 'let
  purifier = builtins.getFlake "github:nix-purifiers/elm-purifier";
  pkgs = import purifier.inputs.nixpkgs {
    system = builtins.currentSystem;
    overlays = [ purifier.overlays.default ];
  };
in
(pkgs.elm-purifier.buildElmProject { src = ./.; }).tests'
```

`result/docs.json` is the documentation of the package, and the second build
runs its tests.

## Browser resource projections

Compiled application packages expose resource/web/Java-resource projections of
their `<Module>.js` output. Package documentation exposes the same projections
for `docs.json`. Use `.directory`, `.documentRoot`, or `.classPath` on the
selected view. Compiler caches and source trees are excluded.

Set `webjars = { "Report.Json" = { artifactId = "elm-report";
version = "1.0.0"; }; };` on `buildElmProject` to additionally publish that
compiled module through immutable Maven/Ivy WebJar views. `groupId` defaults
to `org.webjars.npm`. Only application entry modules may be selected. Java
resources in the plain JAR keep native paths; WebJars use
`META-INF/resources/webjars/<artifactId>/<sourceVersion>/`.

The check runs an actual compiled Elm worker with Node, serves/loads the
compiled bytes through ordinary HTTP and Java, and resolves the WebJar with
offline Gradle. It does not execute a browser or supply application-specific
JavaScript ports, DOM state, or other external assets.

## Credits

The purifier idea was inspired by nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo).

The Elm 0.19.1 build uses the nixpkgs recipe for Elm, and `update` runs
[elm-json](https://github.com/zwilias/elm-json).

Released under the MIT license; see [LICENSE](LICENSE).
