#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0
#
# /// script
# requires-python = ">=3.10"
# dependencies = ["protobuf==7.36.2", "Jinja2==3.1.6", "grpcio-tools==1.85.0"]
# ///

import argparse
import itertools
import subprocess
import tempfile
from pathlib import Path
from google.protobuf import descriptor_pb2 as pb
from grpc_tools import protoc
from jinja2 import Environment, FileSystemLoader, StrictUndefined

ROOT = Path(__file__).resolve().parents[4]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--descriptor', type=Path)
parser.add_argument('--check', action='store_true')
args = parser.parse_args()
BASE = ROOT / 'Packages/LDTXCorelibs/Sources'
OUT = BASE / 'LDTXMessages/Messages/generated'
F = pb.FieldDescriptorProto
if args.descriptor:
    descriptor_data = args.descriptor.read_bytes()
else:
    with tempfile.TemporaryDirectory() as temporary_directory:
        descriptor_path = Path(temporary_directory) / 'schemas.pb'
        proto_directory = ROOT / 'Protos'
        status = protoc.main([
            'protoc', f'-I{proto_directory}', '--include_imports',
            '--include_source_info', f'--descriptor_set_out={descriptor_path}',
            *(str(path) for path in sorted(proto_directory.glob('*.proto'))),
        ])
        if status:
            parser.error(f'grpc_tools.protoc failed with exit status {status}')
        descriptor_data = descriptor_path.read_bytes()
descriptor_set = pb.FileDescriptorSet.FromString(descriptor_data)
files = sorted(descriptor_set.file, key=lambda file: file.name)
expected = {path.name for path in (ROOT / 'Protos').glob('*.proto')}
if {file.name for file in files} != expected or len(files) != len(expected):
    parser.error('Descriptor must contain exactly Protos/*.proto, with imports included')
if any(file.syntax != 'editions' or file.edition != pb.EDITION_2024 for file in files):
    parser.error('Only Edition 2024 schemas are supported')

def validate_features(options):
    features = options.features
    if features.HasField('field_presence') and features.field_presence != pb.FeatureSet.EXPLICIT:
        raise ValueError('Only explicit field presence is supported')

for file in files:
    validate_features(file.options)

messages = {}
enums = {}
owners = {}

def collect(file, prefix, message):
    validate_features(message.options)
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
        validate_features(field.options)
        if field.HasField('default_value'):
            raise ValueError(f'Custom defaults are unsupported: {name}.{field.name}')
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

def map_default(field):
    if field.type == F.TYPE_MESSAGE: return base_type(field) + '()'
    if field.type == F.TYPE_ENUM: return base_type(field) + '()'
    if field.type == F.TYPE_STRING: return '""'
    if field.type == F.TYPE_BYTES: return 'Data()'
    if field.type == F.TYPE_BOOL: return 'false'
    return '0'

def ctype(field):
    if field.type in (F.TYPE_STRING, F.TYPE_BYTES): return 'UnsafeMutablePointer<pb_bytes_array_t>?'
    if field.type in (F.TYPE_MESSAGE, F.TYPE_ENUM): return cname(field.type_name)
    return base_type(field)

def field_model(field):
    result = {
        'name': camel(field.name), 'field': field.name, 'type': swift_type(field),
        'base_type': base_type(field), 'c_type': ctype(field),
        'value_kind': {F.TYPE_MESSAGE: 'message', F.TYPE_ENUM: 'enum',
                       F.TYPE_STRING: 'string', F.TYPE_BYTES: 'bytes'}.get(field.type, 'scalar'),
        'kind': 'optional',
        'suffix': (' = [:]' if ismap(field) else ' = []')
                  if field.label == F.LABEL_REPEATED else '?'}
    if ismap(field):
        key, value = messages[field.type_name].field
        result.update(kind='map', less='{ !$0 && $1 }' if key.type == F.TYPE_BOOL else '(<)')
    elif field.label == F.LABEL_REPEATED:
        result['kind'] = 'repeated'
    elif field.type in (F.TYPE_STRING, F.TYPE_BYTES):
        result['kind'] = 'pointer'
    return result


def enum_model(full, enum):
    return {'name': typename(full),
            'cases': [{'name': name, 'number': value.number}
                      for value, name in enum_cases(enum)]}


def message_model(full, message):
    fields = [field_model(field) for field in message.field if not field.HasField('oneof_index')]
    oneofs = []
    for index, oneof in enumerate(message.oneof_decl):
        cases = [dict(field_model(field), number=field.number)
                 for field in message.field
                 if field.HasField('oneof_index') and field.oneof_index == index]
        oneofs.append({'property': camel(oneof.name), 'name': camel(oneof.name, True),
                       'union': oneof.name, 'cases': cases})
    return {
        'name': typename(full), 'c_type': cname(full), 'oneofs': oneofs,
        'typealiases': [{'name': enum.name, 'type': typename(full + '.' + enum.name)}
                        for enum in message.enum_type],
        'fields': fields,
        'map_entry': message.options.map_entry,
        'defaults': [{'type': base_type(field), 'value': map_default(field)}
                     for field in message.field] if message.options.map_entry else []}


environment = Environment(
    loader=FileSystemLoader(Path(__file__).resolve().parent),
    undefined=StrictUndefined, autoescape=False,
    trim_blocks=True, lstrip_blocks=True, keep_trailing_newline=True)
template = environment.get_template('messages.swift.jinja')
outputs = {}
for file in files:
    rendered = template.render(
        enums=[enum_model(name, enum) for name, enum in enums.items()
               if owners[name] == file.name],
        messages=[message_model(name, message) for name, message in messages.items()
                  if owners[name] == file.name])
    outputs[OUT / f'{Path(file.name).stem}.pb.swift'] = subprocess.run(
        ['swift', 'format', 'format', '--configuration', str(ROOT / '.swift-format')],
        input=rendered, text=True, capture_output=True, check=True).stdout


# Prepare every output before modifying any files. Only generated Swift files
# are written; --check leaves the working tree untouched.
changed = [(path, text) for path,text in outputs.items() if not path.exists() or path.read_text() != text]
if args.check and changed:
    parser.exit(1, 'Generated sources differ:\n' + '\n'.join(str(path) for path,_ in changed) + '\n')
for path, text in changed:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
print(f'{len(messages)} message models, {len(enums)} enums; {len(changed)} changed files')
