import importlib.util
import json
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
HELPER = ROOT / '.eas/build/validate-app-intents.py'


class CompiledIntentMetadataTests(unittest.TestCase):
    def validator(self):
        self.assertTrue(HELPER.is_file(), 'Compiled App Intent metadata validator must exist')
        spec = importlib.util.spec_from_file_location('compiled_intents', HELPER)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_description_rejects_reserved_name(self):
        metadata = {'actions': {'PlaySongIntent': {'descriptionMetadata': {'descriptionText': {'key': 'Play on your iPhone.'}}}}, 'enums': []}
        self.assertEqual(len(self.validator().violations(metadata)), 1)

    def test_enum_case_rejects_reserved_name(self):
        metadata = {'actions': {}, 'enums': [{'identifier': 'WatchPlaybackTarget', 'cases': [{'identifier': 'phone', 'displayRepresentation': {'title': {'key': 'iPhone'}}}]}]}
        self.assertEqual(len(self.validator().violations(metadata)), 1)

    def test_safe_metadata_passes(self):
        metadata = {'actions': {'PlaySongIntent': {'descriptionMetadata': {'descriptionText': {'key': 'Play from your library.'}}}}, 'enums': [{'identifier': 'WatchPlaybackTarget', 'cases': [{'identifier': 'phone', 'displayRepresentation': {'title': {'key': 'Phone'}}}]}]}
        self.assertEqual(self.validator().violations(metadata), [])

    def test_unrelated_runtime_text_is_not_rejected(self):
        metadata = {'actions': {'PlaySongIntent': {'dialog': 'Playing on iPhone.'}}, 'enums': []}
        self.assertEqual(self.validator().violations(metadata), [])

    def test_reserved_name_is_case_insensitive(self):
        metadata = {'actions': {'PlaySongIntent': {'descriptionMetadata': {'descriptionText': {'key': 'Play on IPHONE.'}}}}, 'enums': []}
        self.assertEqual(len(self.validator().violations(metadata)), 1)

    def test_invalid_metadata_fails_closed(self):
        with self.assertRaises(ValueError):
            self.validator().violations({'unexpectedSchema': True})

    def test_missing_compiled_metadata_fails_closed(self):
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaises(ValueError):
                self.validator().validate_app(pathlib.Path(root))

    def test_nested_bundle_is_checked(self):
        module = self.validator()
        with tempfile.TemporaryDirectory() as root:
            root = pathlib.Path(root)
            main = root / 'Metadata.appintents/extract.actionsdata'
            nested = root / 'PlugIns/Widget.appex/Metadata.appintents/extract.actionsdata'
            main.parent.mkdir(parents=True)
            nested.parent.mkdir(parents=True)
            main.write_text(json.dumps({'actions': {}, 'enums': []}))
            nested.write_text(json.dumps({'actions': {'Configure': {'descriptionMetadata': {'descriptionText': {'key': 'Pin from iPhone.'}}}}, 'enums': []}))
            with self.assertRaisesRegex(ValueError, 'Configure'):
                module.validate_app(root)


if __name__ == '__main__':
    unittest.main()
