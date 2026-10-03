//
//  YAMLTag.swift
//  YamlKit
//
//  Copyright 2026 Matthias Zenger. Licensed under the Apache License,
//  Version 2.0. See LICENSE for details.
//

/// A fully resolved YAML tag.
///
/// Tags identify the native data type of a node (YAML 1.2.2, section 3.2.1.1).
/// In the presentation, tags are usually written in a shorthand notation such
/// as `!!str`; YamlKit always stores the resolved form, e.g.
/// `tag:yaml.org,2002:str`.
public struct YAMLTag: RawRepresentable, Sendable, Hashable, Comparable,
                   ExpressibleByStringLiteral, CustomStringConvertible {

  /// The resolved tag URI (or local tag such as `!foo`).
  public let rawValue: String

  /// Creates a tag from its resolved representation.
  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  /// Creates a tag from its resolved representation.
  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }

  public init(stringLiteral value: String) {
    self.rawValue = value
  }

  /// The prefix associated with the secondary tag handle `!!`.
  public static let yamlPrefix = "tag:yaml.org,2002:"

  /// The non-specific tag `!`, which forces a scalar to be interpreted as a
  /// string, a sequence, or a mapping depending on the node kind.
  public static let nonSpecific = YAMLTag("!")

  /// `tag:yaml.org,2002:str` (failsafe schema).
  public static let str = YAMLTag(yamlPrefix + "str")
  /// `tag:yaml.org,2002:seq` (failsafe schema).
  public static let seq = YAMLTag(yamlPrefix + "seq")
  /// `tag:yaml.org,2002:map` (failsafe schema).
  public static let map = YAMLTag(yamlPrefix + "map")
  /// `tag:yaml.org,2002:null` (JSON and core schema).
  public static let null = YAMLTag(yamlPrefix + "null")
  /// `tag:yaml.org,2002:bool` (JSON and core schema).
  public static let bool = YAMLTag(yamlPrefix + "bool")
  /// `tag:yaml.org,2002:int` (JSON and core schema).
  public static let int = YAMLTag(yamlPrefix + "int")
  /// `tag:yaml.org,2002:float` (JSON and core schema).
  public static let float = YAMLTag(yamlPrefix + "float")
  /// `tag:yaml.org,2002:binary` (YAML 1.1 type for base64-encoded data).
  public static let binary = YAMLTag(yamlPrefix + "binary")
  /// `tag:yaml.org,2002:timestamp` (YAML 1.1 type for points in time).
  public static let timestamp = YAMLTag(yamlPrefix + "timestamp")
  /// `tag:yaml.org,2002:merge` (YAML 1.1 merge key `<<`).
  public static let merge = YAMLTag(yamlPrefix + "merge")
  /// `tag:yaml.org,2002:set` (YAML 1.1 type for unordered sets).
  public static let set = YAMLTag(yamlPrefix + "set")
  /// `tag:yaml.org,2002:omap` (YAML 1.1 type for ordered mappings).
  public static let omap = YAMLTag(yamlPrefix + "omap")

  /// Returns `true` if this is a tag of the `tag:yaml.org,2002:` namespace.
  public var isYAMLTag: Bool {
    return self.rawValue.hasPrefix(YAMLTag.yamlPrefix)
  }

  /// Returns `true` if this is a local tag (i.e. it starts with `!`).
  public var isLocal: Bool {
    return self.rawValue.hasPrefix("!")
  }

  public static func < (lhs: YAMLTag, rhs: YAMLTag) -> Bool {
    return lhs.rawValue < rhs.rawValue
  }

  public var description: String {
    if self.isYAMLTag {
      return "!!" + self.rawValue.dropFirst(YAMLTag.yamlPrefix.count)
    } else if self.isLocal {
      return self.rawValue
    } else {
      return "!<\(self.rawValue)>"
    }
  }
}
