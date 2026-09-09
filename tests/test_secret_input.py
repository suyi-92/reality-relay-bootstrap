from __future__ import annotations

import os
import select
import shutil
import signal
import subprocess
import time
import unittest
from pathlib import Path

if os.name == "posix":
    import fcntl
    import pty
    import termios


ROOT = Path(__file__).resolve().parents[1]


def controlling_terminal():
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)


class TerminalPrompt:
    def __init__(self, function: str, label: str = "CLOUDFLARE_API_TOKEN", default: str = "", echo: bool = True):
        self.master, self.slave = pty.openpty()
        state = termios.tcgetattr(self.slave)
        if not echo:
            state[3] &= ~termios.ECHO
            termios.tcsetattr(self.slave, termios.TCSANOW, state)
        self.initial_state = termios.tcgetattr(self.slave)
        script = """\
set -Eeuo pipefail
BOLD='' DIM='' RESET=''
INPUT_TTY="$1"
die() { printf '%s\\n' "$*" >&2; exit 1; }
trap 'printf outer-cleanup >&2' EXIT
""" + function + """\
secret="$(read_secret_default "$2" "$3")"
printf '%s' "$secret"
"""
        self.process = subprocess.Popen(
            ["bash", "--noprofile", "--norc", "-c", script, "secret-input-test", os.ttyname(self.slave), label, default],
            stdin=self.slave,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={**os.environ, "LC_ALL": "C.UTF-8"},
            preexec_fn=controlling_terminal,
        )
        self.output = b""

    def __enter__(self):
        self.read_until(b": ")
        return self

    def read_until(self, marker: bytes):
        deadline = time.monotonic() + 5
        while marker not in self.output:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.master], [], [], remaining)[0]:
                raise AssertionError(f"Terminal did not display {marker!r}; output: {self.output!r}")
            self.output += os.read(self.master, 65536)
        return self.output

    def send(self, value: str | bytes):
        os.write(self.master, value.encode("utf-8") if isinstance(value, str) else value)

    def finish(self):
        value, errors = self.process.communicate(timeout=5)
        while select.select([self.master], [], [], 0.05)[0]:
            self.output += os.read(self.master, 65536)
        return value, errors, self.process.returncode

    def __exit__(self, *_):
        if self.process.poll() is None:
            os.killpg(self.process.pid, signal.SIGKILL)
        self.process.communicate(timeout=5)
        self.process.stdout.close()
        self.process.stderr.close()
        os.close(self.master)
        os.close(self.slave)


@unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "Requires a Linux/POSIX terminal and Bash")
class SecretInputTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        script = (ROOT / "install.sh").read_text(encoding="utf-8")
        start = script.index("read_secret_default() ")
        end = script.index("\nread_yes_no()", start)
        # Exercise the real prompt without running installation or requiring root.
        cls.function = script[start:end]

    def assert_restored(self, prompt):
        self.assertEqual(termios.tcgetattr(prompt.slave), prompt.initial_state)

    def assert_value(self, prompt, expected):
        value, errors, status = prompt.finish()
        self.assertEqual(status, 0, errors)
        self.assertEqual(value, expected.encode("utf-8"))
        self.assertEqual(errors, b"outer-cleanup")
        self.assert_restored(prompt)
        if expected:
            self.assertNotIn(expected.encode("utf-8"), prompt.output)

    def test_each_typed_character_is_masked_immediately_for_both_secret_fields(self):
        for label in ["CLOUDFLARE_API_TOKEN", "  password"]:
            with self.subTest(label=label), TerminalPrompt(self.function, label) as prompt:
                for length, char in enumerate("aBc_9-Z", 1):
                    prompt.send(char)
                    prompt.read_until(b"*" * length)
                prompt.send("\n")
                self.assert_value(prompt, "aBc_9-Z")
                self.assertEqual(prompt.output.count(b"*"), 7)

    def test_paste_preserves_unicode_spaces_and_shell_characters(self):
        secret = "密钥🙂 /$`'\"\\_*=" + "aB9-_" * 40
        with TerminalPrompt(self.function, "  password") as prompt:
            prompt.send(secret)
            prompt.read_until(b"*" * len(secret))
            prompt.send("\r")
            self.assert_value(prompt, secret)
            self.assertEqual(prompt.output.count(b"*"), len(secret))

    def test_backspace_removes_one_character_and_one_mask(self):
        with TerminalPrompt(self.function) as prompt:
            prompt.send(b"\x7f")
            prompt.send("ab🙂")
            prompt.read_until(b"***")
            prompt.send(b"\x7f")
            prompt.read_until(b"***\b \b")
            prompt.send(b"X\x08cd\n")
            self.assert_value(prompt, "abcd")
            self.assertEqual(prompt.output.count(b"\b \b"), 2)
            self.assertEqual(prompt.output.count(b"*") - prompt.output.count(b"\b \b"), 4)

    def test_ctrl_u_clears_input_and_masks(self):
        with TerminalPrompt(self.function) as prompt:
            prompt.send(b"abc\x15XYZ\n")
            self.assert_value(prompt, "XYZ")
            self.assertEqual(prompt.output.count(b"\b \b"), 3)

    def test_enter_uses_default_without_displaying_it(self):
        for default in ["", "saved-secret-value"]:
            with self.subTest(default=bool(default)), TerminalPrompt(self.function, default=default) as prompt:
                prompt.send("\n")
                self.assert_value(prompt, default)
                self.assertNotIn(b"*", prompt.output)

    def test_cursor_keys_and_bracketed_paste_do_not_change_secret(self):
        with TerminalPrompt(self.function) as prompt:
            prompt.send(b"\x1b[200~pasted-token\x1b[201~\x1b[D\x1b[3~\x1bOF\n")
            self.assert_value(prompt, "pasted-token")
            self.assertEqual(prompt.output.count(b"*"), len("pasted-token"))

    def test_ctrl_d_aborts_without_accepting_partial_input_or_default(self):
        with TerminalPrompt(self.function, default="saved-value") as prompt:
            prompt.send(b"partial\x04")
            value, _, status = prompt.finish()
            self.assertNotEqual(status, 0)
            self.assertEqual(value, b"")
            self.assert_restored(prompt)

    def test_ctrl_c_and_sigterm_restore_terminal(self):
        for interrupt in ["ctrl-c", "sigterm"]:
            with self.subTest(interrupt=interrupt), TerminalPrompt(self.function) as prompt:
                prompt.send("partial")
                prompt.read_until(b"*******")
                if interrupt == "ctrl-c":
                    prompt.send(b"\x03")
                else:
                    os.killpg(prompt.process.pid, signal.SIGTERM)
                value, _, status = prompt.finish()
                self.assertNotEqual(status, 0)
                self.assertEqual(value, b"")
                self.assert_restored(prompt)

    def test_original_echo_setting_is_preserved(self):
        with TerminalPrompt(self.function, echo=False) as prompt:
            prompt.send("keep-mode\n")
            self.assert_value(prompt, "keep-mode")


if __name__ == "__main__":
    unittest.main()
