# CLAUDE.md

Guidance for working on **YamlKit** (`swift-yamlkit`): a dependency-free YAML 1.2.2 parser/emitter
with `Codable` support (`YAMLDecoder`/`YAMLEncoder`) for macOS 13+ / iOS 16+, Swift 6 language mode.

## Commands

```bash
swift build
swift test                                   # all tests (~2 s)
swift test --filter YAMLTestSuiteTests       # conformance only
swift test --filter "Round trips"            # randomized Codable round trips
xcodebuild -scheme swift-yamlkit -destination 'generic/platform=iOS Simulator' build -quiet
xcodebuild test -scheme swift-yamlkit -destination 'platform=macOS'   # tests via Xcode's build system
xcodebuild docbuild -scheme swift-yamlkit -destination 'generic/platform=macOS'   # must stay warning-free
Scripts/build-documentation.sh archive       # DocC without Xcode → .build/YamlKit.doccarchive
Scripts/build-documentation.sh site swift-yamlkit   # static website → .build/docs-site (arg = hosting base path)
Scripts/build-documentation.sh preview       # live preview at http://localhost:8080/documentation/yamlkit
Scripts/update-yaml-test-suite.sh [data-YYYY-MM-DD]   # refresh vendored test suite (default data-2022-01-17)
```

The Xcode scheme is `swift-yamlkit` (not `YamlKit`).

### Xcode

There is deliberately **no `.xcodeproj`**: Xcode opens `Package.swift` directly (`xed .`), and
`Package.swift` is the single source of truth for targets, platforms, and resources — never add a
project file that duplicates it. The shared scheme lives in
`.swiftpm/xcode/xcshareddata/xcschemes/swift-yamlkit.xcscheme` (builds `YamlKit`, tests
`YamlKitTests`, code coverage for `YamlKit`). `.gitignore` excludes everything in `.swiftpm/` except
`xcode/xcshareddata`, so user state and `.swiftpm/configuration` stay untracked. If you add targets,
add them to that scheme as well. Tests pass under both `swift test` and
`xcodebuild test -scheme swift-yamlkit -destination 'platform=macOS'` (or an iOS Simulator, see
`xcodebuild -scheme swift-yamlkit -showdestinations`); test resources are loaded via `Bundle.module`,
which works in both. `xcrun xccov` currently fails to read the coverage archive of this Xcode
version; use Xcode's Report navigator to view coverage.

`Scripts/build-documentation.sh` needs no Xcode and no `swift-docc-plugin` dependency (keep the package
dependency-free): it runs `swift package dump-symbol-graph --minimum-access-level public` (scratch path
`.build/docs`), takes the output directory from the printed `Files written to …` line (it differs between
SwiftPM versions), copies only `YamlKit*.symbols.json` into `.build/symbol-graphs`, and then runs
`docc convert … --additional-symbol-graph-dir .build/symbol-graphs`; `docc` is taken from the `PATH` or
`xcrun --find docc`. `site` mode adds `--transform-for-static-hosting` and `--hosting-base-path`.
Don't go back to `swift build -Xswiftc -emit-symbol-graph`: it only emits a graph when the module is
recompiled, so a second run produced no graph and every symbol link failed ("doesn't exist at …").
If DocC reports many "doesn't exist" / "No symbol matched 'YamlKit'" warnings, the symbol graph is missing.
When adding DocC articles, also list them in the Topics of `Documentation.docc/YamlKit.md` and keep the
README's Documentation section in sync with the script.

## Architecture

The YAML processing model (spec chapter 3) is implemented as separate layers, each usable on its own:

```
text ─Reader─▶ scalars ─Scanner─▶ tokens ─YAMLParser─▶ events ─Composer─▶ YAMLNode ─YAMLDecoderImpl─▶ values
text ◀────────── YAMLEmitter ◀──────────── events ◀─Serializer─ YAMLNode ◀─YAMLEncoderImpl─ values
```

