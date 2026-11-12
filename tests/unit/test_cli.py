# SPDX-License-Identifier: MIT
"""Unit tests for bin/elm-purifier and nix/lib/elm-home.py.

    python3 -m unittest discover -s tests/unit

The tests import both scripts from the repository, given as
ELM_PURIFIER_REPO (the current directory when unset).
"""

import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

REPO = os.environ.get("ELM_PURIFIER_REPO", os.getcwd())
# The command reads the lock format version from the Nix library.
os.environ.setdefault("ELM_PURIFIER_LIB", os.path.join(REPO, "nix", "lib"))


def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, os.path.join(REPO, path))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


cli = load("elm_purifier", "bin/elm-purifier")
elm_home = load("elm_home", "nix/lib/elm-home.py")

TOOLCHAINS = {
    "0.19.1": {"elm": "/e1/bin/elm", "elm-test": {"1": "/t9/bin/elm-test", "2": "/t15/bin/elm-test"},
               "elm-test-offline-args": []},
    "0.19.2": {"elm": "/e2/bin/elm", "elm-test": {"2": "/t2/bin/elm-test"},
               "elm-test-offline-args": ["--offline"]},
}


class LockedEnvironment(unittest.TestCase):
    def test_locked_solver_environment_is_scoped_and_overrides_proxy_bypasses(self):
        original = {"HTTPS_PROXY": "http://caller-proxy:1234", "NO_PROXY": "*", "ELM_HOME": "/prepared"}
        result = cli.locked_environment(original)
        self.assertEqual(result["HTTPS_PROXY"], "http://127.0.0.1:9")
        self.assertEqual(result["https_proxy"], result["HTTPS_PROXY"])
        self.assertEqual(result["NO_PROXY"], "")
        self.assertEqual(result["no_proxy"], "")
        self.assertEqual(result["ELM_HOME"], "/prepared")
        self.assertEqual(original["HTTPS_PROXY"], "http://caller-proxy:1234")
        self.assertEqual(original["NO_PROXY"], "*")

    def test_old_writable_home_is_refreshed_once_then_keeps_compiled_artifacts(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory) / "project"
            root = Path(directory) / "prefetch"
            source = root / "home"
            source.mkdir(parents=True)
            (source / "registry.dat").write_text("locked registry")
            home = Path(cli.state(str(project), "home"))
            home.mkdir(parents=True)
            (home / ".source").write_text(str(source.resolve()))
            (home / "registry.dat").write_text("unlocked registry")
            (home / "unlocked-package").write_text("old cached package")
            self.assertEqual(Path(cli.install_home(str(project), str(root))), home)
            self.assertEqual((home / "registry.dat").read_text(), "locked registry")
            self.assertFalse((home / "unlocked-package").exists())
            (home / "compiled-artifact").write_text("reusable")
            cli.install_home(str(project), str(root))
            self.assertEqual((home / "compiled-artifact").read_text(), "reusable")

    def test_failed_cache_copy_preserves_the_previous_home(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory) / "project"
            root = Path(directory) / "prefetch"
            (root / "home").mkdir(parents=True)
            home = Path(cli.state(str(project), "home"))
            home.mkdir(parents=True)
            (home / ".source").write_text("old marker")
            (home / "compiled-artifact").write_text("keep on failure")
            with mock.patch.object(cli, "writable_copy", side_effect=OSError("copy failed")):
                with self.assertRaisesRegex(OSError, "copy failed"):
                    cli.install_home(str(project), str(root))
            self.assertEqual((home / "compiled-artifact").read_text(), "keep on failure")
            self.assertFalse(list(home.parent.glob(".home-*")))


