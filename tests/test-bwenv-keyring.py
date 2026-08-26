import importlib.util
import io
import sys
import types
import unittest
from importlib.machinery import SourceFileLoader
from pathlib import Path
from unittest.mock import patch


HELPER = Path(__file__).parents[1] / "bin" / "bwenv-keyring"


class KeyringError(Exception):
    pass


class PasswordDeleteError(KeyringError):
    pass


class FakeBackend:
    priority = 1


class BwenvKeyringTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        loader = SourceFileLoader("bwenv_keyring", str(HELPER))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        cls.helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.helper)

    def setUp(self):
        self.values = {}
        keyring = types.ModuleType("keyring")
        errors = types.ModuleType("keyring.errors")
        errors.KeyringError = KeyringError
        errors.PasswordDeleteError = PasswordDeleteError
        keyring.errors = errors
        keyring.get_keyring = lambda: FakeBackend()
        keyring.set_password = lambda service, name, value: self.values.__setitem__((service, name), value)
        keyring.get_password = lambda service, name: self.values.get((service, name))

        def delete_password(service, name):
            try:
                del self.values[(service, name)]
            except KeyError as error:
                raise PasswordDeleteError from error

        keyring.delete_password = delete_password
        self.modules = {"keyring": keyring, "keyring.errors": errors}

    def run_helper(self, *args, stdin=""):
        stdout = io.StringIO()
        stderr = io.StringIO()
        with (
            patch.dict(sys.modules, self.modules),
            patch.object(sys, "argv", [str(HELPER), *args]),
            patch.object(sys, "stdin", io.StringIO(stdin)),
            patch.object(sys, "stdout", stdout),
            patch.object(sys, "stderr", stderr),
        ):
            result = self.helper.main()
        return result, stdout.getvalue(), stderr.getvalue()

    def test_put_get_and_delete(self):
        self.assertEqual(self.run_helper("put", "API_TOKEN", stdin="test-value")[0], 0)
        result, output, _ = self.run_helper("get", "API_TOKEN")
        self.assertEqual((result, output), (0, "test-value"))
        self.assertEqual(self.run_helper("delete", "API_TOKEN")[0], 0)
        self.assertEqual(self.run_helper("get", "API_TOKEN")[0], 1)

    def test_rejects_invalid_names_and_empty_values(self):
        self.assertEqual(self.run_helper("put", "INVALID-NAME", stdin="value")[0], 1)
        self.assertEqual(self.run_helper("put", "VALID_NAME", stdin="")[0], 1)

    def test_status_reports_backend_without_reading_values(self):
        result, output, _ = self.run_helper("status")
        self.assertEqual(result, 0)
        self.assertIn("FakeBackend", output)


if __name__ == "__main__":
    unittest.main()
