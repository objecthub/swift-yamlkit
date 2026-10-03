//
//  EventFormatter.swift
//  YamlKitTests
//
//  Copyright 2026 Matthias Zenger. Licensed under the Apache License,
//  Version 2.0. See LICENSE for details.
//

import YamlKit

/// Renders events in the notation used by the `test.event` files of the
/// YAML test suite.
enum EventFormatter {

  /// Returns the test suite representation of `events`, one line per event.
  static func format(_ events: [YAMLEvent]) -> String {
    return events.map { EventFormatter.format($0) + "\n" }.joined()
  }

  /// Returns the test suite representation of a single event.
  static func format(_ event: YAMLEvent) -> String {
    switch event.kind {
      case .streamStart:
        return "+STR"
      case .streamEnd:
        return "-STR"
      case .documentStart(_, _, let isImplicit):
        return isImplicit ? "+DOC" : "+DOC ---"
      case .documentEnd(let isImplicit):
        return isImplicit ? "-DOC" : "-DOC ..."
      case .alias(let anchor):
        return "=ALI *\(anchor)"
      case .scalar(let value, let style, let tag, let anchor):
        let indicator: String
        switch style {
          case .plain: indicator = ":"
          case .singleQuoted: indicator = "'"
          case .doubleQuoted: indicator = "\""
          case .literal: indicator = "|"
          case .folded: indicator = ">"
        }
        return "=VAL" + EventFormatter.properties(anchor: anchor, tag: tag)
          + " " + indicator + EventFormatter.escape(value)
      case .sequenceStart(let style, let tag, let anchor):
        return "+SEQ" + (style == .flow ? " []" : "")
          + EventFormatter.properties(anchor: anchor, tag: tag)
      case .sequenceEnd:
        return "-SEQ"
      case .mappingStart(let style, let tag, let anchor):
        return "+MAP" + (style == .flow ? " {}" : "")
          + EventFormatter.properties(anchor: anchor, tag: tag)
      case .mappingEnd:
        return "-MAP"
    }
  }

  private static func properties(anchor: String?, tag: YAMLTag?) -> String {
    var result = ""
    if let anchor {
      result += " &\(anchor)"
    }
    if let tag {
      result += " <\(tag.rawValue)>"
    }
    return result
  }

  private static func escape(_ value: String) -> String {
    var result = ""
    for scalar in value.unicodeScalars {
      switch scalar {
        case "\\": result += "\\\\"
        case "\n": result += "\\n"
        case "\t": result += "\\t"
        case "\r": result += "\\r"
        case "\u{08}": result += "\\b"
        default: result.unicodeScalars.append(scalar)
      }
    }
    return result
  }
}
