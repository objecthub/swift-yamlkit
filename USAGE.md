# Using YamlKit

This guide walks through the main use cases of YamlKit with small, self-contained examples.
All examples assume `import YamlKit` (and `import Foundation` where `Data` or `Date` is used).

YamlKit offers three levels of abstraction. Pick the highest one that fits your task:

| Level | API | Use it to … |
|---|---|---|
| Swift types | `YAMLDecoder`, `YAMLEncoder` | read and write configuration files and data as `Codable` types |
| Nodes | `YAML.parse`, `YAML.serialize`, `YAMLNode` | inspect, transform, or generate documents without a fixed schema |
| Events | `YAMLParser`, `YAMLEmitter`, `YAMLEvent` | stream large documents or control the presentation in detail |

---

## 1. Decoding YAML into Swift types

`YAMLDecoder` works like `JSONDecoder`: declare `Decodable` types that mirror the document and
call `decode(_:from:)` with a `String` or `Data`.

```swift
struct Deployment: Codable {
  var name: String
  var replicas: Int
  var image: String
  var ports: [Int]
  var labels: [String: String]
  var debug: Bool?
}

let yaml = """
  name: web
  replicas: 3
  image: nginx:1.27
  ports: [80, 443]
  labels:
    tier: frontend
    team: platform
  """

let deployment = try YAMLDecoder().decode(Deployment.self, from: yaml)
print(deployment.ports)   // [80, 443]
print(deployment.debug)   // nil
```

How scalars are interpreted (YAML 1.2 core schema):

- `3`, `0x1F`, `0o17` are integers; `2.5`, `1e3`, `.inf`, `.nan` are floating-point numbers
- `true`/`True`/`TRUE` and `false`/… are booleans
- `null`, `~`, and empty values are null and decode as `nil` for optionals
- quoted scalars (`"3"`, `'true'`) are always strings
- a `String` property accepts any non-null scalar, so `version: 1.10` decodes as `"1.10"`

`Data` input may be UTF-8, UTF-16, or UTF-32; the encoding is detected automatically:

```swift
let data = try Data(contentsOf: URL(fileURLWithPath: "deployment.yaml"))
let fromFile = try YAMLDecoder().decode(Deployment.self, from: data)
```

### Multiple documents

A YAML stream can contain several documents separated by `---`. Use `decodeAll(_:from:)` to
decode each of them; `decode(_:from:)` expects exactly one document.

```swift
let stream = """
  name: web
  replicas: 3
  ---
  name: worker
  replicas: 1
  """

struct Item: Decodable {
  var name: String
  var replicas: Int
}

let items = try YAMLDecoder().decodeAll(Item.self, from: stream)
print(items.map(\.name))   // ["web", "worker"]
```

### Decoding strategies

Strategies adapt the decoder to the conventions of a document:

```swift
struct Job: Decodable {
  var runsOn: String
  var timeoutMinutes: Int
  var startedAt: Date
  var payload: Data
}

let decoder = YAMLDecoder()
decoder.keyDecodingStrategy = .convertFromKebabCase   // runs-on → runsOn
decoder.dateDecodingStrategy = .timestamp             // the default: YAML timestamps
decoder.dataDecodingStrategy = .base64                // the default: !!binary or base64 text

let job = try decoder.decode(Job.self, from: """
  runs-on: macos-latest
  timeout-minutes: 30
  started-at: 2026-10-03 17:45:00 +02:00
  payload: !!binary aGVsbG8=
  """)
print(String(decoding: job.payload, as: UTF8.self))   // hello
```

| Strategy | Options |
|---|---|
| `keyDecodingStrategy` | `.useDefaultKeys`, `.convertFromSnakeCase`, `.convertFromKebabCase`, `.custom(_)` |
| `dateDecodingStrategy` | `.timestamp`, `.iso8601`, `.secondsSince1970`, `.millisecondsSince1970`, `.formatted(_)`, `.deferredToDate`, `.custom(_)` |
| `dataDecodingStrategy` | `.base64`, `.deferredToData`, `.custom(_)` |

Values can be passed to custom `init(from:)` implementations through `decoder.userInfo`.

### Anchors, aliases, and merge keys

Aliases (`*name`) are resolved automatically. YAML 1.1 merge keys (`<<`), common in
configuration files such as Docker Compose files, must be enabled explicitly:

