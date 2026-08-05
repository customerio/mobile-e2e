import importlib.util
import os
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "scripts" / "render_report.py"
SPEC = importlib.util.spec_from_file_location("render_report", MODULE_PATH)
render_report = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(render_report)


class RenderReportArtifactDiscoveryTests(unittest.TestCase):
    def test_finds_legacy_flattened_commands(self):
        with tempfile.TemporaryDirectory() as directory:
            debug = Path(directory)
            expected = debug / "commands-(flow).json"
            expected.write_text("[]")

            self.assertEqual(render_report.find_commands_json(debug), expected)

    def test_finds_maestro_2_nested_commands(self):
        with tempfile.TemporaryDirectory() as directory:
            debug = Path(directory)
            expected = debug / "Message Inbox" / "commands.json"
            expected.parent.mkdir()
            expected.write_text("[]")

            self.assertEqual(render_report.find_commands_json(debug), expected)

    def test_finds_latest_maestro_2_failure_screenshot(self):
        with tempfile.TemporaryDirectory() as directory:
            debug = Path(directory)
            earlier = (
                debug / "Message Inbox" / "screenshots" / "step-015-tap.png"
            )
            expected = debug / "Message Inbox" / "screenshots" / "step-038.png"
            expected.parent.mkdir(parents=True)
            earlier.write_bytes(b"png")
            expected.write_bytes(b"png")
            # Simulate an extracted CI archive where all entries share an
            # identical timestamp; the step filename must break the tie.
            same_timestamp = 1_700_000_000
            os.utime(earlier, (same_timestamp, same_timestamp))
            os.utime(expected, (same_timestamp, same_timestamp))

            self.assertEqual(render_report.find_failure_screenshot(debug), expected)


if __name__ == "__main__":
    unittest.main()
