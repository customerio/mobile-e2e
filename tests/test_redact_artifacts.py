import base64
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class RedactArtifactsTests(unittest.TestCase):
    script = Path(__file__).parents[1] / "scripts" / "redact_artifacts.py"

    def test_redacts_literal_and_basic_auth_encodings(self):
        secret = "mobile-e2e-test-secret"
        variants = [
            secret.encode(),
            base64.b64encode(secret.encode()),
            base64.b64encode(f":{secret}".encode()),
            base64.b64encode(f"{secret}:".encode()),
            base64.b64encode(f"test-site:{secret}".encode()),
            base64.b64encode(b"android-site:android-cdp-key"),
            base64.b64encode(b"ios-site:ios-cdp-key"),
        ]
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "sdk-live.log"
            artifact.write_bytes(b"\n".join(variants))
            env = os.environ | {
                "MAESTRO_APP_API_KEY": secret,
                "MAESTRO_SITE_ID": "test-site",
                "ANDROID_CDP_API_KEY": "android-cdp-key",
                "ANDROID_SITE_ID": "android-site",
                "IOS_CDP_API_KEY": "ios-cdp-key",
                "IOS_SITE_ID": "ios-site",
            }

            check_before = subprocess.run(
                ["python3", str(self.script), "--check", directory],
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(check_before.returncode, 1)

            subprocess.run(
                ["python3", str(self.script), directory],
                env=env,
                check=True,
            )
            subprocess.run(
                ["python3", str(self.script), "--check", directory],
                env=env,
                check=True,
            )
            contents = artifact.read_bytes()
            for variant in variants:
                self.assertNotIn(variant, contents)


if __name__ == "__main__":
    unittest.main()