```swift
struct Service: Decodable {
  var image: String
  var restart: String
  var replicas: Int
}

let compose = """
  defaults: &defaults
    image: app:latest
    restart: always
    replicas: 1
  api:
    <<: *defaults
    replicas: 4
  """

let decoder = YAMLDecoder()
decoder.parseOptions.resolvesMergeKeys = true
let services = try decoder.decode([String: Service].self, from: compose)
print(services["api"]!.replicas, services["api"]!.restart)   // 4 always
```

### Handling errors

Problems with the data are reported as `DecodingError` values. Their context contains the coding
path and the location in the document:

```swift
do {
  _ = try YAMLDecoder().decode(Deployment.self, from: """
    name: web
    replicas: three
    image: nginx
    ports: []
    labels: {}
    """)
} catch DecodingError.typeMismatch(let type, let context) {
  print(type, context.codingPath.map(\.stringValue))   // Int ["replicas"]
  print(context.debugDescription)
  // Expected to decode Int but found a scalar of type !!str instead (line 2, column 11).
}
```

Syntax errors are reported as `DecodingError.dataCorrupted` whose `underlyingError` is a
`YAMLError` with the line and column of the problem:

```swift
do {
  _ = try YAMLDecoder().decode([String: Int].self, from: "a: [1, 2")
} catch DecodingError.dataCorrupted(let context) {
  if let error = context.underlyingError as? YAMLError {
    print(error.kind, error.mark!)   // scanner line 2, column 1
  }
}
```

---

## 2. Encoding Swift values as YAML

`YAMLEncoder` turns `Encodable` values into block-style YAML. Keys are written in the order in
which they are encoded, strings are quoted only where necessary, and multi-line strings become
literal block scalars.

```swift
struct Pipeline: Codable {
  var name: String
  var version: String
  var steps: [Step]
}

struct Step: Codable {
  var name: String
  var script: String
  var retries: Int?
}

let pipeline = Pipeline(name: "build", version: "1.0", steps: [
  Step(name: "compile", script: "swift build\nswift test\n", retries: 2),
  Step(name: "archive", script: "zip -r out.zip .build", retries: nil)
])

let yaml = try YAMLEncoder().encodeToString(pipeline)
print(yaml)
```

```yaml
name: build
version: "1.0"
steps:
  - name: compile
    script: |
      swift build
      swift test
    retries: 2
  - name: archive
    script: zip -r out.zip .build
```

Note how `"1.0"` is quoted: written plain, it would be read back as a number. Optional
properties that are `nil` are omitted.

Use `encode(_:)` to obtain UTF-8 `Data`, `encodeAll(_:)`/`encodeAllToString(_:)` to write
several values as a multi-document stream, and `encodeToNode(_:)` to obtain a `YAMLNode`.

### Formatting and strategies

```swift
let encoder = YAMLEncoder()
encoder.outputFormatting = [.sortedKeys, .explicitDocumentStart]
encoder.indentation = 4
encoder.keyEncodingStrategy = .convertToSnakeCase
encoder.dateEncodingStrategy = .timestamp   // the default: ISO 8601 in UTC

struct Release: Encodable {
  var releaseName: String
  var publishedAt: Date
  var supportedPlatforms: [String]
}

print(try encoder.encodeToString(Release(releaseName: "1.0",
                                         publishedAt: Date(timeIntervalSince1970: 0),
                                         supportedPlatforms: ["macOS", "iOS"])))
```

```yaml
---
published_at: 1970-01-01T00:00:00Z
release_name: "1.0"
supported_platforms:
    - macOS
    - iOS
```

| `outputFormatting` option | Effect |
|---|---|
| `.sortedKeys` | sort mapping keys instead of keeping the encoding order |
| `.explicitDocumentStart` | start every document with `---` |
| `.indentlessSequences` | write sequences in mappings without extra indentation (`key:\n- a`) |
| `.flowStyle` | write all collections in flow style (`{a: [1, 2]}`) |
| `.escapeNonASCII` | escape non-ASCII characters in double-quoted strings |

`lineWidth` (default 80) controls when long strings are folded across lines.

---

## 3. Working with nodes

When the structure of a document is not known in advance, or a document should be modified
without losing information, work with `YAMLNode` trees.

