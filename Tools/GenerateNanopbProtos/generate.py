#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0
# /// script
# requires-python = ">=3.10"
# dependencies = ["protobuf==7.36.2"]
# ///
"""Run official nanopb C generation and generate Swift adapters from a descriptor.

Run protoc externally. Normal application builds do not run this tool.
"""
import argparse
import itertools
import os
from pathlib import Path
import shlex
import subprocess
import sys
from google.protobuf import descriptor_pb2 as pb
from google.protobuf import text_encoding
from google.protobuf.compiler import plugin_pb2

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--descriptor', required=True, type=Path)
parser.add_argument('--nanopb-root', type=Path,
                    default=Path(__file__).resolve().parents[2] / 'Vendors/nanopb')
parser.add_argument('--check', action='store_true')
args = parser.parse_args()
ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / 'Packages/LDTXCorelibs/LDTXProtos'
OUT = BASE / 'Messages'
COUT = BASE / 'NanopbMessages'
F = pb.FieldDescriptorProto
descriptor_set = pb.FileDescriptorSet.FromString(args.descriptor.read_bytes())
files = sorted(descriptor_set.file, key=lambda file: file.name)
expected = {path.name for path in (ROOT / 'Protos').glob('*.proto')}
if {file.name for file in files} != expected or len(files) != len(expected):
    parser.error('Descriptor must contain exactly Protos/*.proto, with imports included')
if any(file.syntax != 'editions' or file.edition != pb.EDITION_2024 for file in files):
    parser.error('Only Edition 2024 schemas are supported')

messages = {}
enums = {}
owners = {}

def collect(file, prefix, message):
    name = prefix + '.' + message.name
    if name in messages:
        raise ValueError(f'Duplicate message: {name}')
    messages[name] = message
    owners[name] = file.name
    for nested in message.nested_type:
        collect(file, name, nested)
    for enum in message.enum_type:
        enums[name + '.' + enum.name] = enum
        owners[name + '.' + enum.name] = file.name

for file in files:
    for message in file.message_type:
        collect(file, '.' + file.package, message)
    for enum in file.enum_type:
        enums['.' + file.package + '.' + enum.name] = enum
        owners['.' + file.package + '.' + enum.name] = file.name

for name, message in messages.items():
    if not message.field or message.extension:
        raise ValueError(f'Empty messages and extensions are unsupported: {name}')
    for field in message.field:
        if field.type == F.TYPE_GROUP or field.label == F.LABEL_REQUIRED or field.proto3_optional:
            raise ValueError(f'Unsupported field: {name}.{field.name}')
        if field.type == F.TYPE_MESSAGE and field.type_name not in messages:
            raise ValueError(f'Missing message: {field.type_name}')
        if field.type == F.TYPE_ENUM and field.type_name not in enums:
            raise ValueError(f'Missing enum: {field.type_name}')

def camel(name, upper=False):
    parts = name.split('_')
    result = parts[0].capitalize() if upper else parts[0]
    for part in parts[1:]:
        result += {'id': 'ID', 'url': 'URL'}.get(part, part[:1].upper() + part[1:])
    return result

def typename(name):
    return '_'.join(part[:1].upper() + part[1:] for part in name.lstrip('.').split('.'))

def cname(name):
    return name.lstrip('.').replace('.', '_')

def literal(value):
    escapes = {'\\': '\\\\', '"': '\\"', '\n': '\\n', '\r': '\\r', '\t': '\\t'}
    return '"' + ''.join(escapes.get(char, f'\\u{{{ord(char):x}}}' if ord(char) < 32 else char)
                         for char in value) + '"'

SCALAR = {F.TYPE_DOUBLE:'Double', F.TYPE_FLOAT:'Float', F.TYPE_INT64:'Int64',
 F.TYPE_UINT64:'UInt64', F.TYPE_INT32:'Int32', F.TYPE_FIXED64:'UInt64',
 F.TYPE_FIXED32:'UInt32', F.TYPE_BOOL:'Bool', F.TYPE_STRING:'String',
 F.TYPE_BYTES:'Data', F.TYPE_UINT32:'UInt32', F.TYPE_SFIXED32:'Int32',
 F.TYPE_SFIXED64:'Int64', F.TYPE_SINT32:'Int32', F.TYPE_SINT64:'Int64'}

