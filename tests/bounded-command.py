#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Run one test command with a deadline covering process exit and output EOF."""
import argparse
import math
import os
import selectors
import signal
import subprocess
import sys
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--timeout', type=float, required=True)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command
    if command[:1] == ['--']:
        command = command[1:]
    if not command or not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error('a command and a finite positive timeout are required')
    start = time.monotonic()
    print(f'bounded-command: start {command!r}; deadline {args.timeout:g}s', flush=True)
    process = subprocess.Popen(command, start_new_session=True,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    timed_out = False
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while selector.get_map():
                remaining = args.timeout - (time.monotonic() - start)
                if remaining <= 0:
                    timed_out = True
                    break
                for key, _ in selector.select(remaining):
                    data = os.read(key.fd, 65536)
                    if data:
                        sys.stdout.buffer.write(data)
                        sys.stdout.buffer.flush()
                    else:
                        selector.unregister(key.fileobj)
            if not timed_out:
                try:
                    process.wait(timeout=max(0, args.timeout - (time.monotonic() - start)))
                except subprocess.TimeoutExpired:
                    timed_out = True
    finally:
        # Includes descendants holding the pipe after the direct child exits.
        # Every process in this fresh group belongs to this test command.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=5)
        process.stdout.close()
    elapsed = time.monotonic() - start
    if timed_out:
        print(f'bounded-command: TIMEOUT after {elapsed:.3f}s; '
              f'process-group {process.pid} killed; direct-child status {process.returncode}',
              file=sys.stderr, flush=True)
        return 124
    print(f'bounded-command: end after {elapsed:.3f}s; status {process.returncode}', flush=True)
    return process.returncode if process.returncode >= 0 else 128 - process.returncode


if __name__ == '__main__':
    sys.exit(main())
