# SPDX-License-Identifier: MIT
#
# Reads an elm-purifier lockfile (written by `elm-purifier lock`) together
# with the elm.json it was made for. The lockfile holds only what elm.json
# cannot give:
#
#   version       the lock format version (lock-version.nix)
#   contentHash   the hash of the rest of the lockfile (lock-hash.nix)
#   elmJson       the SRI hash of elm.json when the lock was made
#   tests         whether the lock covers elm-test on tests/
#   hashes        the SRI SHA-256 of each package's zip, by package name
#   applications  for an application, the file of each entry module, by
#                 module name
#   elmVersion    for a package, the compiler version the lock was made
#                 with, from the range elm.json gives
#   solved        for a package, the version of each package the solver
#                 picked, by package name, from the ranges elm.json gives
#
# An application's elm.json names every package, with its exact version,
# under `dependencies` (and `test-dependencies`, which the lock covers when
# `tests` is true), and its exact compiler version. The package server
# serves each package as the zipball of its tag on GitHub, which
# `elm-purifier lock` checks when it makes the lock.
#
# The result has
#
#   lock         the lock in memory of the purifier contract, which
#                `readLock` of the flake's library returns:
#                  purifier  "elm-purifier"
#                  entries   an archive entry of the shared purifier
#                            library for each package, at its path in the
#                            package cache, <elmVersion>/packages/<author>/
#                            <project>/<version>
#                  outputs   <module> = { main = <file>; } for each entry
#                            module of an application, or docs = { } for
#                            a package
#                  problems  why the lockfile cannot be used for elm.json,
#                            each naming the command that writes it again
#   contentHash  the content hash the lockfile records
#   elmVersion   the compiler version
#   tests        whether the lock covers the tests
#   applications the entry modules of an application
#
# Every value but `lock.problems` is only meaningful when `problems` is
# empty, and the builder checks the lock with the library's `checkLock`
# first. A lockfile that does not parse fails evaluation while it is read,
# with the same advice, because Nix cannot catch a JSON error.
{
  lockFile,
  elmJsonFile,
  # Where the project is, for messages.
  location ? "the project directory",
}:
let
  lockCommand = "`elm-purifier lock` in ${location}, with `--lockfile` or ELM_PURIFIER_LOCKFILE when the lockfile is kept outside the project,";
  problem =
    reason:
    "elm-purifier: the lockfile ${toString lockFile} ${reason}; run ${lockCommand} to write it again.";

  data = builtins.addErrorContext "while reading the elm-purifier lockfile ${toString lockFile} (if it does not parse, run ${lockCommand} to write it again)" (
    builtins.fromJSON (builtins.readFile lockFile)
  );
  supportedVersion = import ./lock-version.nix;
  elmJson = builtins.fromJSON (builtins.readFile elmJsonFile);
  isApplication = elmJson.type == "application";

  elmJsonHash = builtins.convertHash {
    hash = builtins.hashFile "sha256" elmJsonFile;
    hashAlgo = "sha256";
    toHashFormat = "sri";
  };

  absent = fields: builtins.filter (field: !(data ? ${field})) fields;
  typeFields =
    if isApplication then
      [ "applications" ]
    else
      [
        "elmVersion"
        "solved"
      ];

  # The packages by name, with their versions.
  exact = deps: deps.direct // deps.indirect;
  versions =
    if isApplication then
      exact elmJson.dependencies // (if data.tests then exact elmJson."test-dependencies" else { })
    else
      data.solved;
  missing = builtins.filter (name: !(data.hashes ? ${name})) (builtins.attrNames versions);

  # The first problem, as later checks read what earlier ones check.
  problems =
    if !builtins.isAttrs data then
      [ (problem "is not an elm-purifier lockfile") ]
    else if absent [ "version" ] != [ ] then
      [ (problem "has no field `version`") ]
    else if data.version != supportedVersion then
      [
        (problem "has lock format version ${toString data.version}, and this elm-purifier reads version ${toString supportedVersion}")
      ]
    else if
      absent [
        "contentHash"
        "elmJson"
        "tests"
        "hashes"
      ] != [ ]
    then
      [
        (problem "has no field `${
          builtins.head (absent [
            "contentHash"
            "elmJson"
            "tests"
            "hashes"
          ])
        }`")
      ]
    else if data.contentHash != import ./lock-hash.nix data then
      [
        (problem "was edited after `elm-purifier lock` wrote it, because its contentHash does not match its content")
      ]
    else if data.elmJson != elmJsonHash then
      [ (problem "was made for another elm.json: elm.json changed since") ]
    else if absent typeFields != [ ] then
      [ (problem "has no field `${builtins.head (absent typeFields)}`") ]
    else if missing != [ ] then
      [
        (problem "does not lock ${
          builtins.concatStringsSep ", " (map (name: "${name} ${versions.${name}}") missing)
        }, which elm.json needs")
      ]
    else
      [ ];
  usable = problems == [ ];

  elmVersion = if isApplication then elmJson."elm-version" else data.elmVersion;
  applications = if isApplication then data.applications else { };
in
{
  lock = {
    purifier = "elm-purifier";
    entries =
      if !usable then
        [ ]
      else
        map (
          name:
          let
            version = versions.${name};
          in
          {
            path = "${elmVersion}/packages/${name}/${version}";
            archive = {
              url = "https://github.com/${name}/zipball/${version}/";
              mirrors = [ ];
              stripTop = true;
            };
            hash = data.hashes.${name};
          }
        ) (builtins.attrNames versions);
    outputs =
      if !usable then
        { }
      else if isApplication then
        builtins.mapAttrs (_: main: { inherit main; }) applications
      else
        { docs = { }; };
    inherit problems;
  };
  inherit elmVersion applications;
  inherit (data) tests contentHash;
}
