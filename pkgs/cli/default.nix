# SPDX-License-Identifier: MIT
#
# The elm-purifier command: bin/elm-purifier on nixpkgs' Python, with the
# Elm toolchains it locks and runs with (pkgs/build-elm-project/toolchains.nix), the
# editor tools, the Nix library it realizes lockfiles with, the nixpkgs
# that library builds with, and the shared purifier library pinned in this
# flake's flake.lock.
#
# libexec/elm-purifier/bin holds the tools that `elm-purifier prefetch`
# links into a project: elm, elm-test, elm-format and elm-language-server.
# Each runs the command with ELM_PURIFIER_TOOL set to its name, and with
# the path it was run as, from which the command finds the project.
{
  lib,
  stdenvNoCC,
  makeWrapper,
  runtimeShell,
  python3,
  elm-purifier,
  elmPackages,
  path,
  version,
  # The shared purifier library, as pinned in this flake's flake.lock.
  purifierSrc,
}:
let
  runtime = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../lib-overlays
      ../../pkgs
      ../../bin
      ../../flake.lock
    ];
  };
  toolchains = import ../build-elm-project/toolchains.nix { inherit elm-purifier elmPackages; };
  executables = lib.mapAttrs (_: toolchain: {
    elm = "${toolchain.elm}/bin/elm";
    elm-test = lib.mapAttrs (_: elm-test: "${elm-test}/bin/elm-test") toolchain.elm-test;
    elm-test-offline-args = toolchain.elmTestOfflineArgs;
  }) toolchains;
  tools = [
    "elm"
    "elm-test"
    "elm-format"
    "elm-language-server"
  ];
in
stdenvNoCC.mkDerivation {
  pname = "elm-purifier";
  inherit version;
  src = ../../bin;
  nativeBuildInputs = [ makeWrapper ];
  dontConfigure = true;
  dontBuild = true;
  installPhase = ''
    runHook preInstall
    install -Dm644 elm-purifier "$out/libexec/elm-purifier.py"
    makeWrapper ${python3}/bin/python3 "$out/bin/elm-purifier" \
      --add-flags "-I $out/libexec/elm-purifier.py" \
      --set ELM_PURIFIER_TOOLCHAINS ${lib.escapeShellArg (builtins.toJSON executables)} \
      --set ELM_PURIFIER_ELM_FORMAT ${elmPackages.elm-format}/bin/elm-format \
      --set ELM_PURIFIER_ELM_LANGUAGE_SERVER ${elmPackages.elm-language-server}/bin/elm-language-server \
      --set ELM_PURIFIER_ELM_JSON ${elmPackages.elm-json}/bin/elm-json \
      --set ELM_PURIFIER_LIB ${runtime}/pkgs/build-elm-project \
      --set ELM_PURIFIER_NIXPKGS ${path} \
      --set ELM_PURIFIER_PURIFIER ${purifierSrc} \
      --set ELM_PURIFIER_CLI "$out"
    mkdir -p "$out/libexec/elm-purifier/bin"
    for tool in ${lib.escapeShellArgs tools}; do
      cat > "$out/libexec/elm-purifier/bin/$tool" <<EOF
    #!${runtimeShell}
    export ELM_PURIFIER_TOOL=$tool
    export ELM_PURIFIER_TOOL_PATH="\$0"
    exec $out/bin/elm-purifier "\$@"
    EOF
      chmod +x "$out/libexec/elm-purifier/bin/$tool"
      ln -s "$out/libexec/elm-purifier/bin/$tool" "$out/bin/$tool"
    done
    runHook postInstall
  '';
  meta = {
    description = "Locks the packages an Elm project downloads, so that Nix can build it offline";
    license = lib.licenses.mit;
    mainProgram = "elm-purifier";
  };
}
