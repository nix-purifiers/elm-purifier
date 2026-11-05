# SPDX-License-Identifier: MIT
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(os.environ.get('ELM_PURIFIER_REPO', Path(__file__).resolve().parents[2]))
SCRIPT = ROOT / 'tests' / 'bounded-command.py'


class BoundedCommandTests(unittest.TestCase):
    def run_command(self, code, timeout=2):
        started = time.monotonic()
        result = subprocess.run([sys.executable, '-I', str(SCRIPT), '--timeout', str(timeout),
                                 '--', sys.executable, '-I', '-u', '-c', code],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, timeout=8)
        self.assertLess(time.monotonic() - started, 6)
        return result

    def test_success_keeps_output(self):
        result = self.run_command("print('verified bytes')")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('verified bytes', result.stdout)
        self.assertIn('bounded-command: end', result.stdout)

    def test_failure_keeps_status(self):
        result = self.run_command("import sys; print('assertion failed'); sys.exit(7)")
        self.assertEqual(result.returncode, 7, result.stdout)
        self.assertIn('assertion failed', result.stdout)

    def test_success_message_does_not_override_hung_process(self):
        result = self.run_command("import time; print('BUILD SUCCESSFUL'); time.sleep(3600)")
        self.assertEqual(result.returncode, 124, result.stdout)
        self.assertIn('BUILD SUCCESSFUL', result.stdout)
        self.assertIn('TIMEOUT', result.stdout)

    def test_exited_parent_with_child_holding_output_is_bounded(self):
        with tempfile.TemporaryDirectory() as temporary:
            marker = Path(temporary) / 'alive'
            child = f"import time,pathlib; time.sleep(3); pathlib.Path({str(marker)!r}).touch()"
            result = self.run_command(
                f"import subprocess,sys; subprocess.Popen([sys.executable, '-I', '-c', {child!r}]); "
                "print('BUILD SUCCESSFUL')")
            self.assertEqual(result.returncode, 124, result.stdout)
            self.assertIn('direct-child status 0', result.stdout)
            time.sleep(1.5)
            self.assertFalse(marker.exists(), 'descendant survived process-group cleanup')

    def test_closed_output_with_live_process_is_bounded(self):
        result = self.run_command("import os,time; os.close(1); os.close(2); time.sleep(3600)")
        self.assertEqual(result.returncode, 124, result.stdout)


if __name__ == '__main__':
    unittest.main()
