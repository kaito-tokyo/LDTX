# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

import importlib.machinery
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).with_name("symbolicate-release-crash")
loader = importlib.machinery.SourceFileLoader("symbolicate_release_crash", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
sys.modules[loader.name] = module
loader.exec_module(module)


class SymbolicateReleaseCrashTests(unittest.TestCase):
    def test_loads_incident_after_ips_header(self):
        header = {"app_name": "LDTX", "timestamp": "2026-08-10 00:00:00.00 +0000"}
        incident = {"procName": "LDTX", "threads": []}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "LDTX.ips"
            path.write_text(f"{json.dumps(header)}\n{json.dumps(incident)}\n", encoding="utf-8")
            self.assertEqual(module.load_ips(path), incident)

    def test_parses_ldtx_tiny_frames(self):
        crash = module.parse_crash({
            "procName": "LDTXTiny",
            "bundleInfo": {
                "CFBundleIdentifier": "tokyo.kaito.ldtx.LDTXTiny",
                "CFBundleShortVersionString": "0.1.46",
                "CFBundleVersion": "123",
            },
            "usedImages": [{
                "name": "LDTXTiny", "uuid": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                "arch": "arm64", "base": 4096,
            }],
            "threads": [{"frames": [{"imageIndex": 0, "imageOffset": 32}]}],
        })
        self.assertEqual(crash.product, "LDTXTiny")
        self.assertEqual(crash.uuid, "AAAAAAAABBBBCCCCDDDDEEEEEEEEEEEE")
        self.assertEqual(crash.frame_addresses, (4128,))

    @mock.patch.object(module, "symbolicate")
    @mock.patch.object(module, "uuids", return_value={"arm64": "BBBB"})
    def test_uuid_mismatch_stops_before_symbolication(self, _mock_uuids, mock_symbolicate):
        crash = module.Crash("LDTX", "1.0", "1", "arm64", "AAAA", 4096, (4128,))
        with self.assertRaisesRegex(module.AnalysisError, "UUID mismatch"):
            module.verify_and_symbolicate(Path("LDTX"), Path("LDTX.app.dSYM"), crash)
        mock_symbolicate.assert_not_called()


if __name__ == "__main__":
    unittest.main()