class Constraints(unittest.TestCase):
    def test_exact_version(self):
        self.assertTrue(cli.satisfies("0.19.1", "0.19.1"))
        self.assertFalse(cli.satisfies("0.19.2", "0.19.1"))

    def test_range(self):
        self.assertTrue(cli.satisfies("0.19.2", "0.19.0 <= v < 0.20.0"))
        self.assertFalse(cli.satisfies("0.20.0", "0.19.0 <= v < 0.20.0"))
        self.assertTrue(cli.satisfies("0.20.0", "0.19.0 <= v <= 0.20.0"))
        self.assertFalse(cli.satisfies("0.19.0", "0.19.0 < v < 0.20.0"))

    def test_versions_compare_as_numbers(self):
        self.assertLess(cli.version_key("0.19.2"), cli.version_key("0.19.10"))


class CompilerSelection(unittest.TestCase):
    def setUp(self):
        os.environ["ELM_PURIFIER_TOOLCHAINS"] = json.dumps(TOOLCHAINS)

    def test_application_takes_its_exact_version(self):
        self.assertEqual(cli.select_compiler({"elm-version": "0.19.1"}), "0.19.1")

    def test_package_takes_the_newest_in_range(self):
        self.assertEqual(cli.select_compiler({"elm-version": "0.19.0 <= v < 0.20.0"}), "0.19.2")

    def test_unknown_version_fails(self):
        with self.assertRaises(SystemExit):
            cli.select_compiler({"elm-version": "0.18.0"})


class TestRunner(unittest.TestCase):
    def test_major_of_an_application(self):
        elm_json = {"type": "application",
                    "test-dependencies": {"direct": {"elm-explorations/test": "1.2.2"}, "indirect": {}}}
        self.assertEqual(cli.test_major(elm_json), "1")

    def test_major_of_a_package_range(self):
        elm_json = {"type": "package",
                    "test-dependencies": {"elm-explorations/test": "2.0.0 <= v < 3.0.0"}}
        self.assertEqual(cli.test_major(elm_json), "2")

    def test_no_test_package(self):
        self.assertIsNone(cli.test_major({"type": "package", "test-dependencies": {}}))

    def test_runner_by_major(self):
        elm_json = {"type": "package", "test-dependencies": {"elm-explorations/test": "1.0.0 <= v < 2.0.0"}}
        command = cli.elm_test_command(TOOLCHAINS["0.19.1"], elm_json, offline=True)
        self.assertEqual(command, ["/t9/bin/elm-test", "--compiler", "/e1/bin/elm"])

    def test_offline_arguments(self):
        elm_json = {"type": "package", "test-dependencies": {"elm-explorations/test": "2.0.0 <= v < 3.0.0"}}
        command = cli.elm_test_command(TOOLCHAINS["0.19.2"], elm_json, offline=True)
        self.assertEqual(command[-1], "--offline")

    def test_missing_runner_fails(self):
        elm_json = {"type": "package", "test-dependencies": {"elm-explorations/test": "1.0.0 <= v < 2.0.0"}}
        with self.assertRaises(SystemExit):
            cli.elm_test(TOOLCHAINS["0.19.2"], elm_json)


class ProjectScanning(unittest.TestCase):
    def project(self, files):
        root = tempfile.mkdtemp()
        for path, text in files.items():
            full = os.path.join(root, path)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "w") as f:
                f.write(text)
        return root

    def test_finds_modules_that_define_main(self):
        root = self.project({
            "src/Main.elm": "module Main exposing (main)\n\nmain = text \"\"\n",
            "src/Pages/Admin.elm": "port module Pages.Admin exposing (main)\n\nmain : Program () () ()\nmain = worker\n",
            "src/Helpers.elm": "module Helpers exposing (x)\n\nx = mainly\n",
            "lib/Other.elm": "module Other exposing (main)\n\nmain = 1\n",
        })
        mains = cli.find_mains(root, {"source-directories": ["src"]})
        self.assertEqual(mains, ["src/Main.elm", "src/Pages/Admin.elm"])
        self.assertEqual(cli.module_name(os.path.join(root, mains[1])), "Pages.Admin")

    def test_tests_need_an_elm_module(self):
        self.assertFalse(cli.has_tests(self.project({"tests/elm-package.json": "{}"})))
        self.assertTrue(cli.has_tests(self.project({"tests/Suite/A.elm": "module Suite.A exposing (x)"})))


