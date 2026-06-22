from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class InstallDefaultsTest(unittest.TestCase):
    def test_installer_preserves_proxy_keys_by_default(self):
        script = (ROOT / "install.sh").read_text(encoding="utf-8")

        self.assertIn('config_env_value "$project_dir/config.env" "RESET_PROXY_KEYS" "false"', script)
        self.assertIn('read_bool_value "RESET_PROXY_KEYS" "$reset_proxy_keys_default"', script)
        self.assertNotIn('read_bool_value "RESET_PROXY_KEYS" "true"', script)


if __name__ == "__main__":
    unittest.main()
