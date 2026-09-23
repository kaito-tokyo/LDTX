# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
APPLET_TARGETS = (
    "LDTXLauncherApplet",
    "LDTXWorkspaceApplet",
    "LDTXRecordPlayerApplet",
    "LDTXSettingsApplet",
)


class AppletIsolationTests(unittest.TestCase):
    def test_applet_targets_do_not_depend_on_each_other(self):
        project = (ROOT / "project/app.yml").read_text(encoding="utf-8")
        for target in APPLET_TARGETS:
            match = re.search(
                rf"^  {target}:\n(.*?)(?=^  \S|\Z)", project, re.MULTILINE | re.DOTALL
            )
            self.assertIsNotNone(match, f"Missing target {target}")
            target_body = match.group(1)
            for dependency in re.findall(r"^      - target: (\S+)", target_body, re.MULTILINE):
                self.assertNotIn(
                    dependency,
                    APPLET_TARGETS,
                    f"{target} directly depends on applet target {dependency}",
                )

    def test_applet_sources_do_not_import_other_applet_modules(self):
        for target in APPLET_TARGETS:
            source_root = ROOT / "Sources" / target
            self.assertTrue(source_root.is_dir(), f"Missing source directory {source_root}")
            for source in source_root.rglob("*.swift"):
                imports = re.findall(r"^import (\w+)", source.read_text(encoding="utf-8"), re.MULTILINE)
                for imported_module in imports:
                    if imported_module in APPLET_TARGETS:
                        self.assertEqual(
                            imported_module,
                            target,
                            f"{source.relative_to(ROOT)} imports applet module {imported_module}",
                        )


if __name__ == "__main__":
    unittest.main()
