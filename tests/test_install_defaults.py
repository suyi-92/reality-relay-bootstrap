from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class InstallDefaultsTest(unittest.TestCase):
    def test_client_udp_is_enabled_by_default_everywhere(self):
        expected_defaults = {
            "install.sh": 'CLIENT_UDP="true"',
            "config.example.env": 'CLIENT_UDP="true"',
            "scripts/00-lib.sh": '${CLIENT_UDP:=true}',
            "scripts/08-generate-singbox-config.py": '"CLIENT_UDP": "true"',
        }

        for relative_path, expected in expected_defaults.items():
            with self.subTest(path=relative_path):
                content = (ROOT / relative_path).read_text(encoding="utf-8")
                self.assertIn(expected, content)

    def test_installer_preserves_proxy_keys_by_default(self):
        script = (ROOT / "install.sh").read_text(encoding="utf-8")

        self.assertIn('config_env_value "$project_dir/config.env" "RESET_PROXY_KEYS" "false"', script)
        self.assertIn('read_bool_value "RESET_PROXY_KEYS" "$reset_proxy_keys_default"', script)
        self.assertNotIn('read_bool_value "RESET_PROXY_KEYS" "true"', script)


if __name__ == "__main__":
    unittest.main()
