"""Invalid copied credentials must fail before any network or secret writes."""
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'infra'))
import setup_yandex


class YandexInputTests(unittest.TestCase):
    def test_invalid_credentials_are_rejected_without_echoing_them(self):
        cases = [('sender@yandex.ru', password) for password in
                 ('copied-secret»', 'пароль', 'copied-secret\xa0', 'copied secret', 'copied-secret\t', '\x1bsecret')]
        cases += [('отправитель@yandex.ru', 'ascii-secret')]
        for address, password in cases:
            with self.subTest(address=address, password=password), \
                 patch.object(Path, 'exists', return_value=False), \
                 patch('builtins.input', return_value=address), \
                 patch.object(setup_yandex.getpass, 'getpass', return_value=password), \
                 patch.object(setup_yandex.smtplib, 'SMTP') as smtp, \
                 patch.object(setup_yandex.bootstrap, 'main') as bootstrap:
                with self.assertRaises(SystemExit) as result:
                    setup_yandex.main()
                smtp.assert_not_called()
                bootstrap.assert_not_called()
                self.assertNotIn(password, str(result.exception))


if __name__ == '__main__':
    unittest.main()