def ismap(field):
    return field.type == F.TYPE_MESSAGE and messages[field.type_name].options.map_entry

def base_type(field):
    return SCALAR.get(field.type, typename(field.type_name))

def swift_type(field):
    if ismap(field):
        key, value = messages[field.type_name].field
        return f'[{base_type(key)}: {base_type(value)}]'
    base = base_type(field)
    return f'[{base}]' if field.label == F.LABEL_REPEATED else base

def enum_cases(enum):
    prefix = ''.join(chars[0] for chars in itertools.takewhile(
        lambda chars: len(set(chars)) == 1, zip(*(v.name for v in enum.value))))
    prefix = prefix[:prefix.rfind('_')+1]
    return [(v, camel(v.name[len(prefix):].lower())) for v in enum.value]

def default(field):
    value = field.default_value
    if field.type == F.TYPE_MESSAGE: return base_type(field) + '()'
    if field.type == F.TYPE_ENUM:
        return '.' + next(case for v,case in enum_cases(enums[field.type_name])
                           if v.name == (value or enums[field.type_name].value[0].name))
    if field.type == F.TYPE_STRING: return literal(value)
    if field.type == F.TYPE_BYTES: return 'Data(' + str(list(text_encoding.CUnescape(value))) + ')'
    if field.type == F.TYPE_BOOL: return value or 'false'
    return {'inf':'.infinity', '-inf':'-.infinity', 'nan':'.nan'}.get(value, value or '0')

def read(field, merging=None):
    kind = field.type
    if kind == F.TYPE_MESSAGE:
        return f'try reader.message(merging: {merging or base_type(field)+"()"})'
    if kind == F.TYPE_STRING: return 'try reader.string()'
    if kind == F.TYPE_BYTES: return 'try reader.bytes()'
    if kind == F.TYPE_FLOAT: return 'Float(bitPattern: try reader.fixed32())'
    if kind == F.TYPE_DOUBLE: return 'Double(bitPattern: try reader.fixed64())'
    if kind == F.TYPE_FIXED32: return 'try reader.fixed32()'
    if kind == F.TYPE_FIXED64: return 'try reader.fixed64()'
    if kind == F.TYPE_SFIXED32: return 'Int32(bitPattern: try reader.fixed32())'
    if kind == F.TYPE_SFIXED64: return 'Int64(bitPattern: try reader.fixed64())'
    if kind == F.TYPE_BOOL: return 'try reader.bool()'
    if kind == F.TYPE_ENUM: return f'{base_type(field)}(rawValue: Int(Int32(bitPattern: try reader.varint32())))!'
    if kind == F.TYPE_UINT32: return 'try reader.varint32()'
    if kind == F.TYPE_INT32: return 'Int32(bitPattern: try reader.varint32())'
    if kind in (F.TYPE_SINT32,F.TYPE_SINT64):
        return f'{base_type(field)}(truncatingIfNeeded: try reader.svarint())'
    return f'{base_type(field)}(truncatingIfNeeded: try reader.varint())'

