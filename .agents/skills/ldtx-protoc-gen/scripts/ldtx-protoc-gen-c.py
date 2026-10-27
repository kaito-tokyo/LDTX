#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0
#
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///

import sys
from pathlib import Path

import grpc_tools.protoc

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'nanopb'))
import nanopb_generator

nanopb_generator.main_cli()