class LockFormat(unittest.TestCase):
    def lockfile(self, data):
        handle, path = tempfile.mkstemp(suffix=".lock.json")
        with os.fdopen(handle, "w") as f:
            json.dump(data, f)
        return path

    def valid(self):
        data = {
            "version": cli.lock_version(),
            "elmJson": "sha256-x",
            "tests": False,
            "hashes": {"elm/core": "sha256-y"},
            "applications": {"Main": "src/Main.elm"},
        }
        data["contentHash"] = cli.content_hash(data)
        return data

    def message_of(self, data):
        """The message `read_lock` prints before it exits."""
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr), self.assertRaises(SystemExit):
            cli.read_lock(self.lockfile(data))
        message = stderr.getvalue()
        self.assertIn("run `elm-purifier lock`", message)
        return message

    def test_content_hash_ignores_its_own_field(self):
        data = self.valid()
        self.assertEqual(cli.content_hash(data), data["contentHash"])
        self.assertEqual(cli.content_hash({**data, "contentHash": "other"}), data["contentHash"])

    def test_content_hash_follows_the_content(self):
        data = self.valid()
        edited = {**data, "hashes": {"elm/core": "sha256-z"}}
        self.assertNotEqual(cli.content_hash(edited), data["contentHash"])

    def test_content_hash_is_the_hash_of_sorted_compact_json(self):
        # builtins.toJSON in nix/lib/lock-hash.nix writes this text.
        data = {"b": 1, "a": {"y": [True, None], "x": "é"}}
        text = '{"a":{"x":"é","y":[true,null]},"b":1}'
        self.assertEqual(cli.content_hash(data), cli.sri_sha256(text.encode()))

    def test_a_valid_lockfile_reads(self):
        data = self.valid()
        self.assertEqual(cli.read_lock(self.lockfile(data)), data)

    def test_an_edited_lockfile_fails(self):
        data = self.valid()
        data["hashes"]["elm/core"] = "sha256-edited"
        self.assertIn("edited", self.message_of(data))

    def test_another_version_fails(self):
        data = self.valid()
        data["version"] = 99
        self.assertIn("lock format version 99", self.message_of(data))

    def test_a_missing_field_fails(self):
        data = self.valid()
        del data["hashes"]
        self.assertIn("`hashes`", self.message_of(data))

    def test_archive_url_is_the_tag_zipball(self):
        self.assertEqual(
            cli.archive_url("elm/core/1.0.5"), "https://github.com/elm/core/zipball/1.0.5/"
        )

    def test_named_packages_of_an_application(self):
        elm_json = {
            "dependencies": {"direct": {"elm/core": "1.0.5"}, "indirect": {"elm/json": "1.1.4"}},
            "test-dependencies": {"direct": {"elm-explorations/test": "2.2.1"}, "indirect": {}},
        }
        self.assertEqual(cli.named_packages(elm_json, False), ["elm/core/1.0.5", "elm/json/1.1.4"])
        self.assertEqual(
            cli.named_packages(elm_json, True),
            ["elm-explorations/test/2.2.1", "elm/core/1.0.5", "elm/json/1.1.4"],
        )

    def test_lockfile_precedence(self):
        os.environ.pop("ELM_PURIFIER_LOCKFILE", None)
        self.assertEqual(cli.lock_path("/p", None), "/p/elm-purifier.lock.json")
        os.environ["ELM_PURIFIER_LOCKFILE"] = "/elsewhere/a.json"
        try:
            self.assertEqual(cli.lock_path("/p", None), "/elsewhere/a.json")
            self.assertEqual(cli.lock_path("/p", "/given/b.json"), "/given/b.json")
        finally:
            del os.environ["ELM_PURIFIER_LOCKFILE"]

    def test_gc_root_lies_beside_the_lockfile(self):
        self.assertEqual(
            cli.gc_root("/p/elm-purifier.lock.json"), "/p/.elm-purifier.lock.json.gcroot"
        )


