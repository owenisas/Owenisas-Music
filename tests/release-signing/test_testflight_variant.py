import json
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class TestFlightVariantTests(unittest.TestCase):
    def test_testflight_profile_has_separate_workflow(self):
        config = json.loads((ROOT / 'eas.json').read_text())
        beta = config['build'].get('testflight', {})
        self.assertEqual(beta.get('ios', {}).get('config'), 'testflight-ios.yml')
        self.assertEqual(beta.get('distribution'), 'store')
        self.assertEqual(beta.get('environment'), 'production')

    def test_beta_retains_download_and_signing_gates(self):
        path = ROOT / '.eas/build/testflight-ios.yml'
        self.assertTrue(path.is_file())
        text = path.read_text()
        self.assertNotIn('APP_STORE', text)
        self.assertIn('OWENISAS_DISTRIBUTION=personal', text)
        self.assertIn('install-profiles.py', text)
        self.assertIn('validate-app-intents.py', text)
        self.assertIn('Download Music', text)
        self.assertIn('youtubei/v1/player', text)
        self.assertIn('public\\.(url|plain-text)', text)
        self.assertNotIn('-allowProvisioningUpdates', text)

    def test_production_remains_import_only(self):
        text = (ROOT / '.eas/build/production-ios.yml').read_text()
        self.assertIn('APP_STORE', text)
        self.assertIn('OWENISAS_DISTRIBUTION=appstore', text)


if __name__ == '__main__':
    unittest.main()