def write(field, value):
    n, k = field.number, field.type
    if k == F.TYPE_MESSAGE: return f'try writer.message({n}, {value})'
    if k == F.TYPE_STRING: return f'try writer.string({n}, {value})'
    if k == F.TYPE_BYTES: return f'try writer.bytes({n}, {value})'
    if k == F.TYPE_FLOAT: return f'try writer.fixed32({n}, {value}.bitPattern)'
    if k == F.TYPE_DOUBLE: return f'try writer.fixed64({n}, {value}.bitPattern)'
    if k in (F.TYPE_SFIXED32,F.TYPE_SFIXED64):
        width = 32 if k == F.TYPE_SFIXED32 else 64
        return f'try writer.fixed{width}({n}, UInt{width}(bitPattern: {value}))'
    if k in (F.TYPE_FIXED32,F.TYPE_FIXED64):
        return f'try writer.fixed{32 if k==F.TYPE_FIXED32 else 64}({n}, {value})'
    if k in (F.TYPE_SINT32,F.TYPE_SINT64): return f'try writer.svarint({n}, Int64({value}))'
    if k in (F.TYPE_INT32,F.TYPE_INT64): expr=f'UInt64(bitPattern: Int64({value}))'
    elif k == F.TYPE_ENUM: expr=f'UInt64(bitPattern: Int64({value}.rawValue))'
    elif k == F.TYPE_BOOL: expr=f'{value} ? 1 : 0'
    else: expr=f'UInt64({value})'
    return f'try writer.varint({n}, {expr})'

def json_read(field, expr):
    k = field.type
    if k == F.TYPE_MESSAGE: return f'try {base_type(field)}.fromJSONObject({expr})'
    if k == F.TYPE_ENUM: return f'try {base_type(field)}.fromJSON({expr})'
    if k == F.TYPE_BYTES: return f'try NanopbJSON.data({expr})'
    if k == F.TYPE_STRING: return f'try NanopbJSON.string({expr})'
    if k == F.TYPE_BOOL: return f'try NanopbJSON.bool({expr})'
    if k in (F.TYPE_FLOAT,F.TYPE_DOUBLE): return f'try NanopbJSON.floating({expr}, as: {base_type(field)}.self)'
    return f'try NanopbJSON.integer({expr}, as: {base_type(field)}.self)'

def json_write(field, expr):
    if field.type == F.TYPE_MESSAGE: return expr+'.jsonObject'
    if field.type == F.TYPE_ENUM: return expr+'.jsonValue'
    if field.type == F.TYPE_BYTES: return expr+'.base64EncodedString()'
    if field.type in (F.TYPE_INT64,F.TYPE_UINT64,F.TYPE_SFIXED64,F.TYPE_FIXED64,F.TYPE_SINT64): return 'String('+expr+')'
    if field.type in (F.TYPE_FLOAT,F.TYPE_DOUBLE): return 'NanopbJSON.floatingValue('+expr+')'
    return expr

def generate_enum(full, enum):
    cases = enum_cases(enum)
    lines = [f'public enum {typename(full)}: Hashable, Sendable, CaseIterable {{']
    lines += [f'  case {case}' for _,case in cases] + ['  case UNRECOGNIZED(Int)',
      f'  public init() {{ self = .{cases[0][1]} }}', '  public init?(rawValue: Int) {', '    switch rawValue {']
    lines += [f'    case {v.number}: self = .{case}' for v,case in cases]
    lines += ['    default: self = .UNRECOGNIZED(rawValue)', '    }', '  }', '  public var rawValue: Int {', '    switch self {']
    lines += [f'    case .{case}: return {v.number}' for v,case in cases]
    lines += ['    case .UNRECOGNIZED(let value): return value','    }','  }',
      f'  public static let allCases: [Self] = [{", ".join("."+c for _,c in cases)}]',
      '  public var jsonValue: Any {', '    switch self {']
    lines += [f'    case .{case}: return "{v.name}"' for v,case in cases]
    lines += ['    case .UNRECOGNIZED(let value): return value','    }','  }',
      '  public static func fromJSON(_ value: Any) throws -> Self {', '    if let name = value as? String {', '      switch name {']
    lines += [f'      case "{v.name}": return .{case}' for v,case in cases]
    lines += ['      default: break','      }','    }','    return Self(rawValue: try NanopbJSON.integer(value, as: Int.self))!', '  }','}']
    return lines

