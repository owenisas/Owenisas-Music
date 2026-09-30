#!/usr/bin/env python3
"""Install approved App Store profiles; never create or revoke signing assets."""
import base64
import hashlib
import json
import os
import plistlib
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path

TEAM = '3LHSL95J9H'
GROUP = 'group.com.Owenisas-Music'
MAIN_BUNDLE = 'com.Owenisas-Music'
PROFILES = {
    'OWENISAS_MUSIC_PROFILE_APP_B64': MAIN_BUNDLE,
    'OWENISAS_MUSIC_PROFILE_SHARE_B64': MAIN_BUNDLE + '.ShareExtension',
    'OWENISAS_MUSIC_PROFILE_WIDGET_B64': MAIN_BUNDLE + '.Widget',
    'OWENISAS_MUSIC_PROFILE_WATCH_B64': MAIN_BUNDLE + '.watchkitapp',
    'OWENISAS_MUSIC_PROFILE_WATCH_WIDGET_B64': MAIN_BUNDLE + '.watchkitapp.Widget',
}


def validate_profile(profile, bundle, identities):
    entitlements = profile.get('Entitlements', {})
    if profile.get('TeamIdentifier') != [TEAM]:
        raise ValueError('Distribution profile team mismatch')
    if entitlements.get('application-identifier') != TEAM + '.' + bundle:
        raise ValueError('Distribution profile bundle mismatch')
    if entitlements.get('com.apple.developer.team-identifier') != TEAM:
        raise ValueError('Distribution profile entitlement team mismatch')
    if entitlements.get('get-task-allow') is not False:
        raise ValueError('Development profile is not allowed')
    if 'ProvisionedDevices' in profile or profile.get('ProvisionsAllDevices'):
        raise ValueError('Ad hoc/enterprise profile is not allowed')
    if GROUP not in entitlements.get('com.apple.security.application-groups', []):
        raise ValueError('Required App Group is absent')
    expiration = profile.get('ExpirationDate')
    if not isinstance(expiration, datetime):
        raise ValueError('Distribution profile expiration is missing')
    if expiration.tzinfo is None:
        expiration = expiration.replace(tzinfo=timezone.utc)
    if expiration <= datetime.now(timezone.utc):
        raise ValueError('Distribution profile has expired')
    if bundle == MAIN_BUNDLE:
        if 'iCloud.com.Owenisas-Music' not in entitlements.get('com.apple.developer.icloud-container-identifiers', []):
            raise ValueError('Required iCloud container is absent')
        environments = entitlements.get('com.apple.developer.icloud-container-environment', [])
        if isinstance(environments, str):
            environments = [environments]
        if 'Production' not in environments:
            raise ValueError('Production iCloud environment is required')
        services = entitlements.get('com.apple.developer.icloud-services', [])
        if isinstance(services, str):
            services = [services]
        if 'CloudDocuments' not in services and '*' not in services:
            raise ValueError('Required CloudDocuments service is absent')
        if 'iCloud.com.Owenisas-Music' not in entitlements.get('com.apple.developer.ubiquity-container-identifiers', []):
            raise ValueError('Required ubiquity container is absent')
    fingerprints = {hashlib.sha1(cert).hexdigest().upper() for cert in profile.get('DeveloperCertificates', [])}
    matching = fingerprints.intersection(identities)
    if len(matching) != 1:
        raise ValueError('Profile must match exactly one installed distribution identity')
    if not profile.get('UUID') or not profile.get('Name'):
        raise ValueError('Distribution profile UUID/name is missing')
    return {'uuid': profile['UUID'], 'name': profile['Name'], 'identity': matching.pop()}


def export_options(profiles, identity):
    if set(profiles) != set(PROFILES.values()):
        raise ValueError('All five exact distribution profiles are required')
    return {
        'destination': 'export',
        'method': 'app-store-connect',
        'signingStyle': 'manual',
        'teamID': TEAM,
        'signingCertificate': identity,
        'provisioningProfiles': profiles,
    }


def install_profiles(root, environment, identities, profile_dir, decode, additional_profile_dirs=()):
    # Validate the complete set before writing any settings or installed profile.
    prepared = []
    for variable, bundle in PROFILES.items():
        encoded = environment.get(variable)
        if not encoded:
            raise ValueError('Required distribution profile environment variable is missing: ' + variable)
        try:
            raw = base64.b64decode(encoded, validate=True)
        except ValueError:
            raise ValueError('Invalid profile encoding: ' + variable) from None
        profile = decode(raw)
        prepared.append((bundle, raw, validate_profile(profile, bundle, identities)))
    identity_set = {entry[2]['identity'] for entry in prepared}
    if len(identity_set) != 1:
        raise ValueError('All five profiles must use the existing shared distribution identity')
    identity = identity_set.pop()
    directories = {directory.resolve() for directory in [profile_dir, *additional_profile_dirs]}
    for directory in directories:
        directory.mkdir(parents=True, exist_ok=True)
    mappings = {}
    for bundle, raw, metadata in prepared:
        for directory in directories:
            path = directory / (metadata['uuid'] + '.mobileprovision')
            with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), 'wb') as output:
                output.write(raw)
            path.chmod(0o600)
        mappings[bundle] = metadata['uuid']
    options = export_options(mappings, identity)
    (root / 'ExportOptions.plist').write_bytes(plistlib.dumps(options))
    settings = {'teamID': TEAM, 'identity': identity, 'profiles': mappings}
    (root / 'signing-settings.json').write_text(json.dumps(settings, indent=2))
    return settings


def main():
    root = Path.cwd()
    keychain = root / 'owenisas-music-ci.keychain-db'
    output = subprocess.check_output(['security', 'find-identity', '-v', '-p', 'codesigning', str(keychain)], text=True)
    identities = set(re.findall(r'\b([0-9A-Fa-f]{40})\s+"Apple Distribution:', output))
    if not identities:
        raise ValueError('Existing distribution certificate/private-key identity is unavailable')

    def decode(raw):
        process = subprocess.run(['security', 'cms', '-D'], input=raw, capture_output=True, check=True)
        return plistlib.loads(process.stdout)

    install_profiles(root, os.environ, {identity.upper() for identity in identities},
                     Path.home() / 'Library/Developer/Xcode/UserData/Provisioning Profiles', decode,
                     additional_profile_dirs=[Path.home() / 'Library/MobileDevice/Provisioning Profiles'])
    print('Verified and installed five App Store distribution profiles using the existing identity')


if __name__ == '__main__':
    main()
