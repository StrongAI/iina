//
//  MPVCommandWrappers.swift
//  iina
//
//  Created by Yuze Jiang on 2025/05/25.
//  Copyright © 2025 lhc. All rights reserved.
//

extension MPVController {
  func playlistInsert(_ path: String, index: Int) {
    command(.loadfile, args: [path, "insert-at", index.description], level: .verbose)
  }

  func playlistAppend(_ path: String) {
    command(.loadfile, args: [path, "append"], level: .verbose)
  }

  /// Append the given file to the playlist without waiting for `mpv`, which appends it after the requests made before.
  func playlistAppendAsync(_ path: String) {
    asyncCommand(.loadfile, args: [path, "append"], replyUserdata: 0, level: .verbose)
  }

  /// Insert the given file into the playlist at the given index without waiting for `mpv`, which inserts it after the requests
  /// made before. A file inserted at an index past the end of the playlist is appended.
  func playlistInsertAsync(_ path: String, index: Int) {
    asyncCommand(.loadfile, args: [path, "insert-at", index.description], replyUserdata: 0, level: .verbose)
  }

  /// Move the playlist entry at `from` to before the entry at `to` without waiting for `mpv`, which moves it after the requests made
  /// before.
  func playlistMoveAsync(_ from: Int, to: Int) {
    asyncCommand(.playlistMove, args: ["\(from)", "\(to)"], replyUserdata: 0, level: .verbose)
  }

  /// Remove the playlist entry at the given index without waiting for `mpv`, which removes it after the requests made before.
  func playlistRemoveAsync(_ index: Int) {
    asyncCommand(.playlistRemove, args: [index.description], replyUserdata: 0, level: .verbose)
  }

}