def generate_message(full, message):
    name = typename(full)
    lines = [f'public struct {name}: NanopbMessage {{', '  public init() {}']
    for enum in message.enum_type:
        lines += [f'  public typealias {enum.name} = {typename(full + "." + enum.name)}']
    for index, oneof in enumerate(message.oneof_decl):
        prop, en = camel(oneof.name), 'OneOf_' + camel(oneof.name,True)
        lines += [f'  public var {prop}: {en}?',f'  public enum {en}: Hashable, Sendable {{']
        fields = [f for f in message.field if f.HasField('oneof_index') and f.oneof_index == index]
        lines += [f'    case {camel(f.name)}({base_type(f)})' for f in fields] + ['  }']
    for f in message.field:
        prop, cap, ty = camel(f.name), camel(f.name,True), swift_type(f)
        if f.HasField('oneof_index'):
            one = camel(message.oneof_decl[f.oneof_index].name)
            lines += [f'  public var {prop}: {ty} {{', f'    get {{ if case .{prop}(let value)? = {one} {{ return value }}; return {default(f)} }}', f'    set {{ {one} = .{prop}(newValue) }}','  }']
        elif f.label == F.LABEL_REPEATED:
            lines += [f'  public var {prop}: {ty} = '+('[:]' if ismap(f) else '[]')]
        else:
            lines += [f'  private var _{prop}: {ty}?', f'  public var {prop}: {ty} {{',
              f'    get {{ _{prop} ?? {default(f)} }}',f'    set {{ _{prop} = newValue }}','  }',
              f'  public var has{cap}: Bool {{ _{prop} != nil }}',f'  public mutating func clear{cap}() {{ _{prop} = nil }}']
    cn = cname(full)
    lines += [f'  private static func makeCMessage(_ context: UnsafeMutableRawPointer) -> {cn} {{', f'    var message = {cn}()']
    lines += [f'    message.{f.name} = context' for f in message.field]
    lines += ['    return message', '  }',
      '  public mutating func decode(from reader: inout NanopbReader) throws {',
      f'    try reader.decodeMessage(into: &self, descriptor: {cn}_msg, make: Self.makeCMessage) {{ value, field, reader in',
      '      try value.decodeField(field, from: &reader)', '    }', '  }',
      '  private mutating func decodeField(_ field: UInt32, from reader: inout NanopbReader) throws {', '    switch field {']
    for f in message.field:
        prop=camel(f.name)
        lines += [f'    case {f.number}:']
        if ismap(f):
            lines += [f'      let entry: {base_type(f)} = try reader.message()', f'      {prop}[entry.key] = entry.value']
        elif f.label == F.LABEL_REPEATED:
            if f.type in (F.TYPE_MESSAGE,F.TYPE_STRING,F.TYPE_BYTES): lines += [f'      {prop}.append({read(f)})']
            else: lines += [f'      while reader.hasRemaining {{ {prop}.append({read(f)}) }}']
        else: lines += [f'      self.{prop} = {read(f,merging=prop if f.type==F.TYPE_MESSAGE else None)}']
    lines += ['    default: throw NanopbError.malformed', '    }', '  }',
      '  public func encode(to writer: inout NanopbWriter) throws { try encodeC(to: &writer, number: nil) }',
      '  public func encodeSubmessage(_ number: UInt32, to writer: inout NanopbWriter) throws { try encodeC(to: &writer, number: number) }',
      '  private func encodeC(to writer: inout NanopbWriter, number: UInt32?) throws {',
      f'    try writer.encodeMessage(self, descriptor: {cn}_msg, make: Self.makeCMessage, fieldNumber: number) {{ value, field, writer in',
      '      try value.encodeField(field, to: &writer)', '    }', '  }',
      '  private func encodeField(_ field: UInt32, to writer: inout NanopbWriter) throws {', '    switch field {']
    for f in message.field:
        prop=camel(f.name)
        lines += [f'    case {f.number}:']
        if ismap(f):
            key,val=messages[f.type_name].field
            order=f'{prop}.keys.sorted()' if key.type != F.TYPE_BOOL else f'{prop}.keys.sorted {{ !$0 && $1 }}'
            lines += [f'      for key in {order} {{', f'        var entry = {base_type(f)}()', '        entry.key = key',
                      f'        entry.value = {prop}[key]!', f'        try writer.message({f.number}, entry)', '      }']
        elif f.label == F.LABEL_REPEATED: lines += [f'      for value in {prop} {{ {write(f,"value")} }}']
        elif f.HasField('oneof_index'):
            one=camel(message.oneof_decl[f.oneof_index].name)
            lines += [f'      if case .{prop}(let value)? = {one} {{ {write(f,"value")} }}']
        else: lines += [f'      if let value = _{prop} {{ {write(f,"value")} }}']
    lines += ['    default: throw NanopbError.malformed', '    }', '  }',
              '  public var jsonObject: [String: Any] {','    var object: [String: Any] = [:]']
    for f in message.field:
        prop, js = camel(f.name), literal(f.json_name)
        if ismap(f):
            key,val=messages[f.type_name].field
            lines += [f'    if !{prop}.isEmpty {{ object[{js}] = Dictionary(uniqueKeysWithValues: {prop}.map {{ (String($0.key), {json_write(val,"$0.value")}) }}) }}']
        elif f.label == F.LABEL_REPEATED: lines += [f'    if !{prop}.isEmpty {{ object[{js}] = {prop}.map {{ {json_write(f,"$0")} }} }}']
        elif f.HasField('oneof_index'):
            one=camel(message.oneof_decl[f.oneof_index].name)
            lines += [f'    if case .{prop}(let value)? = {one} {{ object[{js}] = {json_write(f,"value")} }}']
        else: lines += [f'    if let value = _{prop} {{ object[{js}] = {json_write(f,"value")} }}']
    lines += ['    return object','  }','  public mutating func merge(jsonObject: [String: Any]) throws {',
      '    var seen: Set<String> = []', '    for (name, value) in jsonObject {','      if value is NSNull { continue }', '      switch name {']
    for f in message.field:
        prop=camel(f.name)
        keycases=', '.join(literal(k) for k in dict.fromkeys([f.json_name,f.name]))
        lines += [f'      case {keycases}:',f'        guard seen.insert("{prop}").inserted else {{ throw NanopbError.invalidJSON }}']
        if f.HasField('oneof_index'):
            one=camel(message.oneof_decl[f.oneof_index].name)
            lines += [f'        guard seen.insert("oneof:{one}").inserted else {{ throw NanopbError.invalidJSON }}']
        if ismap(f):
            key,val=messages[f.type_name].field
            keyread='try NanopbJSON.boolKey(key)' if key.type==F.TYPE_BOOL else json_read(key,'key')
            lines += ['        for (key, item) in try NanopbJSON.object(value) {', f'          {prop}[{keyread}] = {json_read(val,"item")}','        }']
        elif f.label == F.LABEL_REPEATED: lines += [f'        {prop} = try NanopbJSON.array(value).map {{ {json_read(f,"$0")} }}']
        else: lines += [f'        self.{prop} = {json_read(f,"value")}']
    return lines + ['      default: throw NanopbError.invalidJSON','      }','    }','  }','}']

