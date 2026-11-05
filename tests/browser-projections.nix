# SPDX-License-Identifier: MIT
{ pkgs, build }:
let
  built = build {
    src = ./fixtures/app;
    webjars."Report.Json" = {
      artifactId = "elm-report";
      version = "1.0.0";
    };
  };
  package = built.packages."Report.Json";
  view = package.projections.maven;
in
pkgs.runCommand "elm-browser-projections"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.nodejs
      pkgs.jdk
      pkgs.gradle
    ];
  }
  ''
    test -e ${
      import ./resource-consumer.nix {
        inherit pkgs;
        projection = package.projections.resources;
      }
    }
    node ${./run-worker.js} ${package.projections.resources.directory}/Report.Json.js Report.Json Nix | grep -F 'Hello, Nix!'
    export HOME="$TMPDIR/home" GRADLE_USER_HOME="$TMPDIR/gradle"
    mkdir -p "$HOME"
    python - <<'PY'
    import json
    module, = json.load(open('${view.catalog}'))['modules']
    open('coordinate', 'w').write(f"{module['group']}:{module['name']}:{module['version']}")
    PY
    echo "rootProject.name = 'elm-resource-consumer'" > settings.gradle
    cat > build.gradle <<'GRADLE'
    repositories { maven { url = uri('${view}') } }
    configurations { assets }
    dependencies { assets file('coordinate').text }
    tasks.register('verify') {
      doLast {
        def jar = new java.util.jar.JarFile(configurations.assets.singleFile)
        assert jar.getJarEntry('META-INF/resources/webjars/elm-report/1.0.0/Report.Json.js') != null
        jar.close()
      }
    }
    GRADLE
    python ${./bounded-command.py} --timeout 300 -- gradle --offline --no-daemon --console=plain verify
    echo "elm-browser-projections: Gradle exited; writing check output"
    touch $out
  ''
