"""Exercise the release CLI's installation layout and distribution boundary."""

import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile


class ReleaseTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        sources = {
            "koreadalong.koplugin/main.lua": "return {}\n",
            "koreadalong.koplugin/_meta.lua": "return {fullname='KOReadalong'}\n",
            "koreadalong.koplugin/audio.lua": "return {speed=1.7}\n",
            "README.md": "# Installation\n",
            "docs/kindle.md": "# Kindle\n",
            "scripts/kinamp-diagnostic": "#!/bin/sh\nexit 0\n",
            "LICENSE": "Test license text\n",
            ".gitignore": "dist/\n",
            ".cache/sysroot/private.so": "PRIVATE RUNTIME\n",
            ".amp/private-book.epub": "PRIVATE BOOK\n",
            "koreadalong.koplugin/private.log": "PRIVATE LOG\n",
            "KinAMP-minimal": "NOT PART OF PLUGIN\n",
        }
        for name, data in sources.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(data)
        shutil.copyfile(Path(__file__).resolve().parents[1] / "scripts/package-release",
                        self.root / "scripts/package-release")
        subprocess.run(["git", "init", "-q"], cwd=self.root, check=True)
        subprocess.run(["git", "add", "."], cwd=self.root, check=True)
        subprocess.run([
            "git", "-c", "user.name=Release Test", "-c", "user.email=test@example.invalid",
            "-c", "commit.gpgsign=false", "commit", "-qm", "Fixture",
        ], cwd=self.root, check=True)

    def package(self, version="v2.7.4-beta.3"):
        return subprocess.run(
            [sys.executable, "scripts/package-release", version],
            cwd=self.root, text=True, capture_output=True,
        )

    def test_installable_repeatable_archive_excludes_private_inputs(self):
        result = self.package()
        self.assertEqual(result.returncode, 0, result.stderr)
        archive = self.root / "dist/koreadalong-v2.7.4-beta.3.zip"
        original = archive.read_bytes()
        with zipfile.ZipFile(archive) as package:
            self.assertEqual(set(package.namelist()), {
                "koreadalong.koplugin/main.lua", "koreadalong.koplugin/_meta.lua",
                "koreadalong.koplugin/audio.lua", "README.md", "docs/kindle.md",
                "scripts/kinamp-diagnostic", "LICENSE", "RELEASE.json",
            })
            package.extractall(self.root / "installed")
            self.assertEqual((self.root / "installed/koreadalong.koplugin/audio.lua").read_text(),
                             "return {speed=1.7}\n")
            self.assertEqual(package.read("LICENSE"), b"Test license text\n")
            metadata = json.loads(package.read("RELEASE.json"))
            self.assertEqual(metadata["version"], "v2.7.4-beta.3")
            commit = subprocess.check_output(["git", "rev-parse", "HEAD"],
                                             cwd=self.root, text=True).strip()
            self.assertEqual(metadata["source_commit"], commit)
            self.assertFalse(metadata["source_modified"])
        shutil.rmtree(self.root / "installed")
        self.assertEqual((self.root / "dist/SHA256SUMS").read_text(),
                         f"{hashlib.sha256(original).hexdigest()}  {archive.name}\n")
        self.assertEqual(self.package().returncode, 0)
        self.assertEqual(archive.read_bytes(), original)

    def test_local_preview_identifies_missing_license_and_modified_source(self):
        (self.root / "LICENSE").unlink()
        result = self.package()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("choose and add LICENSE", result.stdout)
        with zipfile.ZipFile(self.root / "dist/koreadalong-v2.7.4-beta.3.zip") as package:
            self.assertNotIn("LICENSE", package.namelist())
            self.assertTrue(json.loads(package.read("RELEASE.json"))["source_modified"])

    def test_rejects_non_beta_versions_before_writing_assets(self):
        for version in ("", "v1.2.3", "v1.2.3-beta.0", "v01.2.3-beta.1", "../bad", "v1.2.3-beta.1/evil"):
            with self.subTest(version=version):
                result = self.package(version)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("version must be", result.stderr)
                self.assertFalse((self.root / "dist").exists())


if __name__ == "__main__":
    unittest.main()