PREAMBLE = ('/* Generated by Tools/GenerateNanopbProtos/generate.py. DO NOT EDIT.\n'
            ' * SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>\n'
            ' * SPDX-License-Identifier: Apache-2.0 */\n')
outputs = {}
# Invoke the official generator's standard protoc-plugin interface with the
# already compiled descriptors. Neither our wrapper nor the official generator
# may invoke protoc. Its nanopb_pb2 support module is prepared externally too.
nanopb_root = args.nanopb_root.resolve()
generator = nanopb_root / 'generator/nanopb_generator.py'
if not generator.is_file() or '#define NANOPB_VERSION "nanopb-0.4.9.2"' not in (nanopb_root / 'pb.h').read_text():
    parser.error('Initialize Vendors/nanopb at nanopb 0.4.9.2, or pass --nanopb-root CHECKOUT')
support = args.descriptor.resolve().parent
if not (support / 'nanopb_pb2.py').is_file():
    parser.error('Run protoc --python_out=DESCRIPTOR_DIRECTORY on nanopb generator/proto/nanopb.proto first')
request = plugin_pb2.CodeGeneratorRequest(
    file_to_generate=[file.name for file in files], proto_file=descriptor_set.file,
    parameter=shlex.join(['-s', 'type:FT_CALLBACK', '-s', 'no_unions:true',
                         '-s', 'callback_datatype:"void *"',
                         '-s', 'callback_function:"ldtx_nanopb_field_callback"']))