### Parsing and navigating

`YAML.parse(_:)` returns the root node of a single-document stream (or `nil` for an empty
stream); `YAML.parseAll(_:)` returns all documents.

```swift
let root = try YAML.parse("""
  server:
    host: example.com
    ports: [80, 443]
    tls: true
  """)!

print(root["server"]?["host"]?.string)       // Optional("example.com")
print(root["server"]?["ports"]?[1]?.int)     // Optional(443)
print(root["server"]?["tls"]?.bool)          // Optional(true)
print(root["server"]?["missing"] == nil)     // true
```

A node is an enum with three cases. Every node has a resolved `tag`; scalars also keep their
source text, style, and location:

```swift
switch root["server"]! {
  case .mapping(let mapping):
    for entry in mapping.entries {
      print(entry.key.string!, entry.value.tag)
    }
    // host !!str
    // ports !!seq
    // tls !!bool
  case .sequence(let sequence):
    print(sequence.count)
  case .scalar(let scalar):
    print(scalar.value, scalar.mark!)
}
```

Accessors: `string`, `int`, `double`, `bool`, `isNull`, `array`, `scalar`, `sequence`,
`mapping`, `tag`, `anchor`, `mark`, plus subscripts by index, string key, and node key.

### Building and modifying

Nodes can be written as literals. Collections are value types and can be modified and put back:

```swift
var document: YAMLNode = [
  "name": "YamlKit",
  "stars": 42,
  "topics": ["swift", "yaml"],
  "license": nil
]

if case .mapping(var mapping) = document {
  mapping["stars"] = 43
  mapping["license"] = "Apache-2.0"
  document = .mapping(mapping)
}

print(try YAML.serialize(document))
```

```yaml
name: YamlKit
stars: 43
topics:
  - swift
  - yaml
license: Apache-2.0
```

To control presentation, set styles and tags explicitly:

```swift
let styled: YAMLNode = [
  "quoted": .scalar(YAMLNode.Scalar("text", style: .doubleQuoted)),
  "inline": .sequence(YAMLNode.Sequence([1, 2, 3], style: .flow)),
  "custom": .scalar(YAMLNode.Scalar("#ff8800", tag: YAMLTag("!color")))
]
print(try YAML.serialize(styled))
// quoted: "text"
// inline: [1, 2, 3]
// custom: !color '#ff8800'
```

Nodes compare by content: mapping order, styles, and anchors are ignored, and different
notations of the same value are equal (`~` and `null`, `0x10` and `16`).

### Converting between nodes and Swift types

`YAMLDecoder` and `YAMLEncoder` also accept and produce nodes, which is handy for documents that
are partly typed:

```swift
let config = try YAML.parse("""
  kind: Deployment
  spec:
    name: web
    replicas: 2
    image: nginx
    ports: [80]
    labels: {}
  """)!

if config["kind"]?.string == "Deployment", let spec = config["spec"] {
  let deployment = try YAMLDecoder().decode(Deployment.self, from: spec)
  let node = try YAMLEncoder().encodeToNode(deployment)
  print(node["replicas"]?.int)   // Optional(2)
}
```

---

## 4. Schemas and parse options

A schema decides how untagged plain scalars are interpreted. YamlKit includes the three
schemas of the YAML 1.2 specification:

```swift
let text = "[yes, null, 012, 1.5]"
print(try YAML.parse(text)!.array!.map(\.tag))
// [!!str, !!null, !!int, !!float]       core schema (default)
print(try YAML.parse(text, options: .init(schema: .json))!.array!.map(\.tag))
// [!!str, !!null, !!str, !!float]       JSON schema
print(try YAML.parse(text, options: .init(schema: .failsafe))!.array!.map(\.tag))
// [!!str, !!str, !!str, !!str]          failsafe schema
```

Custom schemas implement a single method. For example, to accept the YAML 1.1 booleans
`yes`/`no`/`on`/`off` found in older files:

```swift
struct LegacyBoolSchema: YAMLSchema {
  func tag(forPlainScalar value: String) -> YAMLTag {
    switch value.lowercased() {
      case "yes", "no", "on", "off":
        return .bool
      default:
        return CoreSchema().tag(forPlainScalar: value)
    }
  }
}

let decoder = YAMLDecoder()
decoder.parseOptions.schema = LegacyBoolSchema()
let flags = try decoder.decode([String: Bool].self, from: "enabled: yes\nverbose: off")
print(flags["enabled"]!, flags["verbose"]!)   // true false
```

