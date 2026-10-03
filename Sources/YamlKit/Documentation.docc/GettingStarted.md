# Getting Started with YamlKit

Decode and encode Swift types, work with untyped YAML documents, and control the
generated output.

## Decoding

Create a ``YAMLDecoder`` and decode any `Decodable` type from a `String` or `Data`.
The character encoding of `Data` (UTF-8, UTF-16, or UTF-32) is detected automatically.

```swift
struct Config: Decodable {
  var name: String
  var retries: Int
  var timeout: Double?
  var hosts: [String]
}

let config = try YAMLDecoder().decode(Config.self, from: """
  name: backend
  retries: 3
  hosts:
    - alpha.example.com
    - beta.example.com
  """)
```

Plain scalars are interpreted using the YAML 1.2 core schema: `3` is an integer, `true`
a boolean, `~`, `null`, or an empty value is null. Quoted scalars are always strings.
A `String` property accepts any non-null scalar, so `version: 1.10` decodes as `"1.10"`.

Streams with several documents can be decoded with
``YAMLDecoder/decodeAll(_:from:)-(_,String)``:

```swift
let manifests = try YAMLDecoder().decodeAll(Manifest.self, from: text)
```

### Decoding Strategies

Like `JSONDecoder`, the decoder supports strategies for dates, binary data, and keys:

```swift
let decoder = YAMLDecoder()
decoder.keyDecodingStrategy = .convertFromSnakeCase   // max_retries → maxRetries
decoder.dateDecodingStrategy = .timestamp             // 2001-12-14t21:59:43.10-05:00
decoder.dataDecodingStrategy = .base64                // !!binary R0lGODlhDAAMAIQAAP
```

YAML 1.1 merge keys (`<<: *defaults`), which are popular in configuration files, can be
enabled via the parse options:

```swift
decoder.parseOptions.resolvesMergeKeys = true
```

### Errors

Decoding errors are reported as `DecodingError` values whose context contains the coding
path and, where available, the line and column of the offending node. Syntax errors are
reported as `DecodingError.dataCorrupted` with an underlying ``YAMLError``.

## Encoding

``YAMLEncoder`` produces block-style YAML that preserves the order in which properties
are encoded:

```swift
let encoder = YAMLEncoder()
encoder.outputFormatting = [.sortedKeys]
encoder.keyEncodingStrategy = .convertToSnakeCase
let text = try encoder.encodeToString(config)
```

Strings are quoted only where necessary: values such as `"true"`, `"null"`, or `"1.0"`
are quoted so that they are read back as strings, and multi-line strings are written as
literal block scalars.

## Working with Nodes

``YAML/parse(_:options:)-(String,_)`` composes a document into a ``YAMLNode`` tree,
which can be inspected, modified, and serialized again:

```swift
let root = try YAML.parse("servers: [alpha, beta]")
print(root?["servers"]?[1]?.string ?? "")   // beta

let document: YAMLNode = ["name": "YamlKit", "tags": ["swift", "yaml"]]
print(try YAML.serialize(document))
```

## Working with Events

For streaming use cases, ``YAMLParser`` produces ``YAMLEvent`` values one at a time,
and ``YAMLEmitter`` turns events back into text:

```swift
var parser = try YAMLParser(string: text)
while let event = try parser.next() {
  print(event.kind)
}
```