class ElmRaces(unittest.TestCase):
    """run_elm_tool starts a tool again when it fails with a race inside the
    Elm compiler, and not for any other failure."""

    def tool(self, script):
        project = tempfile.mkdtemp()
        os.makedirs(os.path.join(project, "elm-stuff"))
        return project, [sys.executable, "-I", "-c", script]

    def test_a_race_is_run_again_with_a_fresh_elm_stuff(self):
        project, command = self.tool(
            "import os, sys\n"
            "if os.path.exists('elm-stuff/attempted'):\n"
            "    sys.exit('this attempt found the old elm-stuff')\n"
            "os.makedirs('elm-stuff', exist_ok=True)\n"
            "open('elm-stuff/attempted', 'w').close()\n"
            "if not os.path.exists('../second-attempt-marker'):\n"
            "    open('../second-attempt-marker', 'w').close()\n"
            "    sys.exit('d.dat: withBinaryFile: resource busy (file is locked)')\n"
        )
        # The marker lies beside the project, so the second attempt finds it.
        with contextlib.redirect_stderr(io.StringIO()) as errors:
            cli.run_elm_tool(command, project, dict(os.environ))
        self.assertIn("running it again", errors.getvalue())

    def test_another_failure_is_not_run_again(self):
        project, command = self.tool("import sys; sys.exit('a type error')")
        with contextlib.redirect_stderr(io.StringIO()) as errors:
            with self.assertRaises(subprocess.CalledProcessError):
                cli.run_elm_tool(command, project, dict(os.environ))
        self.assertNotIn("running it again", errors.getvalue())

    def test_a_race_that_repeats_fails_after_the_attempts(self):
        project, command = self.tool("import sys; sys.exit('thread blocked indefinitely in an MVar operation')")
        with contextlib.redirect_stderr(io.StringIO()) as errors:
            with self.assertRaises(subprocess.CalledProcessError):
                cli.run_elm_tool(command, project, dict(os.environ))
        self.assertEqual(errors.getvalue().count("running it again"), cli.ELM_ATTEMPTS - 1)


class PackageCache(unittest.TestCase):
    def test_trim_keeps_what_the_compiler_keeps(self):
        package = tempfile.mkdtemp()
        for path in ["elm.json", "README.md", "LICENSE", "src/Basics.elm", "tests/Test.elm", ".travis.yml"]:
            os.makedirs(os.path.dirname(os.path.join(package, path)), exist_ok=True)
            with open(os.path.join(package, path), "w") as f:
                f.write(path)
        elm_home.trim(package)
        found = sorted(
            os.path.relpath(os.path.join(d, f), package)
            for d, _, fs in os.walk(package) for f in fs
        )
        self.assertEqual(found, ["LICENSE", "README.md", "elm.json", "src/Basics.elm"])

    def test_registry_encoding(self):
        data = elm_home.registry(["elm/core/1.0.2", "elm/core/1.0.5", "a/b/300.0.1"])
        position = 0

        def take(n):
            nonlocal position
            chunk = data[position:position + n]
            position += n
            return chunk

        self.assertEqual(struct.unpack(">qq", take(16)), (3, 2))
        # Names in byte order: "a" sorts before "elm".
        self.assertEqual(take(2), b"\x01a")
        self.assertEqual(take(2), b"\x01b")
        # 300 does not fit in a byte, so the version takes the long form.
        self.assertEqual(take(7), b"\xff" + struct.pack(">HHH", 300, 0, 1))
        self.assertEqual(struct.unpack(">q", take(8)), (0,))
        self.assertEqual(take(4), b"\x03elm")
        self.assertEqual(take(5), b"\x04core")
        self.assertEqual(take(3), bytes([1, 0, 5]))
        self.assertEqual(struct.unpack(">q", take(8)), (1,))
        self.assertEqual(take(3), bytes([1, 0, 2]))
        self.assertEqual(position, len(data))


if __name__ == "__main__":
    unittest.main()
