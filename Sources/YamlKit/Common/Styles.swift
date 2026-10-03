//
//  Styles.swift
//  YamlKit
//
//  Copyright 2026 Matthias Zenger. Licensed under the Apache License,
//  Version 2.0. See LICENSE for details.
//

/// The presentation style of a scalar (YAML 1.2.2, sections 7.3 and 8.1).
public enum ScalarStyle: String, Sendable, Hashable, CaseIterable {
  /// An unquoted flow scalar, e.g. `value`.
  case plain
  /// A single-quoted flow scalar, e.g. `'value'`.
  case singleQuoted
  /// A double-quoted flow scalar supporting escape sequences, e.g. `"value"`.
  case doubleQuoted
  /// A literal block scalar introduced by `|`.
  case literal
  /// A folded block scalar introduced by `>`.
  case folded

  /// Returns `true` for the two block scalar styles.
  public var isBlock: Bool {
    return self == .literal || self == .folded
  }

  /// Returns `true` for the two quoted scalar styles.
  public var isQuoted: Bool {
    return self == .singleQuoted || self == .doubleQuoted
  }
}

/// The presentation style of a sequence or mapping.
public enum CollectionStyle: String, Sendable, Hashable, CaseIterable {
  /// Indentation-based block style.
  case block
  /// Bracketed flow style, i.e. `[ ... ]` or `{ ... }`.
  case flow
}

/// A YAML version as declared by a `%YAML` directive.
public struct YAMLVersion: Sendable, Hashable, Comparable, CustomStringConvertible {

  /// The major version number.
  public var major: Int

  /// The minor version number.
  public var minor: Int

  /// Creates a new version.
  public init(major: Int, minor: Int) {
    self.major = major
    self.minor = minor
  }

  /// YAML 1.1.
  public static let v1_1 = YAMLVersion(major: 1, minor: 1)

  /// YAML 1.2, the version implemented by YamlKit.
  public static let v1_2 = YAMLVersion(major: 1, minor: 2)

  public static func < (lhs: YAMLVersion, rhs: YAMLVersion) -> Bool {
    return (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
  }

  public var description: String {
    return "\(self.major).\(self.minor)"
  }
}

/// A `%TAG` directive associating a tag handle with a tag prefix.
public struct TagDirective: Sendable, Hashable, CustomStringConvertible {

  /// The tag handle, e.g. `!`, `!!`, or `!e!`.
  public var handle: String

  /// The prefix that the handle expands to.
  public var prefix: String

  /// Creates a new tag directive.
  public init(handle: String, prefix: String) {
    self.handle = handle
    self.prefix = prefix
  }

  /// The default tag directives that are implicitly in effect for every
  /// document.
  public static let defaults: [TagDirective] = [
    TagDirective(handle: "!", prefix: "!"),
    TagDirective(handle: "!!", prefix: YAMLTag.yamlPrefix)
  ]

  public var description: String {
    return "%TAG \(self.handle) \(self.prefix)"
  }
}
