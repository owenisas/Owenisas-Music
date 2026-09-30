import base64
import hashlib
import importlib.util
import json
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from datetime import datetime, timedelta, timezone

ROOT = pathlib.Path(__file__).resolve().parents[2]
HELPER = ROOT / '.eas/build/install-profiles.py'
PUBLIC_CERT = b'test public certificate, not a private key'
FINGERPRINT = hashlib.sha1(PUBLIC_CERT).hexdigest().upper()
BUNDLE = 'com.Owenisas-Music'


def profile():
    return {
        'UUID': 'test-profile-uuid',
        'Name': 'Test distribution profile',
        'TeamIdentifier': ['3LHSL95J9H'],
        'ExpirationDate': datetime.now(timezone.utc) + timedelta(days=30),
        'DeveloperCertificates': [PUBLIC_CERT],
        'Entitlements': {
            'application-identifier': '3LHSL95J9H.' + BUNDLE,
            'com.apple.developer.team-identifier': '3LHSL95J9H',
            'get-task-allow': False,
            'com.apple.security.application-groups': ['group.com.Owenisas-Music'],
            'com.apple.developer.icloud-container-identifiers': ['iCloud.com.Owenisas-Music'],
            'com.apple.developer.icloud-container-environment': 'Production',
            'com.apple.developer.icloud-services': ['CloudDocuments'],
            'com.apple.developer.ubiquity-container-identifiers': ['iCloud.com.Owenisas-Music'],
        },
    }


