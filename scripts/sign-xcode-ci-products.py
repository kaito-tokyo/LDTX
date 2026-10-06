#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
# SPDX-License-Identifier: Apache-2.0

"""Sign unsigned Xcode test products from the inside out for CI experiments."""

import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

products = Path(sys.argv[1]).resolve()
profile = Path.home() / 'Library/Developer/Xcode/UserData/Provisioning Profiles' / (
    os.environ['LDTX_APP_PROVISIONING_PROFILE_UUID'] + '.provisionprofile'
)
team = '4HMJS6J4MZ'
identity = 'Apple Development'
macho_magic = {
    b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf',
    b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca',
    b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca',
}
bundles = []
app_found = False

with tempfile.TemporaryDirectory(prefix='ldtx-ci-sign-') as temporary:
    for path in products.rglob('*'):
        if path.is_symlink():
            continue
        if path.is_dir() and path.suffix in {'.app', '.framework', '.xpc', '.appex', '.xctest'}:
            bundles.append(path)
        elif path.is_file():
            with path.open('rb') as file:
                is_macho = file.read(4) in macho_magic
            if is_macho:
                subprocess.run(['codesign', '--force', '--sign', identity,
                                '--timestamp=none', str(path)], check=True)

    for bundle in sorted(bundles, key=lambda path: len(path.parts), reverse=True):
        entitlements = None
        if bundle.suffix == '.app':
            entitlements = {'com.apple.security.get-task-allow': True}
            info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
            if info['CFBundleIdentifier'] == 'tokyo.kaito.ldtx.LDTX':
                app_found = True
                shutil.copyfile(profile, bundle / 'Contents/embedded.provisionprofile')
                source = Path('Sources/LDTXApp/LDTX.entitlements').read_text()
                source = source.replace('$(AppIdentifierPrefix)', team + '.')
                source = source.replace('$(TeamIdentifierPrefix)', team + '.')
                source = source.replace('$(PRODUCT_BUNDLE_IDENTIFIER)', info['CFBundleIdentifier'])
                entitlements.update(plistlib.loads(source.encode()))
                entitlements['com.apple.application-identifier'] = team + '.' + info['CFBundleIdentifier']
                entitlements['com.apple.developer.team-identifier'] = team
        elif bundle.suffix == '.appex':
            source = Path('Sources') / bundle.stem / (bundle.stem + '.entitlements')
            entitlements = plistlib.loads(source.read_bytes())

        command = ['codesign', '--force', '--sign', identity, '--timestamp=none']
        if bundle.suffix in {'.app', '.xpc', '.appex'}:
            command += ['--options', 'runtime']
        if entitlements is not None:
            entitlement_path = Path(temporary) / 'entitlements.plist'
            entitlement_path.write_bytes(plistlib.dumps(entitlements))
            command += ['--entitlements', str(entitlement_path)]
        subprocess.run(command + [str(bundle)], check=True)

    if not app_found:
        raise RuntimeError('LDTX.app was not found in the build products')
    for bundle in bundles:
        subprocess.run(['codesign', '--verify', '--strict', str(bundle)], check=True)
