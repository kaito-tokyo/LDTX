# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

PREFIX ?= /usr/local
DESTDIR ?=

.PHONY: build-ldtx install-ldtx

build-ldtx:
	swift build -c release --product ldtx

install-ldtx: build-ldtx
	install -d "$(DESTDIR)$(PREFIX)/bin"
	install -m 755 "$$(swift build -c release --show-bin-path)/ldtx" "$(DESTDIR)$(PREFIX)/bin/ldtx"
