# Architecture

How YamlKit implements the YAML 1.2.2 processing model and how it can be extended.

## Overview

The YAML specification describes YAML processing as a series of transformations between
three representations (chapter 3). YamlKit implements each of them as a separate,
publicly accessible layer:

```
               parse            compose             decode
 YAML text ──────────▶ events ──────────▶ nodes ──────────▶ Swift values
           ◀────────── events ◀────────── nodes ◀────────── Swift values
               emit           serialize             encode
```

| Layer      | Types                                   | Responsibility                                       |
|------------|-----------------------------------------|------------------------------------------------------|
| Reader     | `Reader` (internal)                     | Encoding detection, line break normalization         |
| Scanner    | `Scanner` (internal)                    | Tokens, indentation, scalar folding and escaping     |
| Parser     | ``YAMLParser``, ``YAMLEvent``           | Grammar of documents, nodes, and collections         |
| Composer   | ``YAML``, ``YAMLNode``, ``YAMLSchema``  | Tag resolution, aliases, key uniqueness, merge keys  |
| Serializer | ``YAML``                                | Implicit tags, quoting, anchors and aliases          |
| Emitter    | ``YAMLEmitter``                         | Presentation styles, indentation, line folding       |
| Codable    | ``YAMLDecoder``, ``YAMLEncoder``        | Mapping between nodes and `Codable` types            |

### Scanner and Parser

The scanner follows the proven design of libyaml: it converts indentation into explicit
block start and end tokens and inserts the tokens of implicit keys retroactively once
the value indicator `:` has been found. On top of that design, it implements the rules
that YAML 1.2 tightened compared to YAML 1.1, e.g. restrictions on tabs, the
requirement that block collections start on a new line, multi-line keys in flow
mappings, JSON-like keys followed by adjacent values, and the indentation of flow
content. Every rule is annotated with the production number of the specification.

The parser is a pull-based LL(1) state machine. It never recurses, so the nesting depth
of documents is only limited by the configurable ``YAML/ParseOptions/maximumDepth``.

### Composer and Schemas

The composer resolves the tags of untagged nodes using a ``YAMLSchema``. The three
schemas of the specification are provided; custom schemas, e.g. to interpret the
YAML 1.1 booleans `yes` and `no`, can be implemented by conforming to the protocol.

Aliases are replaced by the nodes they refer to. Because ``YAMLNode`` is a value type,
the copies share their storage. To protect against maliciously crafted documents
("billion laughs"), the total number of nodes copied by aliases is limited by
``YAML/ParseOptions/maximumAliasExpansion``.

### Serializer and Emitter

The serializer decides for every scalar whether its tag can be left implicit: a string
such as `true` must be quoted, while an integer tagged `!!int` can be written in plain
style. The emitter chooses the presentation style of every scalar, honoring the
requested style if the content permits it. It falls back to single-quoted and finally
double-quoted style where necessary.

## Conformance Testing

The package vendors a snapshot of the [YAML test suite](https://github.com/yaml/yaml-test-suite)
(`Tests/YamlKitTests/Resources/yaml-test-suite`; refresh it with
`Scripts/update-yaml-test-suite.sh`). For every test case, the unit tests verify that

1. invalid documents are rejected and the events of valid documents match `test.event`,
2. composed nodes match the expected JSON data in `in.json`,
3. emitting the parsed events and parsing the result again yields equivalent events, and
4. serializing the composed nodes and parsing the result again yields equal nodes.

In addition, randomized round-trip tests encode values containing all kinds of special
characters and verify that they are decoded unchanged.
