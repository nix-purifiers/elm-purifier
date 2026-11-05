# SPDX-License-Identifier: MIT
"""Unit tests for tests/lsp-probe.py, with a fake language server.

    python3 -m unittest discover -s tests/unit

The tests import the probe from the repository, given as
ELM_PURIFIER_REPO (the current directory when unset).
"""

import contextlib
import importlib.machinery
import importlib.util
import io
import os
import pathlib
import sys
import tempfile
import textwrap
import unittest

REPO = os.environ.get("ELM_PURIFIER_REPO", os.getcwd())

loader = importlib.machinery.SourceFileLoader("lsp_probe", os.path.join(REPO, "tests/lsp-probe.py"))
spec = importlib.util.spec_from_loader("lsp_probe", loader)
probe = importlib.util.module_from_spec(spec)
loader.exec_module(probe)

# A language server that hangs on its first start, as elm-language-server
# sometimes does, and answers on later starts. It publishes one diagnostic
# for the file it is sent.
FAKE_SERVER = textwrap.dedent(
    """
    import json, os, sys, time

    marker, mode = sys.argv[1], sys.argv[2]
    if mode == "hang-once" and not os.path.exists(marker):
        open(marker, "w").close()
        time.sleep(3600)
    if mode == "always-hang":
        time.sleep(3600)
    if mode == "close-output":
        os.close(sys.stdout.fileno())
        time.sleep(3600)
    if mode == "unframed-output":
        open(marker, "w").close()
        while True:
            sys.stdout.buffer.write(b"x" * 1024)
            sys.stdout.buffer.flush()
            time.sleep(0.001)

    def read():
        headers = {}
        while True:
            line = sys.stdin.buffer.readline().decode()
            if line == "":
                sys.exit(0)
            if line == "\\r\\n":
                break
            key, _, value = line.partition(":")
            headers[key.strip().lower()] = value.strip()
        return json.loads(sys.stdin.buffer.read(int(headers["content-length"])))

    def write(message):
        body = json.dumps(message).encode()
        sys.stdout.buffer.write(f"Content-Length: {len(body)}\\r\\n\\r\\n".encode() + body)
        sys.stdout.buffer.flush()

    print("fake server started", file=sys.stderr)
    while True:
        message = read()
        if message.get("method") == "initialize":
            write({"jsonrpc": "2.0", "id": message["id"], "result": {"capabilities": {}}})
        elif message.get("method") == "textDocument/didOpen":
            uri = message["params"]["textDocument"]["uri"]
            write({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics",
                   "params": {"uri": uri, "diagnostics": [{"message": "No definition found.\\nMore."}]}})
    """
)


class Probe(unittest.TestCase):
    def setUp(self):
        self.directory = pathlib.Path(tempfile.mkdtemp())
        (self.directory / "server.py").write_text(FAKE_SERVER)
        self.source = self.directory / "Main.elm"
        self.source.write_text("module Main exposing (main)\n")
        probe.START_WAIT = 2
        probe.DIAGNOSTICS_WAIT = 5
        probe.ATTEMPTS = 3

    def test_closed_output_from_a_live_server_is_bounded(self):
        probe.ATTEMPTS = 1
        probe.START_WAIT = 1
        started = probe.time.monotonic()
        status, output, errors = self.run_probe("close-output")
        self.assertEqual(status, 1)
        self.assertIn("closed standard output without exiting", errors)
        self.assertLess(probe.time.monotonic() - started, 3)

    def test_continuous_unframed_output_respects_the_deadline(self):
        probe.ATTEMPTS = 1
        probe.START_WAIT = 1
        started = probe.time.monotonic()
        status, output, errors = self.run_probe("unframed-output")
        self.assertEqual(status, 1)
        self.assertTrue((self.directory / "marker").exists())
        self.assertIn("did not answer initialize", errors)
        self.assertLess(probe.time.monotonic() - started, 3)

    def run_probe(self, mode):
        command = [sys.executable, "-I", str(self.directory / "server.py"), str(self.directory / "marker"), mode]
        sys.argv = ["lsp-probe.py", str(self.source), "--", *command]
        output, errors = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            status = probe.main()
        return status, output.getvalue(), errors.getvalue()

    def test_a_working_server_succeeds_at_once(self):
        status, output, errors = self.run_probe("works")
        self.assertEqual(status, 0)
        self.assertEqual(output.strip(), "No definition found.")
        self.assertEqual(errors, "")

    def test_a_server_that_hangs_once_is_started_again(self):
        status, output, errors = self.run_probe("hang-once")
        self.assertEqual(status, 0)
        self.assertEqual(output.strip(), "No definition found.")
        self.assertIn("started the server 2 times", errors)

    def test_a_server_that_always_hangs_fails_with_every_attempt(self):
        status, output, errors = self.run_probe("always-hang")
        self.assertEqual(status, 1)
        self.assertEqual(output, "")
        for number in (1, 2, 3):
            self.assertIn(f"attempt {number}: the server did not answer initialize within 2 seconds", errors)

    def test_a_server_that_exits_reports_its_status_and_stderr(self):
        command = [sys.executable, "-I", "-c", "import sys; print('boom', file=sys.stderr); sys.exit(4)"]
        sys.argv = ["lsp-probe.py", str(self.source), "--", *command]
        errors = io.StringIO()
        with contextlib.redirect_stderr(errors):
            status = probe.main()
        self.assertEqual(status, 1)
        self.assertIn("the server exited with status 4", errors.getvalue())
        self.assertIn("boom", errors.getvalue())


if __name__ == "__main__":
    unittest.main()