environment = dict(os.environ, NANOPB_PB2_NO_REBUILD='1', PYTHONDONTWRITEBYTECODE='1')
environment['PYTHONPATH'] = str(support) + os.pathsep + environment.get('PYTHONPATH', '')
result = subprocess.run([sys.executable, str(generator), '--protoc-plugin'],
                        input=request.SerializeToString(), stdout=subprocess.PIPE,
                        env=environment, check=True)
response = plugin_pb2.CodeGeneratorResponse.FromString(result.stdout)
if response.error:
    parser.error(response.error)
expected_c = {Path(file.name).stem + suffix for file in files for suffix in ('.pb.h', '.pb.c')}
if {file.name for file in response.file} != expected_c:
    parser.error('Unexpected output from the official nanopb generator')
for file in response.file:
    path = COUT / ('include' if file.name.endswith('.h') else '') / file.name
    outputs[path] = PREAMBLE + file.content.rstrip() + '\n'

for file in files:
    names = [name for name in messages if owners[name] == file.name]
    stem = Path(file.name).stem
    lines = ['// Generated by Tools/GenerateNanopbProtos/generate.py. DO NOT EDIT.',
      '// swift-format-ignore-file', '// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>',
      '// SPDX-License-Identifier: Apache-2.0', 'import Foundation', 'import LDTXNanopb',
      'internal import LDTXNanopbMessages', '']
    for name, enum in enums.items():
        if owners[name] == file.name: lines += generate_enum(name, enum) + ['']
    for name in names: lines += generate_message(name, messages[name]) + ['']
    outputs[OUT / f'{stem}.pb.swift'] = '\n'.join(lines)
outputs[COUT / 'StorageChecks.c'] = PREAMBLE + '#include "LDTXNanopbMessages.h"\n' + '\n'.join(
    f'_Static_assert(sizeof({cname(name)}) == {len(message.field)} * sizeof(void *),\n'
    f'               "{cname(name)} must only store callback pointers");' for name,message in messages.items()) + '\n'
outputs[COUT / 'include/LDTXNanopbMessages.h'] = PREAMBLE + '#pragma once\n' + '\n'.join(
    f'#include "{Path(file.name).stem}.pb.h"' for file in files) + '''
#include <LDTXNanopbSupport.h>
'''

# Prepare every output before modifying any files. Patch-based writes preserve
# handwritten extensions and allow the same output to be checked without writes.
changed = [(path, text) for path,text in outputs.items() if not path.exists() or path.read_text() != text]
if args.check and changed:
    parser.exit(1, 'Generated sources differ:\n' + '\n'.join(str(path) for path,_ in changed) + '\n')
if changed:
    patch = '*** Begin Patch\n'
    for path, text in changed:
        if path.exists():
            patch += f'*** Update File: {path}\n@@\n'
            patch += ''.join('-' + line + '\n' for line in path.read_text().splitlines())
        else: patch += f'*** Add File: {path}\n'
        patch += ''.join('+' + line + '\n' for line in text.splitlines())
    patch += '*** End Patch\n'
    subprocess.run(['apply_patch'], input=patch, text=True, check=True, stdout=subprocess.DEVNULL)
print(f'{len(messages)} message models, {len(enums)} enums; {len(changed)} changed files')
