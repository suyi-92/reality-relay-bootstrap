from __future__ import annotations

import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def run_require_supported_os(os_release: str) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory(dir=ROOT) as tmp:
        os_release_path = Path(tmp) / "os-release"
        os_release_path.write_text(
            textwrap.dedent(os_release).strip() + "\n",
            encoding="utf-8",
            newline="\n",
        )
        os_release_posix = os_release_path.relative_to(ROOT).as_posix()
        cmd = textwrap.dedent(
            f"""
            set -Eeuo pipefail
            export RRB_OS_RELEASE_FILE="{os_release_posix}"
            source scripts/00-lib.sh
            require_supported_os
            """
        )
        return subprocess.run(
            ["bash", "-lc", cmd],
            cwd=ROOT,
            text=True,
            capture_output=True,
            encoding="utf-8",
        )


class SupportedOsTest(unittest.TestCase):
    def test_debian_10_through_13_are_supported(self):
        for version in ("10", "11", "12", "13"):
            with self.subTest(version=version):
                result = run_require_supported_os(
                    f"""
                    ID=debian
                    VERSION_ID="{version}"
                    PRETTY_NAME="Debian GNU/Linux {version}"
                    """
                )

                self.assertEqual(result.returncode, 0, result.stderr)

    def test_debian_outside_10_through_13_is_rejected(self):
        for version in ("9", "14"):
            with self.subTest(version=version):
                result = run_require_supported_os(
                    f"""
                    ID=debian
                    VERSION_ID="{version}"
                    PRETTY_NAME="Debian GNU/Linux {version}"
                    """
                )

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("不在默认支持范围", result.stderr)


if __name__ == "__main__":
    unittest.main()
