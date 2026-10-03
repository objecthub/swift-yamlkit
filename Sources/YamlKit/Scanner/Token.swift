//
//  Token.swift
//  YamlKit
//
//  Copyright 2026 Matthias Zenger. Licensed under the Apache License,
//  Version 2.0. See LICENSE for details.
//

/// A lexical token produced by the ``Scanner``.
///
/// Tokens abstract away indentation: the scanner turns changes in
/// indentation into explicit ``Kind/blockSequenceStart``,
/// ``Kind/blockMappingStart`` and ``Kind/blockEnd`` tokens, so that the
/// ``YAMLParser`` can be implemented as a simple LL(1) state machine.
struct Token: Sendable, CustomStringConvertible {

  /// The different kinds of tokens.
  enum Kind: Sendable, Equatable {
    case streamStart
    case streamEnd
    /// `%YAML major.minor`
    case versionDirective(YAMLVersion)
    /// `%TAG handle prefix`
    case tagDirective(TagDirective)
    /// Any other (reserved) directive, which is ignored.
    case reservedDirective(String)
    /// `---`
    case documentStart
    /// `...`
    case documentEnd
    case blockSequenceStart
    case blockMappingStart
    case blockEnd
    /// `[`
    case flowSequenceStart
    /// `]`
    case flowSequenceEnd
    /// `{`
    case flowMappingStart
    /// `}`
    case flowMappingEnd
    /// `-` in block context.
    case blockEntry
    /// `,`
    case flowEntry
    /// `?` or an implicit key.
    case key
    /// `:`
    case value
    /// `*name`
    case alias(String)
    /// `&name`
    case anchor(String)
    /// A tag property. `handle` is `nil` for verbatim tags (`!<...>`); the
    /// suffix is not percent-decoded yet.
    case tag(handle: String?, suffix: String)
    /// A scalar with its (already unescaped and folded) value.
    case scalar(String, ScalarStyle)
  }

  /// The kind of the token, including its payload.
  var kind: Kind

  /// The position of the first character of the token.
  var start: Mark

  /// The position following the last character of the token.
  var end: Mark

  var description: String {
    return "\(self.kind)"
  }

  /// A short description of the token kind used in error messages.
  var name: String {
    switch self.kind {
      case .streamStart: return "stream start"
      case .streamEnd: return "end of stream"
      case .versionDirective: return "%YAML directive"
      case .tagDirective: return "%TAG directive"
      case .reservedDirective: return "directive"
      case .documentStart: return "document start '---'"
      case .documentEnd: return "document end '...'"
      case .blockSequenceStart: return "block sequence"
      case .blockMappingStart: return "block mapping"
      case .blockEnd: return "end of block collection"
      case .flowSequenceStart: return "'['"
      case .flowSequenceEnd: return "']'"
      case .flowMappingStart: return "'{'"
      case .flowMappingEnd: return "'}'"
      case .blockEntry: return "'-'"
      case .flowEntry: return "','"
      case .key: return "key"
      case .value: return "':'"
      case .alias: return "alias"
      case .anchor: return "anchor"
      case .tag: return "tag"
      case .scalar: return "scalar"
    }
  }
}
