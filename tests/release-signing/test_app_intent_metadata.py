import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE_DIRECTORIES = ['Owenisas Music/Integrations', 'Shared', 'WatchShared']


class AppIntentMetadataTests(unittest.TestCase):
    def test_intent_descriptions_do_not_use_reserved_platform_names(self):
        violations = []
        for directory in SOURCE_DIRECTORIES:
            for path in (ROOT / directory).glob('*.swift'):
                text = path.read_text()
                for match in re.finditer(r'IntentDescription\(\s*"((?:\\.|[^"\\])*)"', text):
                    if re.search(r'\biphone\b', match.group(1), re.IGNORECASE):
                        line = text[:match.start()].count('\n') + 1
                        violations.append(f'{path.relative_to(ROOT)}:{line}')
        self.assertEqual(violations, [], 'Apple ingestion rejects reserved iPhone names in App Intent descriptions')

    def test_custom_enum_display_names_do_not_use_reserved_platform_names(self):
        violations = []
        for directory in SOURCE_DIRECTORIES:
            for path in (ROOT / directory).glob('*.swift'):
                text = path.read_text()
                for match in re.finditer(r'caseDisplayRepresentations\s*:\s*\[Self:\s*DisplayRepresentation\]\s*=\s*\[([^\]]*)\]', text, re.DOTALL):
                    if re.search(r'"[^"\n]*\biphone\b[^"\n]*"', match.group(1), re.IGNORECASE):
                        line = text[:match.start()].count('\n') + 1
                        violations.append(f'{path.relative_to(ROOT)}:{line}')
        self.assertEqual(violations, [], 'Apple ingestion rejects reserved iPhone names in custom enum metadata')


if __name__ == '__main__':
    unittest.main()