| Path | Role |
|---|---|
| `Sources/YamlKit/Reader/Reader.swift` | Encoding detection (BOM / null patterns, §5.2), CRLF/CR → LF normalization, rejects non-printable chars. Output is `[Unicode.Scalar]`. |
| `Sources/YamlKit/Scanner/` | libyaml-style tokenizer. `Scanner.swift`: token queue, indentation stack (roll/unroll), simple keys, flow stack, 1.2 tab/indent rules. `+Scalars`: plain, quoted, block scalars. `+Properties`: anchors, tags, directives. |
| `Sources/YamlKit/Parser/` | `YAMLParser` — pull-based, non-recursive LL(1) state machine (`State` enum + `states` stack). `YAMLEvent`. Tag handle resolution + percent-decoding happen here. |
| `Sources/YamlKit/Node/` | `YAMLNode` (enum: `.scalar/.sequence/.mapping`) and `Composer` (iterative; tag resolution via schema, alias substitution, duplicate keys, merge keys, alias-expansion limit). |
| `Sources/YamlKit/Schema/YAMLSchema.swift` | `YAMLSchema` protocol + `CoreSchema` (default), `JSONSchema`, `FailsafeSchema`; numeric parsing helpers (`CoreSchema.parseInteger/parseFloat`). |
| `Sources/YamlKit/Emitter/` | `Serializer` (node → events: implicit vs explicit tags, quoting of ambiguous strings, anchors→aliases) and `YAMLEmitter` (events → text; port of libyaml's emitter with 1.2 fixes). |
| `Sources/YamlKit/Codable/` | Public `YAMLDecoder`/`YAMLEncoder` (option structs behind `NSLock`, `@unchecked Sendable`) and internal `YAMLDecoderImpl`/`YAMLEncoderImpl` (containers). `CodingSupport.swift`: `YAMLCodingKey`, key case conversion, YAML timestamp parsing/formatting. |
| `Sources/YamlKit/YAML.swift` | Public façade: `YAML.parseEvents/parse/parseAll/emit/serialize`, `YAML.ParseOptions`, `YAML.SerializeOptions`. |
| `Sources/YamlKit/Documentation.docc/` | DocC landing page, GettingStarted, Architecture. |
| `Scripts/` | `update-yaml-test-suite.sh` (vendor test suite), `build-documentation.sh` (DocC without Xcode). |

### Key design facts

- **Scanner is where most YAML 1.2 subtlety lives.** Important state: `simpleKeyAllowed`, `simpleKeys` (one per flow level), `noBlockCollectionLine` (block collections may not start on the line of an implicit key's `:` or of `---`), `adjacentValueAllowed` (JSON-like keys: `{"a":b}`), `flowCollections` (`true` = flow mapping; multi-line implicit keys are allowed only there). `rollIndent` rejects tabs in the whitespace before a new compact collection. `checkIndentation` enforces flow-content indentation and tab-indentation rules. Rules are commented with spec production numbers (`[170] c-l+literal(n)`) — keep doing that.
- **Block scalar indentation:** content indent = parent block indent + indicator, where the top level is `-1` (spec semantics, *not* libyaml's). Auto-detection is in `detectBlockScalarIndentation`. A final whitespace-only line at EOF counts as a terminated line (tests JEF9/02, L24T/01).
- **Events** carry `tag: YAMLTag?` (`nil` = no tag in source) and `ScalarStyle`. `YAMLTag.nonSpecific` is `!`.
- **Nodes always have resolved tags.** Equality/hash use `Scalar.canonicalValue` (so `~ == null`, `0x1 == 1`); mapping equality is order-insensitive; style/anchor/mark are ignored. Node `style == nil` means "serializer chooses".
- **No alias node case**: the composer substitutes aliased nodes (COW-shared) but keeps `anchor`; the serializer emits an alias when the same anchor reappears with an equal node.
- **Composer and parser must stay non-recursive** (deep documents). Composer frames are classes so collections grow in place — an earlier enum-payload version was O(n²) (32 s vs 0.5 s on 6.8 MB). Watch for accidental copy-on-write in hot loops.
- **Emitter style selection**: `analyze()` computes allowed styles (1.2 plain rules for flow context), `selectStyle()` falls back plain → single → double. Empty plain scalars are allowed except as property-less flow-sequence entries. `needsSpaceBeforeValueIndicator` handles `*alias : v` and `&anchor : v`. Block scalar indentation hints are `indent - parentIndent`; root block scalars needing a hint are written double-quoted (YAML 1.1/1.2 ambiguity). NEL/LS/PS are always escaped.
- **Decoder semantics**: `String` decodes from any non-null scalar; numbers/bools require the matching resolved tag (quoted `"12"` is not an `Int`); non-core tags are re-resolved by the schema; bool accepts 1.1 spellings when the schema tags them bool. Errors map to `DecodingError` with coding path and `(line X, column Y)` in the description; YAML syntax errors become `.dataCorrupted` with the `YAMLError` as `underlyingError`.
- **Encoder**: keys keep encoding order unless `.sortedKeys`; int-valued coding keys become int scalars; `Data` → `!!binary`; dates default to ISO 8601 timestamps; `superEncoder` uses `YAMLReferencingEncoder` (writes into parent on `deinit`).
- **Defaults**: `maximumDepth` 512 (recursive `Codable` decoding overflows 512 KiB thread stacks around depth ~500), `maximumAliasExpansion` 1,000,000, duplicate keys rejected, merge keys off.

## Tests

Swift Testing (`@Test`, `#expect`), parameterized where useful. Layout mirrors the sources:
`Tests/YamlKitTests/{Parsing,Nodes,Emitting,Codable,Conformance}`.

- **Conformance** (`Conformance/YAMLTestSuiteTests.swift`) runs for every vendored case of
  `Tests/YamlKitTests/Resources/yaml-test-suite/<ID>[/<NN>]/` (`in.yaml`, `test.event`, `in.json`, `error`, …):
  1. events formatted by `EventFormatter` must equal `test.event`; `error` cases must throw;
  2. composed nodes must equal `in.json` (parsed by the test-only `JSONValue` stream parser);
  3. emit → re-parse must give equal *normalized* events (`normalize`: ignores doc markers, collection
     styles, and scalar style except for untagged plain scalars not resolving to `!!str`);
  4. serialize nodes → re-parse must give equal nodes.
  All 402 cases pass; any regression here is a real bug. Don't add a known-failures list without discussing it.
- `Codable/RoundTripTests.swift` — seeded random records/values with nasty strings across formatting
  options and line widths (50 seeds by default; temporarily raise to several hundred after emitter changes).
- `@testable import YamlKit` gives access to internals (`Scanner`, `Token`, `Reader`, `YAMLCodingKey`).
- Beware: `Testing` exports `Tag`; that's why the library type is `YAMLTag`.

### Debugging workflow

For quick experiments, use a scratch executable package that depends on this one by path
(`.package(path: "…/swift-yamlkit")`) and copy `EventFormatter.swift` into it to print events in
test-suite notation. A mutation fuzzer (randomly edit test-suite inputs, keep the ones that parse,
then check emit → re-parse with the normalization above) was very effective at finding emitter bugs;
build it with `-c release` and run ~10⁶ iterations after emitter changes.

## Extending

- **New syntax rule / scanner fix**: add the rule in the scanner (cite the production), add a case to
  `ScannerTests`/`ParserTests`, run conformance.
- **New schema**: conform to `YAMLSchema` (`tag(forPlainScalar:)`); add a static accessor in an
  `extension YAMLSchema where Self == …` like `.core`; add resolution cases to `SchemaTests`.
- **New decoding/encoding strategy or option**: add the case to the public enum/`OutputFormatting`,
  store it in the `Options` struct, add a locked accessor on the public class, implement in the
  `*Impl` file, document it, and test it in `DecoderTests`/`EncoderTests`.
- **Emitter formatting option**: add to `YAMLEmitter.Options` (and map it in
  `YAMLEncoder.Options.serializeOptions` if it should be exposed via the encoder).
- **Special Foundation types** (like `Date`, `Data`, `URL`, `Decimal`) are switched on in
  `YAMLDecoderImpl.unbox` and `YAMLEncoderImpl.box`.

## Conventions

- Follow Apple's API Design Guidelines; uniform acronym casing (`YAMLNode`, `YAMLTag`, `baseURL`).
- 2-space indentation, explicit `self.`, `case` labels indented inside `switch`, file header comment
  (`//  File.swift / YamlKit / Copyright 2026 Matthias Zenger. Licensed under the Apache License, Version 2.0.`).
- Every public declaration gets a `///` doc comment; DocC must build without warnings
  (overloaded symbol links need disambiguation, e.g. ``YAML/parseEvents(_:)-(String)``).
- All public types are `Sendable`; no force unwraps in library code except type-checked `as!` after `is`.
- No external dependencies.
- Errors: throw `YAMLError(kind, message, at: mark)` with the most precise `Mark` available.
- The vendored test suite is data under MIT license (`Resources/yaml-test-suite/LICENSE`); don't edit it by hand.
