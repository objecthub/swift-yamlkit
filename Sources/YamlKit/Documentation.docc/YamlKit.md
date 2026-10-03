# ``YamlKit``

Parse and generate YAML 1.2 and convert between YAML and Swift types with `Codable`.

## Overview

YamlKit is a pure Swift implementation of the [YAML 1.2.2 specification](https://yaml.org/spec/1.2.2/).
It provides ``YAMLDecoder`` and ``YAMLEncoder``, which work just like `JSONDecoder` and
`JSONEncoder`, and gives access to every intermediate representation of the YAML
processing model: event streams, node trees, and text.

```swift
import YamlKit

struct Service: Codable {
  var image: String
  var ports: [Int]
  var environment: [String: String]
}

let yaml = """
  image: nginx:1.27
  ports: [80, 443]
  environment:
    TZ: Europe/Zurich
  """

let service = try YAMLDecoder().decode(Service.self, from: yaml)
let text = try YAMLEncoder().encodeToString(service)
```

The parser passes all 402 test cases of the official
[YAML test suite](https://github.com/yaml/yaml-test-suite), which is vendored into the
package and run as part of its unit tests.

## Topics

### Essentials

- <doc:GettingStarted>
- ``YAMLDecoder``
- ``YAMLEncoder``

### Nodes

- ``YAML``
- ``YAMLNode``
- ``YAMLTag``

### Schemas

- ``YAMLSchema``
- ``CoreSchema``
- ``JSONSchema``
- ``FailsafeSchema``

### Events

- ``YAMLParser``
- ``YAMLEmitter``
- ``YAMLEvent``
- ``ScalarStyle``
- ``CollectionStyle``
- ``YAMLVersion``
- ``TagDirective``

### Errors

- ``YAMLError``
- ``Mark``

### Design

- <doc:Architecture>
