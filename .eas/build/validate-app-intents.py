#!/usr/bin/env python3
"""Catch the observed ASC 90626 reserved-name rule in compiled intent metadata."""

import argparse
import json
import pathlib
import re

RESERVED_NAME = re.compile(r'\biphone\b', re.IGNORECASE)


def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for child in value.values():
            yield from strings(child)
    elif isinstance(value, list):
        for child in value:
            yield from strings(child)


def violations(metadata):
    if not isinstance(metadata, dict) or not isinstance(metadata.get('actions'), dict) or not isinstance(metadata.get('enums'), list):
        raise ValueError('Unrecognized compiled App Intent metadata schema')
    problems = []
    for identifier, action in metadata['actions'].items():
        description = action.get('descriptionMetadata', {})
        if any(RESERVED_NAME.search(text) for text in strings(description)):
            problems.append(f'Intent description: {identifier}')
    for enum in metadata['enums']:
        identifier = enum.get('identifier', '<unnamed>')
        if any(RESERVED_NAME.search(text) for text in strings(enum.get('displayTypeName', {}))):
            problems.append(f'Enum display type: {identifier}')
        for case in enum.get('cases', []):
            if any(RESERVED_NAME.search(text) for text in strings(case.get('displayRepresentation', {}))):
                problems.append(f'Enum case: {identifier}.{case.get("identifier", "<unnamed>")}')
    return problems


def validate_app(app):
    metadata_files = sorted(app.rglob('Metadata.appintents/extract.actionsdata'))
    if not metadata_files:
        raise ValueError('Compiled App Intent metadata is missing')
    problems = []
    for path in metadata_files:
        for problem in violations(json.loads(path.read_text())):
            problems.append(f'{path.relative_to(app)}: {problem}')
    if problems:
        raise ValueError('Reserved platform name in compiled Siri metadata:\n' + '\n'.join(problems))
    return len(metadata_files)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=pathlib.Path)
    args = parser.parse_args()
    try:
        count = validate_app(args.app)
    except (ValueError, OSError, TypeError) as error:
        parser.exit(1, f'ERROR: {error}\n')
    print(f'Compiled App Intent reserved-name check passed for {count} bundles')


if __name__ == '__main__':
    main()
