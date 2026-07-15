#!/bin/sh

# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

set -eu

libtool_path="$(xcrun --find libtool)"

case " $* " in
  *" -static "*)
    exec "$libtool_path" -no_warning_for_no_symbols "$@"
    ;;
  *)
    exec "$libtool_path" "$@"
    ;;
esac