`YAML.ParseOptions` (also available as `YAMLDecoder.parseOptions`) further controls:

| Option | Default | Meaning |
|---|---|---|
| `allowsDuplicateKeys` | `false` | accept mappings with repeated keys instead of failing |
| `resolvesMergeKeys` | `false` | expand `<<` merge keys |
| `maximumAliasExpansion` | 1,000,000 | maximum number of nodes copied by aliases ("billion laughs" protection) |
| `maximumDepth` | 512 | maximum nesting depth of collections |

---

## 5. Streaming with events

For very large inputs, or tools that must preserve presentation details such as styles and
document markers, process the event stream directly.

### Reading events

`YAMLParser` is a pull parser: each call to `next()` returns the next event, or `nil` at the end
of the stream. Memory use does not depend on the size of the document tree.

```swift
var parser = try YAMLParser(string: """
  - id: 1
    name: first
  - id: 2
    name: second
  """)

var depth = 0
var names: [String] = []
var expectName = false
while let event = try parser.next() {
  switch event.kind {
    case .mappingStart, .sequenceStart:
      depth += 1
    case .mappingEnd, .sequenceEnd:
      depth -= 1
    case .scalar(let value, _, _, _):
      if expectName {
        names.append(value)
      }
      expectName = depth == 2 && value == "name"
    default:
      break
  }
}
print(names)   // ["first", "second"]
```

(For simplicity, this example treats every scalar `name` at depth 2 as a key.)
`YAML.parseEvents(_:)` returns all events of a stream at once. Every event has `start` and
`end` marks with line and column information.

### Writing events

`YAMLEmitter` turns events into text. Requested styles are honored where the content allows it:

```swift
var emitter = YAMLEmitter(options: .init(indentation: 2))
try emitter.emit(contentsOf: [
  YAMLEvent(.streamStart),
  YAMLEvent(.documentStart(version: nil, tagDirectives: [], isImplicit: false)),
  YAMLEvent(.mappingStart(style: .block, tag: nil, anchor: nil)),
  .scalar("title"), .scalar("Release notes", style: .doubleQuoted),
  .scalar("body"), .scalar("Line one\nLine two\n", style: .literal),
  .scalar("tags"),
  YAMLEvent(.sequenceStart(style: .flow, tag: nil, anchor: nil)),
  .scalar("swift"), .scalar("yaml"),
  YAMLEvent(.sequenceEnd),
  YAMLEvent(.mappingEnd),
  YAMLEvent(.documentEnd(isImplicit: true)),
  YAMLEvent(.streamEnd)
])
print(emitter.output)
```

```yaml
---
title: "Release notes"
body: |
  Line one
  Line two
tags: [swift, yaml]
```

Parsing and re-emitting events reformats a document while keeping its scalar styles, tags,
anchors, and flow/block structure (comments are not part of the YAML data model and are
dropped):

```swift
let reformatted = try YAML.emit(try YAML.parseEvents("{a: 1,   b: [x,y]}"))
print(reformatted)   // {a: 1, b: [x, y]}
```

---

## 6. Practical notes

- **Thread safety.** `YAMLDecoder` and `YAMLEncoder` are `Sendable`; their configuration is
  protected by a lock, so a single instance can be shared between tasks. Nodes, events, schemas,
  and options are value types and `Sendable`.
- **Combine.** `YAMLDecoder` conforms to `TopLevelDecoder` and `YAMLEncoder` to
  `TopLevelEncoder`, so they can be used with `.decode(type:decoder:)` and `.encode(encoder:)`.
- **Untrusted input.** The default limits on nesting depth and alias expansion protect against
  malicious documents. Lower them further via `YAML.ParseOptions` if needed.
- **Name clash with Swift Testing.** YamlKit's tag type is called `YAMLTag` to avoid a conflict
  with `Testing.Tag`.
- **Errors.** All low-level APIs throw `YAMLError`, which has a `kind` (`.reader`, `.scanner`,
  `.parser`, `.composer`, `.emitter`, `.limitExceeded`), a `message`, and a `mark`.
