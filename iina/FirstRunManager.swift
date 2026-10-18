//
//  FirstRunManager.swift
//  iina
//
//  Created by Collider LI on 29/1/2018.
//  Copyright © 2018 lhc. All rights reserved.
//

import Foundation

class FirstRunManager {
  struct Key: RawRepresentable {
    typealias RawValue = String
    var rawValue: String

    init(_ value: String) {
      self.rawValue = value
    }

    init(rawValue: String) {
      self.rawValue = rawValue
    }
  }

  /// Find whether the flag file of `key` is not in the Application Support folder, writing it when it is not, on
  /// `Utility.folderQueue` after the app's folders are made, so that the main thread does not wait for the file system; then give
  /// the answer to `then` on the main thread.
  static func isFirstRun(for key: Key, then: @escaping (Bool) -> Void) {
    let filename = ".\(key.rawValue)"
    let fileURL = Utility.appSupportDirUrl.appendingPathComponent(filename, isDirectory: false)
    Utility.folderQueue.async {
      let isFirstRun = !FileManager.default.fileExists(atPath: fileURL.path)
      if isFirstRun {
        FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
      }
      DispatchQueue.main.async { then(isFirstRun) }
    }
  }

  /// Remove the flag file of `key` on `Utility.folderQueue`, after it is written.
  static func unsetFirstRun(for key: Key) {
    let filename = ".\(key.rawValue)"
    let fileURL = Utility.appSupportDirUrl.appendingPathComponent(filename, isDirectory: false)
    Utility.folderQueue.async {
      try? FileManager.default.removeItem(at: fileURL)
    }
  }
}
