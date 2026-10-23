#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

"""Check dependency pins, or synchronize XcodeGen declarations after a bot proposal.

Uses only Python's standard library. Parsers deliberately accept the repository's
literal exact-pin conventions; a new manifest format requires an explicit update.
"""

import argparse
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
XCODE_LOCK = Path('LDTX.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved')
SWIFT_PIN = re.compile(r'\.package\(url: "([^"]+)", exact: "([^"]+)"\)')
PROJECT_PIN = re.compile(
    r'^  ([\w-]+):\n    url: (\S+)\n    exactVersion: ([\d.]+)$', re.MULTILINE
)
REQUIREMENT = re.compile(r'^([\w.-]+)==([^\s;]+)(.*)$')


def identity(url):
    return url.lower().rstrip('/').removesuffix('.git').rsplit('/', 1)[-1]


def lock_pins(path):
    data = json.loads(path.read_text())
    if data['version'] not in (2, 3):
        raise ValueError(f'{path}: unsupported lock format')
    pins = {pin['identity']: pin for pin in data['pins']}
    if len(pins) != len(data['pins']):
        raise ValueError(f'{path}: duplicate lock identities')
    return pins


def manifests(root):
    swift = (root / 'Package.swift').read_text()
    matches = SWIFT_PIN.findall(swift)
    if not matches or len(matches) != swift.count('.package('):
        raise ValueError('Package.swift: expected literal exact package pins')
    shared = {identity(url): (url, version) for url, version in matches}
    project = (root / 'project.yml').read_text()
    section = project.split('\npackages:\n', 1)[1].split('\nsettings:', 1)[0]
    app = PROJECT_PIN.findall(section)
    if not app or len(app) != len(re.findall(r'^  \S+:$', section, re.MULTILINE)):
        raise ValueError('project.yml: expected literal exact package pins')
    if len(shared) != len(matches) or len({identity(url) for _, url, _ in app}) != len(app):
        raise ValueError('Duplicate manifest dependency identities')
    return shared, app, project


def sync(root):
    shared, app, project = manifests(root)
    lock = lock_pins(root / XCODE_LOCK)
    # Only AppAuth is proposed through the Xcode bot scope. Other app-only
    # packages must get an explicit update policy before this tool accepts them.
    if {identity(url) for _, url, _ in app} != set(shared) | {'appauth-ios'}:
        raise ValueError('Update dependency coverage for new app packages first')
    appauth_url = next(url for _, url, _ in app if identity(url) == 'appauth-ios')
    if lock['appauth-ios']['location'] != appauth_url:
        raise ValueError('AppAuth lock location does not match its identity')
    versions = {key: version for key, (_, version) in shared.items()}
    versions['appauth-ios'] = lock['appauth-ios']['state']['version']
    if any(not re.fullmatch(r'\d+\.\d+\.\d+', version) for version in versions.values()):
        raise ValueError('Expected stable semantic versions before syncing project.yml')
    result = PROJECT_PIN.sub(
        lambda m: f'  {m[1]}:\n    url: {m[2]}\n    exactVersion: {versions[identity(m[2])]}',
        project,
    )
    (root / 'project.yml').write_text(result)
    print('Synchronized project.yml. Resolve SwiftPM and Xcode locks, then run check.')


def python_pins(path, hashed=False):
    result = {}
    text = path.read_text().replace('\\\n', ' ')
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        match = REQUIREMENT.fullmatch(line)
        if not match:
            raise ValueError(f'{path}: expected exact requirement: {line}')
        name, version, suffix = match.groups()
        name = re.sub(r'[-_.]+', '-', name).lower()
        if name in result:
            raise ValueError(f'{path}: duplicate requirement {name}')
        hashes = suffix.split()
        if hashed and (not hashes or any(
            not re.fullmatch(r'--hash=sha256:[0-9a-f]{64}', value) for value in hashes
        )):
            raise ValueError(f'{path}: {name} must have SHA256 hashes')
        if not hashed and hashes:
            raise ValueError(f'{path}: unsupported requirement suffix')
        result[name] = version
    if not result:
        raise ValueError(f'{path}: no requirements found')
    return result


def python_direct_requirements(path):
    """Read uv's single-line and multiline direct-requirement annotations."""
    direct = set()
    current = None
    for line in path.read_text().splitlines():
        match = REQUIREMENT.match(line)
        if match:
            current = re.sub(r'[-_.]+', '-', match[1]).lower()
        if re.fullmatch(r'\s*#\s+(?:via\s+)?-r requirements-dev\.txt\s*', line):
            if current is None:
                raise ValueError(f'{path}: direct annotation without a requirement')
            direct.add(current)
    return direct


def check(root):
    shared, app, _ = manifests(root)
    app_pins = {identity(url): (url, version) for _, url, version in app}
    if set(app_pins) != set(shared) | {'appauth-ios'}:
        raise ValueError('Update dependency coverage for new app packages first')
    for key, value in shared.items():
        if app_pins[key] != value:
            raise ValueError(f'{key}: Package.swift and project.yml disagree; run sync')
    locks = []
    for relative, declared in ((Path('Package.resolved'), shared), (XCODE_LOCK, app_pins)):
        pins = lock_pins(root / relative)
        for key, (url, version) in declared.items():
            pin = pins.get(key, {})
            if pin.get('location') != url or pin.get('state', {}).get('version') != version:
                raise ValueError(f'{relative}: {key} does not match its manifest; resolve locks')
            if not re.fullmatch(r'[0-9a-f]{40}', pin['state'].get('revision', '')):
                raise ValueError(f'{relative}: {key} lacks a commit revision')
        locks.append(pins)
    for key in shared:
        if locks[0][key]['state'] != locks[1][key]['state']:
            raise ValueError(f'{key}: SwiftPM and Xcode lock revisions disagree')
    source = python_pins(root / 'requirements-dev.txt')
    locked = python_pins(root / 'requirements-dev.lock', hashed=True)
    for name, version in source.items():
        if locked.get(name) != version:
            raise ValueError(f'{name}: regenerate requirements-dev.lock with uv pip compile')
    direct = python_direct_requirements(root / 'requirements-dev.lock')
    if direct != set(source):
        raise ValueError('Direct Python requirements changed; regenerate requirements-dev.lock')
    print('Swift manifests/locks and Python source pins/hash lock agree.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('check', 'sync'))
    args = parser.parse_args()
    try:
        (check if args.command == 'check' else sync)(ROOT)
    except (ValueError, KeyError, IndexError, OSError) as error:
        print(f'Dependency error: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
