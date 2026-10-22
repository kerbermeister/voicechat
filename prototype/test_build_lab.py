import unittest
from build_lab import credentials

class RedactionTests(unittest.TestCase):
    def test_flutter_flat_and_nested_fixture_credentials_are_detected(self):
        data={'ALICE_PASSWORD':'disposable-password','ROLE':'web',
              'LOAD_ACCOUNTS':'[{"username":"load","password":"another-password"}]'}
        self.assertEqual(credentials(data), {'disposable-password','another-password'})

if __name__ == '__main__': unittest.main()
