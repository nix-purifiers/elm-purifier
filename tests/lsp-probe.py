# SPDX-License-Identifier: MIT
"""Starts a language server, opens one Elm file, and prints the
diagnostics the server publishes for it.

    python3 lsp-probe.py FILE -- COMMAND ARGS...

It exits with status 0 once the server publishes at least one diagnostic
for FILE, and with status 1 when no attempt succeeds.

elm-language-server 2.8.0 sometimes hangs while it starts: it logs that it
loads its grammar and then never answers `initialize`. A normal start
answers within a second. So the probe starts the server again when it has
not answered within START_WAIT seconds, up to ATTEMPTS times, and prints
what each failed attempt received and the standard error of its server.
"""

import json
import os
import pathlib
import select
import subprocess
import sys
import tempfile
import time

START_WAIT = 30
DIAGNOSTICS_WAIT = 180
ATTEMPTS = 8


def send(proc, message):
    body = json.dumps(message).encode()
    proc.stdin.write(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
    proc.stdin.flush()


class Messages:
    """The messages a server writes to its standard output. The class keeps
    the bytes it has read from the file descriptor in a buffer of its own,
    and waits for more with `select` only when the buffer holds no complete
    message."""

    def __init__(self, proc):
        self.fd = proc.stdout.fileno()
        self.buffer = b""

    def next(self, until):
        """The next message, or None when none arrives before `until`.
        Raises EOFError when the server closed its output."""
        while True:
            # Continuous non-protocol output must not keep a readable pipe
            # alive past the same deadline as an otherwise silent server.
            if time.monotonic() >= until:
                return None
            header_end = self.buffer.find(b"\r\n\r\n")
            if header_end >= 0:
                headers = {}
                for line in self.buffer[:header_end].decode().split("\r\n"):
                    key, _, value = line.partition(":")
                    headers[key.strip().lower()] = value.strip()
                start = header_end + 4
                end = start + int(headers["content-length"])
                if len(self.buffer) >= end:
                    message = json.loads(self.buffer[start:end])
                    self.buffer = self.buffer[end:]
                    return message
            if not select.select([self.fd], [], [], max(0, until - time.monotonic()))[0]:
                return None
            chunk = os.read(self.fd, 65536)
            if not chunk:
                raise EOFError
            self.buffer += chunk


def attempt(command, path):
    """One start of the server. Returns the first diagnostic messages, or
    a description of how the attempt failed."""
    root = pathlib.Path.cwd().as_uri()
    uri = path.as_uri()
    with tempfile.TemporaryFile() as stderr:
        proc = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr)
        try:
            send(proc, {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                        "params": {"processId": os.getpid(), "rootUri": root, "capabilities": {},
                                   "workspaceFolders": [{"uri": root, "name": "project"}]}})
            started = time.monotonic()
            until = started + START_WAIT
            initialized = False
            received = []
            reason = "no diagnostics arrived"
            messages = Messages(proc)
            while time.monotonic() < until:
                try:
                    message = messages.next(until)
                except EOFError:
                    try:
                        status = proc.wait(timeout=0.1)
                    except subprocess.TimeoutExpired:
                        reason = "the server closed standard output without exiting"
                    else:
                        reason = f"the server exited with status {status}"
                    break
                if message is None:
                    break
                received.append(message.get("method") or f"response {message.get('id')}")
                if message.get("id") == 1 and not initialized:
                    initialized = True
                    until = time.monotonic() + DIAGNOSTICS_WAIT
                    send(proc, {"jsonrpc": "2.0", "method": "initialized", "params": {}})
                    send(proc, {"jsonrpc": "2.0", "method": "textDocument/didOpen",
                                "params": {"textDocument": {"uri": uri, "languageId": "elm", "version": 1,
                                                            "text": path.read_text()}}})
                    send(proc, {"jsonrpc": "2.0", "method": "textDocument/didSave",
                                "params": {"textDocument": {"uri": uri}}})
                elif message.get("method") == "textDocument/publishDiagnostics":
                    params = message["params"]
                    if params["uri"] == uri and params["diagnostics"]:
                        return [diagnostic["message"].splitlines()[0] for diagnostic in params["diagnostics"]]
                elif "id" in message and "method" in message:
                    # A request from the server, such as workspace/configuration.
                    send(proc, {"jsonrpc": "2.0", "id": message["id"], "result": [{}] * 8})
            if not initialized and reason == "no diagnostics arrived":
                reason = f"the server did not answer initialize within {START_WAIT} seconds"
            stderr.seek(0)
            return (f"{reason} (after {time.monotonic() - started:.0f} seconds; received {received}; "
                    f"standard error: {stderr.read().decode(errors='replace').strip() or 'empty'})")
        finally:
            proc.kill()
            proc.wait(timeout=5)


def main():
    split = sys.argv.index("--")
    path = pathlib.Path(sys.argv[1]).resolve()
    command = sys.argv[split + 1 :]
    failures = []
    for number in range(1, ATTEMPTS + 1):
        result = attempt(command, path)
        if isinstance(result, list):
            if failures:
                print(f"started the server {number} times; earlier attempts failed", file=sys.stderr)
            print("\n".join(result))
            return 0
        failures.append(f"attempt {number}: {result}")
    print("\n".join(failures), file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
