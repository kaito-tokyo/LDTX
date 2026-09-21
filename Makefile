# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

PREFIX ?= /usr/local
DESTDIR ?=

.PHONY: build-ldtx install-ldtx

build-ldtx:
	xcodegen generate
	xcodebuild -project LDTX.xcodeproj -scheme LDTXHelperTool -configuration Release \
		-derivedDataPath .derivedData build

install-ldtx: build-ldtx
	install -d "$(DESTDIR)$(PREFIX)/bin"
	install -m 755 ".derivedData/Build/Products/Release/LDTXHelper" "$(DESTDIR)$(PREFIX)/bin/ldtx"
