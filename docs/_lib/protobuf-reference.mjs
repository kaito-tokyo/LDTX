// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

// Reads the descriptor wire format emitted by protoc. Unknown fields are skipped
// so new editions do not require a matching third-party descriptor library.
function varint(bytes, cursor) {
  let value = 0n;
  let shift = 0n;
  for (;;) {
    if (cursor.offset >= bytes.length || shift >= 70n) {
      throw new Error("Invalid descriptor varint");
    }
    const byte = bytes[cursor.offset++];
    value |= BigInt(byte & 127) << shift;
    if (byte < 128) return value;
    shift += 7n;
  }
}

function decode(bytes) {
  const result = new Map();
  const cursor = { offset: 0 };
  while (cursor.offset < bytes.length) {
    const tag = Number(varint(bytes, cursor));
    const number = tag >>> 3;
    const wire = tag & 7;
    let value;
    if (wire === 0) {
      value = varint(bytes, cursor);
    } else if (wire === 2) {
      const length = Number(varint(bytes, cursor));
      if (length > bytes.length - cursor.offset) {
        throw new Error("Truncated descriptor field");
      }
      value = bytes.subarray(cursor.offset, cursor.offset + length);
      cursor.offset += length;
    } else if (wire === 1 || wire === 5) {
      const length = wire === 1 ? 8 : 4;
      if (length > bytes.length - cursor.offset) {
        throw new Error("Truncated descriptor field");
      }
      cursor.offset += length;
      continue;
    } else {
      throw new Error(`Unsupported descriptor wire type: ${wire}`);
    }
    if (!result.has(number)) result.set(number, []);
    result.get(number).push(value);
  }
  return result;
}

const values = (message, number) => message.get(number) ?? [];
const text = (message, number) => values(message, number)[0]?.toString("utf8") ?? "";
const integer = (message, number) => Number(values(message, number)[0] ?? 0n);
const messages = (message, number) => values(message, number).map(decode);
const escape = (value) => String(value).replaceAll("&", "&amp;")
  .replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;");
const code = (value) => `<code>${escape(value)}</code>`;

function pathNumbers(location) {
  return values(location, 1).flatMap((value) => {
    if (typeof value === "bigint") return [Number(value)];
    const cursor = { offset: 0 };
    const result = [];
    while (cursor.offset < value.length) result.push(Number(varint(value, cursor)));
    return result;
  });
}

const scalarTypes = ["", "double", "float", "int64", "uint64", "int32",
  "fixed64", "fixed32", "bool", "string", "group", "message", "bytes",
  "uint32", "enum", "sfixed32", "sfixed64", "sint32", "sint64"];

export function renderProtobufReference(bytes) {
  const files = messages(decode(bytes), 1);
  const symbols = new Map();
  function register(message, prefix) {
    const name = `${prefix}.${text(message, 1)}`;
    symbols.set(name, message);
    for (const nested of messages(message, 3)) register(nested, name);
  }
  for (const file of files) {
    for (const message of messages(file, 4)) register(message, text(file, 2));
  }
  function type(field) {
    const name = text(field, 6).replace(/^\./, "");
    if (name) return `<a href="#${escape(name)}">${code(name.split(".").at(-1))}</a>`;
    return code(scalarTypes[integer(field, 5)]);
  }
  const sections = files.map((file) => {
    const comments = new Map();
    for (const info of messages(file, 9)) {
      for (const location of messages(info, 1)) {
        comments.set(pathNumbers(location).join(","),
          [text(location, 3), text(location, 4)].filter(Boolean).join("\n").trim());
      }
    }
    const description = (path) => comments.get(path.join(",")) ?? "";
    const paragraph = (path) => description(path) ? `<p>${escape(description(path))}</p>` : "";
    function enumHTML(enumeration, prefix, path) {
      const name = `${prefix}.${text(enumeration, 1)}`;
      const rows = messages(enumeration, 2).map((value, index) =>
        `<tr><td>${code(text(value, 1))}</td><td>${BigInt.asIntN(32, values(value, 2)[0] ?? 0n)}</td><td>${escape(description([...path, 2, index])) || "—"}</td></tr>`);
      return `<article><h3 id="${escape(name)}">${code(name.slice(text(file, 2).length + 1))}</h3>${paragraph(path)}
<table><thead><tr><th>Value</th><th>Number</th><th>Description</th></tr></thead><tbody>${rows.join("\n")}</tbody></table></article>`;
    }
    function messageHTML(message, prefix, path) {
      if (messages(message, 7).some((options) => integer(options, 7) === 1)) return "";
      const name = `${prefix}.${text(message, 1)}`;
      const oneofs = messages(message, 8);
      const rows = messages(message, 2).map((field, index) => {
        const referenced = symbols.get(text(field, 6).replace(/^\./, ""));
        const isMap = referenced && messages(referenced, 7).some((options) => integer(options, 7) === 1);
        const fieldType = isMap
          ? `${code("map<")}${messages(referenced, 2).map(type).join(code(", "))}${code(">")}`
          : type(field);
        const label = isMap ? "map" : field.has(9)
          ? `oneof ${code(text(oneofs[integer(field, 9)], 1))}`
          : integer(field, 4) === 3 ? "repeated" : "";
        return `<tr><td>${code(text(field, 1))}</td><td>${integer(field, 3)}</td><td>${fieldType}</td><td>${label}</td><td>${field.has(7) ? code(text(field, 7)) : "—"}</td><td>${escape(description([...path, 2, index])) || "—"}</td></tr>`;
      });
      return `<article><h3 id="${escape(name)}">${code(name.slice(text(file, 2).length + 1))}</h3>${paragraph(path)}
${rows.length ? `<table><thead><tr><th>Field</th><th>Number</th><th>Type</th><th>Label</th><th>Default</th><th>Description</th></tr></thead><tbody>${rows.join("\n")}</tbody></table>` : ""}</article>
${messages(message, 3).map((nested, index) => messageHTML(nested, name, [...path, 3, index])).join("\n")}
${messages(message, 4).map((enumeration, index) => enumHTML(enumeration, name, [...path, 4, index])).join("\n")}`;
    }
    return `<section><h2>${code(text(file, 1))}</h2><p>Package ${code(text(file, 2))}</p>
${messages(file, 4).map((message, index) => messageHTML(message, text(file, 2), [4, index])).join("\n")}
${messages(file, 5).map((enumeration, index) => enumHTML(enumeration, text(file, 2), [5, index])).join("\n")}</section>`;
  });
  return `<!doctype html>
<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>LDTX Workspace Protobuf Reference</title>
<style>
table { border-collapse: collapse; }
table, th, td { border: 1px solid; }
p, td { white-space: pre-wrap; }
</style>
</head>
<body>
<h1>LDTX Workspace Protobuf Reference</h1>
<p>Schema reference for the persisted Workspace format.</p>
${sections.join("\n")}
</body>
</html>
`;
}
