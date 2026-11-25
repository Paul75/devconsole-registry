#!/usr/bin/env python3
"""Gardes de check-versions.py (stdlib unittest, aucune dépendance).

Usage : python3 scripts/test_check_versions.py
"""

from __future__ import annotations

import argparse
import importlib.util
import sys
import unittest
from pathlib import Path

# Le script s'appelle `check-versions.py` (tiret) : il n'est pas importable
# par son nom, on le charge donc explicitement depuis son chemin.
SCRIPT = Path(__file__).resolve().parent / "check-versions.py"
spec = importlib.util.spec_from_file_location("check_versions", SCRIPT)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
make_entry = module.make_entry


class MakeEntryTest(unittest.TestCase):
    def setUp(self) -> None:
        self.args = argparse.Namespace(sha=False)

    def test_url_windows_vide_reste_vide_sans_bloquer_la_substitution(self) -> None:
        """Une URL vide = pas d'artefact pour cette plateforme, pas un template.

        spekter 1.4.0 n'a qu'une archive Linux (cf. la release
        spekter-1.4.0) : `url_windows: ""` est un état légitime du registre.
        `make_entry` doit tout de même dériver la version suivante de l'URL
        Linux — sinon le checker entier avorte et la mise à jour est perdue.
        """
        template = {
            "url": "https://exemple/spekter-1.4.0-linux.tar.gz",
            "url_windows": "",
            "sha256": "abc",
            "sha256_windows": "",
        }
        entry = make_entry(template, "1.4.0", "1.5.0", self.args, "spekter")
        self.assertEqual(entry["url"], "https://exemple/spekter-1.5.0-linux.tar.gz")
        self.assertEqual(entry["url_windows"], "")
        self.assertIsNone(entry["sha256"])
        self.assertIsNone(entry["sha256_windows"])

    def test_url_non_vide_sans_la_version_est_toujours_refusee(self) -> None:
        """On ne relâche pas le garde de substitute_version pour autant."""
        template = {"url": "https://exemple/spekter-linux-latest.tar.gz"}
        with self.assertRaises(ValueError):
            make_entry(template, "1.4.0", "1.5.0", self.args, "spekter")


if __name__ == "__main__":
    unittest.main()
