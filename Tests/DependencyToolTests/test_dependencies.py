# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

"""Exercise bot proposals and stale locks without network access or repo mutation."""

import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('dependencies', ROOT / 'Tools/dependencies.py')
dependencies = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dependencies)


class DependencyUpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shared, app, _ = dependencies.manifests(ROOT)
        self.protobuf = shared['swift-protobuf'][1]
        self.appauth = next(version for _, url, version in app if dependencies.identity(url) == 'appauth-ios')
        self.coreml = dependencies.python_pins(ROOT / 'requirements-dev.txt')['coremltools']
        for relative in ('Package.swift', 'Package.resolved', 'project.yml',
                         str(dependencies.XCODE_LOCK), 'requirements-dev.txt', 'requirements-dev.lock'):
            destination = self.root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, destination)

    @staticmethod
    def newer(version):
        parts = version.split('.')
        return str(int(parts[0]) + 1) + '.0.0'

    def replace(self, relative, old, new):
        path = self.root / relative
        path.write_text(path.read_text().replace(old, new))

    def change_lock(self, relative, key, field, value):
        path = self.root / relative
        data = json.loads(path.read_text())
        pin = next(pin for pin in data['pins'] if pin['identity'] == key)
        pin['state'][field] = value
        path.write_text(json.dumps(data))

    def test_current_pins_and_sync_are_idempotent(self):
        before = (self.root / 'project.yml').read_bytes()
        dependencies.check(self.root)
        dependencies.sync(self.root)
        self.assertEqual(before, (self.root / 'project.yml').read_bytes())
        dependencies.check(self.root)

    def test_root_swift_bot_proposal_requires_both_locks(self):
        self.replace('Package.swift', f'exact: "{self.protobuf}"', f'exact: "{self.newer(self.protobuf)}"')
        self.change_lock('Package.resolved', 'swift-protobuf', 'version', self.newer(self.protobuf))
        with self.assertRaisesRegex(ValueError, 'disagree'):
            dependencies.check(self.root)
        dependencies.sync(self.root)
        with self.assertRaisesRegex(ValueError, 'resolve locks'):
            dependencies.check(self.root)
        self.change_lock(dependencies.XCODE_LOCK, 'swift-protobuf', 'version', self.newer(self.protobuf))
        dependencies.check(self.root)

    def test_appauth_bot_lock_proposal_syncs_xcodegen(self):
        self.change_lock(dependencies.XCODE_LOCK, 'appauth-ios', 'version', self.newer(self.appauth))
        with self.assertRaisesRegex(ValueError, 'resolve locks'):
            dependencies.check(self.root)
        dependencies.sync(self.root)
        self.assertIn(f'exactVersion: {self.newer(self.appauth)}', (self.root / 'project.yml').read_text())
        dependencies.check(self.root)

    def test_shared_lock_revision_drift_fails(self):
        self.change_lock(dependencies.XCODE_LOCK, 'swift-protobuf', 'revision', 'a' * 40)
        with self.assertRaisesRegex(ValueError, 'revisions disagree'):
            dependencies.check(self.root)

    def test_python_bot_proposal_requires_regeneration(self):
        self.replace('requirements-dev.txt', f'coremltools=={self.coreml}', f'coremltools=={self.newer(self.coreml)}')
        with self.assertRaisesRegex(ValueError, 'regenerate requirements-dev.lock'):
            dependencies.check(self.root)

    def test_unhashed_transitive_requirement_fails(self):
        with (self.root / 'requirements-dev.lock').open('a') as file:
            file.write('\nnew-transitive==1.0\n')
        with self.assertRaisesRegex(ValueError, 'SHA256 hashes'):
            dependencies.check(self.root)

    def test_uncovered_app_package_fails(self):
        self.replace('project.yml', '\nsettings:', '\n  NewPackage:\n    url: https://example.com/new\n    exactVersion: 1.0.0\n\nsettings:')
        with self.assertRaisesRegex(ValueError, 'coverage'):
            dependencies.check(self.root)

    def test_nonliteral_swift_requirement_fails(self):
        self.replace('Package.swift', f'exact: "{self.protobuf}"', f'from: "{self.protobuf}"')
        with self.assertRaisesRegex(ValueError, 'literal exact'):
            dependencies.check(self.root)

    def test_python_name_normalization(self):
        self.replace('requirements-dev.txt', 'huggingface_hub', 'huggingface.hub')
        dependencies.check(self.root)


if __name__ == '__main__':
    unittest.main()
