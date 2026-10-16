//
//  ISO639_Helper.swift
//  iina
//
//  Created by lhc on 14/3/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Foundation


class ISO639Helper {
  struct Language {
    var code: String
    var name: [String]

    var description: String {
      return "\(name[0]) (\(code))"
    }
  }

  static let descriptionRegex = Regex("^.+?\\(([a-z]{2,3})\\)$")

  /// The queue the language list is read and sorted on, so that the main thread does not wait for the file system or for the sort.
  static let queue = DispatchQueue(label: "IINAISO639", qos: .userInitiated)

  /// The languages sorted by description, once `load(then:)` has read them on `queue`, and empty until then. Read and set on the
  /// main thread; a test empties it to have the list read again.
  static var languages: [Language] = []

  /// Whether the language list is being read on `queue`.
  private static var loading = false

  /// The callers to tell on the main thread once the language list being read has been read.
  private static var whenLoaded: [() -> Void] = []

  /// Read the language list on `queue` unless it has been read, then call `completion` on the main thread once it has been.
  static func load(then completion: @escaping () -> Void) {
    guard languages.isEmpty else {
      DispatchQueue.main.async(execute: completion)
      return
    }
    whenLoaded.append(completion)
    guard !loading else { return }
    loading = true
    queue.async {
      let read = ISO639Helper.readLanguages()
      DispatchQueue.main.async {
        ISO639Helper.languages = read
        ISO639Helper.loading = false
        let completions = ISO639Helper.whenLoaded
        ISO639Helper.whenLoaded = []
        completions.forEach { $0() }
      }
    }
  }

  /// The languages of the ISO639.strings file in the app bundle, sorted by description, ascending alpha order.
  private static func readLanguages() -> [Language] {
    guard let filePath = Bundle.main.path(forResource: "ISO639", ofType: "strings"),
          let dictionary = NSDictionary(contentsOfFile: filePath) as? [String: String] else {
      Logger.log("Cannot read the ISO639 language list", level: .error)
      return []
    }
    var result = dictionary.map { Language(code: $0.key, name: $0.value.split(separator: ";").map { String($0) }) }
    result.sort { $0.description.localizedCompare($1.description) == .orderedAscending }
    return result
  }
}
