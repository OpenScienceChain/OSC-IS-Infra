from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PACKAGER = ROOT / "platform/aws/package_webapp_bundle.py"


class WebAppBundleTests(unittest.TestCase):
    def test_bundle_is_deterministic_and_runtime_configured(self) -> None:
        revision = "a" * 40
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "site"
            (source / "assets").mkdir(parents=True)
            (source / "index.html").write_text("<h1>demo</h1>\n", encoding="utf-8")
            (source / "assets/old.txt").write_text("kept\n", encoding="utf-8")
            outputs = [root / "one.tar.gz", root / "two.tar.gz"]
            for output in outputs:
                subprocess.run(
                    [
                        sys.executable,
                        str(PACKAGER),
                        "--source",
                        str(source),
                        "--output",
                        str(output),
                        "--source-revision",
                        revision,
                    ],
                    check=True,
                )
            self.assertEqual(
                hashlib.sha256(outputs[0].read_bytes()).digest(),
                hashlib.sha256(outputs[1].read_bytes()).digest(),
            )
            with tarfile.open(outputs[0], "r:gz") as archive:
                names = archive.getnames()
                self.assertEqual(names, sorted(names))
                config = json.load(archive.extractfile("assets/runtime-config.json"))
                self.assertTrue(config["demoMode"])
                self.assertEqual(config["apiBaseUrl"], "/api/v1")
                self.assertEqual(config["sourceRevision"], revision)
                self.assertTrue(all(member.mtime == 0 for member in archive.getmembers()))

    def test_bundle_rejects_symlinks(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / "site"
            source.mkdir()
            (source / "index.html").write_text("demo", encoding="utf-8")
            try:
                (source / "escape").symlink_to(Path(temp) / "outside")
            except OSError:
                self.skipTest("symbolic links are unavailable on this host")
            result = subprocess.run(
                [
                    sys.executable,
                    str(PACKAGER),
                    "--source",
                    str(source),
                    "--output",
                    str(Path(temp) / "bundle.tar.gz"),
                    "--source-revision",
                    "b" * 40,
                ],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("symbolic links", result.stderr)


if __name__ == "__main__":
    unittest.main()
