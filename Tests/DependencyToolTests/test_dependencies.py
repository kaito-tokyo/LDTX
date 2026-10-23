# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

"""Exercise bot proposals and stale locks without network access or repo mutation."""

import importlib.util
import json
import re
from pathlib import Path
import shutil
import shlex
import subprocess
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

    def test_ci_rejects_xcode_origin_hash_drift(self):
        workflow = (ROOT / '.github/workflows/swift.yml').read_text()
        gate = next(line.strip() for line in workflow.splitlines()
                    if line.strip().startswith('git diff --exit-code -- '))
        command = shlex.split(gate)
        self.assertIn(str(dependencies.XCODE_LOCK), command)
        self.assertLess(workflow.index('-resolvePackageDependencies'), workflow.index(gate))
        subprocess.run(['git', 'init', '--quiet'], cwd=self.root, check=True)
        subprocess.run(['git', 'add', str(dependencies.XCODE_LOCK)], cwd=self.root, check=True)
        self.assertEqual(subprocess.run(command, cwd=self.root, capture_output=True).returncode, 0)
        path = self.root / dependencies.XCODE_LOCK
        data = json.loads(path.read_text())
        data['originHash'] = '0' * 64
        path.write_text(json.dumps(data, indent=2) + '\n')
        drift = subprocess.run(command, cwd=self.root, capture_output=True, text=True)
        self.assertEqual(drift.returncode, 1)
        self.assertIn('originHash', drift.stdout)

    def test_shared_lock_revision_drift_fails(self):
        self.change_lock(dependencies.XCODE_LOCK, 'swift-protobuf', 'revision', 'a' * 40)
        with self.assertRaisesRegex(ValueError, 'revisions disagree'):
            dependencies.check(self.root)

    def test_python_bot_proposal_requires_regeneration(self):
        self.replace('requirements-dev.txt', f'coremltools=={self.coreml}', f'coremltools=={self.newer(self.coreml)}')
        with self.assertRaisesRegex(ValueError, 'regenerate requirements-dev.lock'):
            dependencies.check(self.root)

    def test_removed_direct_python_requirement_requires_regeneration(self):
        version = dependencies.python_pins(self.root / 'requirements-dev.txt')['onnx2torch']
        self.replace('requirements-dev.txt', f'onnx2torch=={version}\n', '')
        with self.assertRaisesRegex(ValueError, 'Direct Python requirements changed'):
            dependencies.check(self.root)

    def test_removed_direct_requirement_may_remain_transitive(self):
        version = dependencies.python_pins(self.root / 'requirements-dev.txt')['onnx']
        self.replace('requirements-dev.txt', f'onnx=={version}\n', '')
        path = self.root / 'requirements-dev.lock'
        text = path.read_text()
        block = re.search(r'^onnx==.*?(?=^\S|\Z)', text, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(block)
        annotated = block[0]
        self.assertIn('    #   -r requirements-dev.txt\n', annotated)
        path.write_text(text.replace(annotated, annotated.replace(
            '    #   -r requirements-dev.txt\n', ''
        )))
        # onnx remains required by onnx2torch, with its hashes and version intact.
        dependencies.check(self.root)
        self.assertIn('onnx', dependencies.python_pins(path, hashed=True))

    def test_uv_direct_annotations_support_both_formats(self):
        direct = dependencies.python_direct_requirements(self.root / 'requirements-dev.lock')
        self.assertIn('onnx2torch', direct)  # single-line annotation
        self.assertIn('onnx', direct)  # multiline annotation
        self.assertNotIn('numpy', direct)  # legitimate transitive dependency

    def test_python_version_metadata_matches_lock_target(self):
        lines = (ROOT / '.python-version').read_text().splitlines()
        version = next(line.strip() for line in lines if line.strip() and not line.startswith('#'))
        self.assertRegex(version, r'^3\.13\.\d+$')
        target = '.'.join(version.split('.')[:2])
        self.assertIn(f'--python-version {target} ', (self.root / 'requirements-dev.lock').read_text())

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
