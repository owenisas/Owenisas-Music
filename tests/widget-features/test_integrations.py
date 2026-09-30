import pathlib
import plistlib
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]

class WidgetIntegrationTests(unittest.TestCase):
    def test_bootstrap_starts_live_activity_and_playlist_publisher(self):
        text = (ROOT / 'Owenisas Music/FeatureBootstrap.swift').read_text()
        self.assertRegex(text, r'Task\s*\{\s*@MainActor in\s*SleepTimerActivityBridge\.shared\.start\(\)\s*PlaylistWidgetPublisher\.shared\.start\(\)')

    def test_watch_project_graph_shared_sources_and_configuration(self):
        raw = subprocess.check_output(['plutil', '-convert', 'xml1', '-o', '-', str(ROOT / 'Owenisas Music.xcodeproj/project.pbxproj')])
        project = plistlib.loads(raw)
        objects = project['objects']
        targets = {o['name']: o for o in objects.values() if o.get('isa') == 'PBXNativeTarget'}
        watch = targets['OwenisasWatch']
        widget = targets['OwenisasWatchWidget']
        widget_id = next(k for k, v in objects.items() if v is widget)
        self.assertTrue(any(objects[d]['target'] == widget_id for d in watch['dependencies']))
        copies = [objects[p] for p in watch['buildPhases'] if objects[p]['isa'] == 'PBXCopyFilesBuildPhase']
        self.assertTrue(any(str(p['dstSubfolderSpec']) == '13' and any(objects[f]['fileRef'] == widget['productReference'] for f in p['files']) for p in copies))
        self.assertEqual(widget['productType'], 'com.apple.product-type.app-extension')
        sources = [objects[objects[f]['fileRef']]['path'] for p in widget['buildPhases'] if objects[p]['isa'] == 'PBXSourcesBuildPhase' for f in objects[p]['files']]
        self.assertCountEqual(sources, ['WatchShared/WatchWidgetSnapshot.swift', 'WatchShared/WatchWidgetStore.swift', 'WatchShared/WatchWidgetPlaybackIntent.swift'])
        self.assertIn('OwenisasWatchWidget', [objects[g]['path'] for g in widget['fileSystemSynchronizedGroups']])
        for name, target in targets.items():
            for config_id in objects[target['buildConfigurationList']]['buildConfigurations']:
                settings = objects[config_id]['buildSettings']
                self.assertEqual('WATCH_WIDGET_EXTENSION' in settings.get('SWIFT_ACTIVE_COMPILATION_CONDITIONS', ''), name == 'OwenisasWatchWidget')
                if name in ['OwenisasWatch', 'OwenisasWatchWidget']:
                    entitlements = plistlib.loads((ROOT / settings['CODE_SIGN_ENTITLEMENTS']).read_bytes())
                    self.assertIn('group.com.Owenisas-Music', entitlements['com.apple.security.application-groups'])
        for name in ['Owenisas Music', 'OwenisasWidget']:
            self.assertIn('Shared', [objects[g]['path'] for g in targets[name]['fileSystemSynchronizedGroups']])
        info = plistlib.loads((ROOT / 'Config/OwenisasWatch-Info.plist').read_bytes())
        self.assertIn('owenisas-watch', [s for entry in info['CFBundleURLTypes'] for s in entry['CFBundleURLSchemes']])
        info = plistlib.loads((ROOT / 'Config/OwenisasWatchWidget-Info.plist').read_bytes())
        self.assertEqual(info['NSExtension']['NSExtensionPointIdentifier'], 'com.apple.widgetkit-extension')

    def test_watch_has_real_extension_and_explicit_families(self):
        file = ROOT / 'OwenisasWatchWidget/OwenisasWatchWidgetBundle.swift'
        self.assertTrue(file.exists(), 'Watch WidgetKit extension is missing')
        text = file.read_text()
        for token in ['@main', 'WidgetBundle', 'accessoryCircular', 'accessoryRectangular', 'accessoryInline', 'WatchPhoneWidget()', 'WatchOfflineWidget()']:
            self.assertIn(token, text)

    def test_phone_playlist_widget_uses_app_intent_configuration(self):
        file = ROOT / 'OwenisasWidget/PlaylistWidget.swift'
        self.assertTrue(file.exists(), 'Configurable playlist widget is missing')
        self.assertIn('AppIntentConfiguration', file.read_text())
        self.assertIn('PlaylistWidget()', (ROOT / 'OwenisasWidget/OwenisasWidgetBundle.swift').read_text())

    def test_useful_controls_keep_existing_play_pause(self):
        bundle = (ROOT / 'OwenisasWidget/OwenisasWidgetBundle.swift').read_text()
        for token in ['NowPlayingWidget()', 'PlayPauseControl()', 'NextTrackControl()', 'FavoriteTrackControl()', 'SleepTimerLiveActivity()']:
            self.assertIn(token, bundle)

    def test_watch_buttons_have_destination_specific_intent(self):
        file = ROOT / 'WatchShared/WatchWidgetPlaybackIntent.swift'
        self.assertTrue(file.exists(), 'Watch playback intent missing')
        text = file.read_text()
        for token in ['AudioPlaybackIntent', 'case .phone:', 'case .watch:', 'PhoneLink.shared', 'WatchLocalPlayer.shared', 'throw']:
            self.assertIn(token, text)
        self.assertIn('Button(intent:', (ROOT / 'OwenisasWatchWidget/OwenisasWatchWidgetBundle.swift').read_text())

    def test_watch_links_are_consumed_without_iphone_fallback(self):
        text = (ROOT / 'OwenisasWatch/RootView.swift').read_text()
        self.assertIn('.onOpenURL', text)
        self.assertIn('WatchWidgetDestination(url:', text)
        for token in ['.phoneNowPlaying', '.watchNowPlaying', '.offline']:
            self.assertIn(token, text)

if __name__ == '__main__':
    unittest.main()
