# SPDX-License-Identifier: MIT
#
# The tree `elm-purifier prefetch` builds, with an out-link at
# elm-stuff/elm-purifier/root as the garbage-collector root:
#
#   home       the package cache of the lockfile (elm-home.nix)
#   bin        the tools of the CLI (pkgs/cli): elm, elm-test, elm-format
#              and elm-language-server, which refer to every toolchain the
#              CLI carries
#   lock-hash  the contentHash of the lockfile, which the tools compare
#              with the lockfile they read
#
# It is a package for callPackage, with the package cache and the CLI as
# arguments.
{
  runCommand,
  home,
  cli,
}:
runCommand "elm-purifier-prefetch" { preferLocalBuild = true; } ''
  mkdir "$out"
  ln -s ${home} "$out/home"
  ln -s ${cli}/libexec/elm-purifier/bin "$out/bin"
  echo ${home.contentHash} > "$out/lock-hash"
''
