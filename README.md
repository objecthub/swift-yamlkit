# swift-yamlkit

YamlKit is a pure Swift implementation of [YAML 1.2.2](https://yaml.org/spec/1.2.2/) for
macOS and iOS. It provides `YAMLDecoder` and `YAMLEncoder`, which plug into Swift's
`Codable` framework just like `JSONDecoder` and `JSONEncoder`, as well as lower-level APIs
for working with YAML node trees and event streams.

- Complete YAML 1.2.2 parser that passes all 402 cases of the official
  [YAML test suite](https://github.com/yaml/yaml-test-suite)
- Emitter producing idiomatic block-style YAML, quoting strings only where necessary
- `Codable` support with date, data, and key strategies (including snake case and kebab case)
- Core, JSON, and failsafe schemas, plus support for custom schemas
- Anchors and aliases, multi-document streams, `%YAML`/`%TAG` directives, optional merge keys
- UTF-8, UTF-16, and UTF-32 input with automatic encoding detection
- Protection against malicious input ("billion laughs", excessive nesting)
- No dependencies; Swift 6 language mode with strict concurrency checking

## Requirements

- Swift 6.0 or later
- macOS 13 or later, iOS 16 or later

## Installation

Add YamlKit to the dependencies of your `Package.swift`:

```swift
dependencies: [
  .package(url: "https://github.com/objecthub/swift-yamlkit.git", from: "1.0.0")
],
targets: [
  .target(name: "MyTarget", dependencies: [
    .product(name: "YamlKit", package: "swift-yamlkit")
  ])
]
```

## Usage

### Decoding

```swift
import YamlKit

struct Service: Codable {
  var image: String
  var replicas: Int
  var ports: [Int]
  var environment: [String: String]
}

let yaml = """
  image: nginx:1.27
  replicas: 3
  ports: [80, 443]
  environment:
    TZ: Europe/Zurich
  """

let service = try YAMLDecoder().decode(Service.self, from: yaml)
```

Plain scalars are interpreted according to the YAML 1.2 core schema (`3` is an integer,
`true` a boolean, `~` is null, `"3"` is a string). Errors are reported as `DecodingError`
values whose context includes the coding path and the line and column of the problem.

### Encoding

```swift
let encoder = YAMLEncoder()
encoder.outputFormatting = [.sortedKeys]
print(try encoder.encodeToString(service))
```

```yaml
environment:
  TZ: Europe/Zurich
image: nginx:1.27
ports:
  - 80
  - 443
replicas: 3
```

### Strategies and Options

```swift
let decoder = YAMLDecoder()
decoder.keyDecodingStrategy = .convertFromKebabCase      // runs-on → runsOn
decoder.dateDecodingStrategy = .timestamp                // 2001-12-14t21:59:43.10-05:00
decoder.parseOptions.resolvesMergeKeys = true            // <<: *defaults

let encoder = YAMLEncoder()
encoder.keyEncodingStrategy = .convertToSnakeCase
encoder.outputFormatting = [.explicitDocumentStart, .indentlessSequences]
encoder.indentation = 4
```

Streams with multiple documents are supported via `decodeAll(_:from:)` and
`encodeAll(_:)`.

### Nodes

```swift
let root = try YAML.parse("""
  name: YamlKit
  tags: [swift, yaml]
  """)
print(root?["tags"]?[0]?.string ?? "")   // swift

let document: YAMLNode = ["name": "YamlKit", "version": 1, "tags": ["swift", "yaml"]]
print(try YAML.serialize(document))
```

### Events

```swift
var parser = try YAMLParser(string: "[a, b]")
while let event = try parser.next() {
  print(event.kind)
}

let text = try YAML.emit(try YAML.parseEvents("{a: 1}"))
```

## Architecture

YamlKit implements the processing model of chapter 3 of the specification as separate
layers:

```
               parse            compose             decode
 YAML text ──────────▶ events ──────────▶ nodes ──────────▶ Swift values
           ◀────────── events ◀────────── nodes ◀────────── Swift values
               emit           serialize             encode
```

| Directory                  | Contents                                                      |
|----------------------------|---------------------------------------------------------------|
| `Sources/YamlKit/Reader`   | Encoding detection and line break normalization               |
| `Sources/YamlKit/Scanner`  | Tokenizer: indentation, implicit keys, scalars, properties    |
| `Sources/YamlKit/Parser`   | `YAMLParser` and `YAMLEvent`                                  |
| `Sources/YamlKit/Node`     | `YAMLNode` and the composer (tag resolution, aliases)         |
| `Sources/YamlKit/Schema`   | `YAMLSchema` with the core, JSON, and failsafe schemas        |
| `Sources/YamlKit/Emitter`  | `YAMLEmitter` and the serializer                              |
| `Sources/YamlKit/Codable`  | `YAMLDecoder` and `YAMLEncoder`                               |

## Documentation

The DocC documentation contains API reference, a getting started guide, and a description of
the architecture. In Xcode, choose Product ▸ Build Documentation.

Without Xcode, use `Scripts/build-documentation.sh`. It extracts the symbol graph with SwiftPM and
runs the `docc` tool of the Swift toolchain (found on the `PATH`, or via `xcrun` on macOS), so
the package needs no documentation plugin dependency:

```sh
Scripts/build-documentation.sh archive    # .build/YamlKit.doccarchive
Scripts/build-documentation.sh preview    # live preview at http://localhost:8080/documentation/yamlkit
```

### Static Website

To publish the documentation on a static web server such as GitHub Pages, run:

```sh
Scripts/build-documentation.sh site swift-yamlkit
```

The website is written to `.build/docs-site`. The second argument is the hosting base path,
i.e. the URL path under which the site is served; `swift-yamlkit` matches
`https://<user>.github.io/swift-yamlkit/`. Omit it if the site is served from the root of a
domain. Copy the contents of `.build/docs-site` to the web server (for GitHub Pages, e.g. to the
`docs` folder of the publishing branch); the documentation is then available at
`<base URL>/documentation/yamlkit/`.

The script performs these steps, which can also be run by hand:

```sh
swift build --target YamlKit --scratch-path .build/docs \
  -Xswiftc -emit-symbol-graph -Xswiftc -emit-symbol-graph-dir -Xswiftc "$PWD/.build/symbol-graphs"
docc convert Sources/YamlKit/Documentation.docc \
  --fallback-display-name YamlKit --fallback-bundle-identifier org.objecthub.YamlKit \
  --additional-symbol-graph-dir .build/symbol-graphs \
  --transform-for-static-hosting --hosting-base-path swift-yamlkit \
  --output-path .build/docs-site
```

On macOS, use `xcrun docc` if `docc` is not on the `PATH`.

## Testing

```sh
swift test
```

The test suite includes unit tests for every layer, randomized round-trip tests, and
conformance tests based on a vendored snapshot of the YAML test suite. For every case of
the suite, the tests verify the parsing events, the composed data (against `in.json`),
and that emitting and serializing preserve the content. The snapshot can be updated with
`Scripts/update-yaml-test-suite.sh`.

## License

YamlKit is distributed under the Apache License, Version 2.0. See [LICENSE](LICENSE).
The vendored YAML test suite data is distributed under the MIT license by its authors.
