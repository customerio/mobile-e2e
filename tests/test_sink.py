#!/usr/bin/env python3

import importlib.util
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock
from urllib.request import urlopen


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("mobile_e2e_sink", ROOT / "scripts" / "sink.py")
SINK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SINK)


class LoopbackHTTPServerTest(unittest.TestCase):
    def test_bind_does_not_perform_reverse_dns(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(
            socket, "getfqdn", side_effect=AssertionError("reverse DNS must not run")
        ):
            server = SINK.LoopbackHTTPServer(("127.0.0.1", 0), SINK.Handler)
            server.out_path = str(Path(tmp) / "sink.jsonl")
            self.addCleanup(server.server_close)

            self.assertEqual(server.server_name, "127.0.0.1")
            self.assertGreater(server.server_port, 0)

    def test_health_endpoint_is_reachable(self):
        with tempfile.TemporaryDirectory() as tmp:
            server = SINK.LoopbackHTTPServer(("127.0.0.1", 0), SINK.Handler)
            server.out_path = str(Path(tmp) / "sink.jsonl")
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            self.addCleanup(server.server_close)
            self.addCleanup(server.shutdown)

            with urlopen(f"http://127.0.0.1:{server.server_port}/", timeout=2) as response:
                self.assertEqual(response.status, 200)
                self.assertEqual(response.read(), b"sink ok\n")

    def test_cli_publishes_port_and_startup_diagnostics(self):
        with tempfile.TemporaryDirectory() as tmp:
            port_file = Path(tmp) / "sink.port"
            output_file = Path(tmp) / "sink.jsonl"
            process = subprocess.Popen(
                [
                    sys.executable,
                    str(ROOT / "scripts" / "sink.py"),
                    str(output_file),
                    "--port",
                    "0",
                    "--port-file",
                    str(port_file),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            try:
                for _ in range(250):
                    if port_file.exists() and port_file.read_text():
                        break
                    self.assertIsNone(process.poll(), "sink exited before publishing its port")
                    time.sleep(0.02)
                else:
                    self.fail("sink did not publish its port")

                port = int(port_file.read_text())
                with urlopen(f"http://127.0.0.1:{port}/", timeout=2) as response:
                    self.assertEqual(response.status, 200)
            finally:
                process.terminate()
                try:
                    stdout, stderr = process.communicate(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()
                    stdout, stderr = process.communicate(timeout=2)

            self.assertIn("sink listening on 127.0.0.1:", stdout)
            self.assertIn("sink binding to 127.0.0.1:0", stderr)
            self.assertIn("sink bound to 127.0.0.1:", stderr)


if __name__ == "__main__":
    unittest.main()