class ManualSigningTests(unittest.TestCase):
    def helper(self):
        self.assertTrue(HELPER.exists(), 'Missing explicit distribution signing helper')
        spec = importlib.util.spec_from_file_location('manual_signing', HELPER)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_distribution_profile_accepts_exact_bundle_and_existing_certificate(self):
        result = self.helper().validate_profile(profile(), BUNDLE, {FINGERPRINT})
        self.assertEqual(result['uuid'], 'test-profile-uuid')
        self.assertEqual(result['identity'], FINGERPRINT)

    def reject(self, mutate):
        data = profile()
        mutate(data)
        with self.assertRaises(ValueError):
            self.helper().validate_profile(data, BUNDLE, {FINGERPRINT})

    def test_wrong_bundle_rejected(self):
        self.reject(lambda p: p['Entitlements'].update({'application-identifier': '3LHSL95J9H.wrong'}))

    def test_wrong_team_rejected(self):
        self.reject(lambda p: p.update({'TeamIdentifier': ['OTHERTEAM']}))

    def test_development_profile_rejected(self):
        self.reject(lambda p: p['Entitlements'].update({'get-task-allow': True}))

    def test_adhoc_profile_rejected(self):
        self.reject(lambda p: p.update({'ProvisionedDevices': ['test-device']}))

    def test_enterprise_profile_rejected(self):
        self.reject(lambda p: p.update({'ProvisionsAllDevices': True}))

    def test_missing_app_group_rejected(self):
        self.reject(lambda p: p['Entitlements'].update({'com.apple.security.application-groups': []}))

    def test_missing_icloud_container_rejected(self):
        self.reject(lambda p: p['Entitlements'].update({'com.apple.developer.icloud-container-identifiers': []}))

    def test_development_icloud_environment_rejected(self):
        self.reject(lambda p: p['Entitlements'].update({'com.apple.developer.icloud-container-environment': 'Development'}))

    def test_profile_allowed_icloud_environment_array_accepts_production(self):
        data = profile()
        data['Entitlements']['com.apple.developer.icloud-container-environment'] = ['Development', 'Production']
        self.assertEqual(self.helper().validate_profile(data, BUNDLE, {FINGERPRINT})['identity'], FINGERPRINT)

    def test_expired_profile_rejected(self):
        self.reject(lambda p: p.update({'ExpirationDate': datetime.now(timezone.utc) - timedelta(seconds=1)}))

    def test_uninstalled_certificate_rejected(self):
        with self.assertRaises(ValueError):
            self.helper().validate_profile(profile(), BUNDLE, {'0' * 40})

    def test_naive_utc_expiration_from_plist_is_supported(self):
        data = profile()
        data['ExpirationDate'] = data['ExpirationDate'].replace(tzinfo=None)
        self.assertEqual(self.helper().validate_profile(data, BUNDLE, {FINGERPRINT})['identity'], FINGERPRINT)

    def test_exactly_five_bundle_profiles_are_required(self):
        module = self.helper()
        self.assertEqual(len(module.PROFILES), 5)
        self.assertEqual(set(module.PROFILES.values()), {
            'com.Owenisas-Music', 'com.Owenisas-Music.ShareExtension',
            'com.Owenisas-Music.Widget', 'com.Owenisas-Music.watchkitapp',
            'com.Owenisas-Music.watchkitapp.Widget',
        })

    def test_export_uses_manual_distribution_identity_and_exact_profiles(self):
        module = self.helper()
        profiles = {bundle: 'uuid-' + str(i) for i, bundle in enumerate(module.PROFILES.values())}
        options = module.export_options(profiles, FINGERPRINT)
        self.assertEqual(options['signingStyle'], 'manual')
        self.assertEqual(options['method'], 'app-store-connect')
        self.assertEqual(options['signingCertificate'], FINGERPRINT)
        self.assertEqual(options['provisioningProfiles'], profiles)
        with self.assertRaises(ValueError):
            module.export_options({BUNDLE: 'uuid-only'}, FINGERPRINT)

    def test_profile_wildcard_icloud_services_permit_cloud_documents(self):
        for allowed in ['*', ['*']]:
            with self.subTest(allowed=allowed):
                data = profile()
                data['Entitlements']['com.apple.developer.icloud-services'] = allowed
                self.assertEqual(self.helper().validate_profile(data, BUNDLE, {FINGERPRINT})['identity'], FINGERPRINT)

    def test_missing_cloud_documents_service_rejected(self):
        self.reject(lambda p: p['Entitlements'].update({'com.apple.developer.icloud-services': []}))

    def test_missing_ubiquity_container_rejected(self):
        self.reject(lambda p: p['Entitlements'].update({'com.apple.developer.ubiquity-container-identifiers': []}))

    def temporary_directory(self):
        parent = ROOT / 'build/release-signing-tests'
        parent.mkdir(parents=True, exist_ok=True)
        return tempfile.TemporaryDirectory(dir=parent)

    def installer_environment(self, module):
        variables = {}
        for index, (name, bundle) in enumerate(module.PROFILES.items()):
            data = profile()
            data['UUID'] = 'test-uuid-' + str(index)
            data['ExpirationDate'] = data['ExpirationDate'].replace(tzinfo=None)
            data['Entitlements']['application-identifier'] = '3LHSL95J9H.' + bundle
            variables[name] = base64.b64encode(plistlib.dumps(data)).decode()
        return variables

    def test_installer_writes_private_profiles_to_modern_and_legacy_locations(self):
        module = self.helper()
        with self.temporary_directory() as temporary:
            root = pathlib.Path(temporary)
            modern, legacy = root / 'modern', root / 'legacy'
            settings = module.install_profiles(root, self.installer_environment(module), {FINGERPRINT},
                                               modern, plistlib.loads, additional_profile_dirs=[legacy])
            for directory in [modern, legacy]:
                paths = list(directory.glob('*.mobileprovision'))
                self.assertEqual(len(paths), 5)
                self.assertTrue(all(path.stat().st_mode & 0o777 == 0o600 for path in paths))
            self.assertEqual(len(settings['profiles']), 5)
            options = plistlib.loads((root / 'ExportOptions.plist').read_bytes())
            self.assertEqual(options['provisioningProfiles'], settings['profiles'])

    def test_missing_last_profile_causes_no_partial_install_or_settings(self):
        module = self.helper()
        variables = self.installer_environment(module)
        variables.pop('OWENISAS_MUSIC_PROFILE_WATCH_WIDGET_B64')
        with self.temporary_directory() as temporary:
            root = pathlib.Path(temporary)
            with self.assertRaises(ValueError):
                module.install_profiles(root, variables, {FINGERPRINT}, root / 'profiles', plistlib.loads)
            self.assertFalse((root / 'profiles').exists())
            self.assertFalse((root / 'ExportOptions.plist').exists())
            self.assertFalse((root / 'signing-settings.json').exists())

    def test_cloud_ruby_rewrites_all_release_profiles_and_preserves_debug(self):
        module = self.helper()
        with self.temporary_directory() as temporary:
            root = pathlib.Path(temporary)
            settings = module.install_profiles(root, self.installer_environment(module), {FINGERPRINT},
                                               root / 'profiles', plistlib.loads)
            project = root / 'Owenisas Music.xcodeproj'
            project.mkdir()
            shutil.copyfile(ROOT / 'Owenisas Music.xcodeproj/project.pbxproj', project / 'project.pbxproj')
            text = (ROOT / '.eas/build/production-ios.yml').read_text()
            ruby = textwrap.dedent(text.split("ruby <<'RUBY'\n", 1)[1].split('\n          RUBY', 1)[0])
            process = subprocess.run(['ruby'], input=ruby, text=True, capture_output=True, cwd=root)
            self.assertEqual(process.returncode, 0, process.stderr)
            raw = subprocess.check_output(['plutil', '-convert', 'xml1', '-o', '-', str(project / 'project.pbxproj')])
            objects = plistlib.loads(raw)['objects']
            configured = set()
            for target in objects.values():
                if target.get('isa') != 'PBXNativeTarget':
                    continue
                for config_id in objects[target['buildConfigurationList']]['buildConfigurations']:
                    config = objects[config_id]
                    build_settings = config['buildSettings']
                    bundle = build_settings.get('PRODUCT_BUNDLE_IDENTIFIER')
                    if bundle not in settings['profiles']:
                        continue
                    if config['name'] == 'Release':
                        self.assertEqual(build_settings['CODE_SIGN_STYLE'], 'Manual')
                        self.assertEqual(build_settings['CODE_SIGN_IDENTITY'], FINGERPRINT)
                        self.assertEqual(build_settings['PROVISIONING_PROFILE_SPECIFIER'], settings['profiles'][bundle])
                        configured.add(bundle)
                    else:
                        self.assertEqual(build_settings['CODE_SIGN_STYLE'], 'Automatic')
            self.assertEqual(configured, set(module.PROFILES.values()))

    def test_workflow_never_asks_xcode_to_mutate_certificates_or_profiles(self):
        text = (ROOT / '.eas/build/production-ios.yml').read_text()
        self.assertNotIn('-allowProvisioningUpdates', text)
        self.assertNotIn('CODE_SIGN_STYLE=Automatic', text)
        self.assertIn('install-profiles.py', text)
        self.assertIn('SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) APP_STORE', text)


if __name__ == '__main__':
    unittest.main()
