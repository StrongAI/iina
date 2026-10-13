//
//  DraggingDetect.swift
//  iina
//
//  Created by Yuze Jiang on 05/08/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Foundation

extension PlayerCore {

  /**
   Returns playable files contained in a URL list. Any non-file URL will be counted directly without further checking.

   - Parameters:
     - urls: The list as an array of `URL`.
   - Returns: URLs of all playable files as an array of `URL`.
   */
  func getPlayableFiles(in urls: [URL]) -> [URL] {
    var playableFiles: [URL] = []
    for url in urls {
      if !url.isFileURL {
        playableFiles.append(url)
        continue
      }
      if url.hasDirectoryPath {
        // is directory
        // `enumerator(at:includingPropertiesForKeys:)` doesn't work :(
        guard let dirEnumerator = FileManager.default.enumerator(atPath: url.path) else { return [] }
        while let fileName = dirEnumerator.nextObject() as? String {
          guard !fileName.hasPrefix(".") else { continue }
          if Utility.playableFileExt.contains(fileName.lowercasedPathExtension) {
            playableFiles.append(url.appendingPathComponent(fileName))
          }
        }
      } else {
        // is file
        if !Utility.blacklistExt.contains(url.pathExtension.lowercased()) {
          playableFiles.append(url)
        }
      }
    }
    return Array(Set(playableFiles)).sorted { url1, url2 in
      let folder1 = url1.deletingLastPathComponent(), folder2 = url2.deletingLastPathComponent()
      if folder1.absoluteString == folder2.absoluteString {
        return url1.lastPathComponent.localizedStandardCompare(url2.lastPathComponent) == .orderedAscending
      } else {
        return folder1.absoluteString < folder2.absoluteString
      }
    }
  }

  /**
   Checks whether a URL is BD folder by checking the existence of "MovieObject.bdmv" and "index.bdmv".

   - Parameters:
     - url: The URL.
   - Returns: Whether the URL is a BD folder.
   */
  func isBDFolder(_ url: URL) -> Bool {
  
    func isBDMVFolder(_ url: URL) -> Bool {
      if let files = try? FileManager.default.contentsOfDirectory(atPath: url.path) {
        return files.contains("MovieObject.bdmv") && files.contains("index.bdmv")
      }
      return false
    }
    
    if isBDMVFolder(url) {
      return true
    }
    
    let bdmvFolder = url.appendingPathComponent("BDMV")
    guard bdmvFolder.isExistingDirectory else { return false }
    return isBDMVFolder(bdmvFolder)
  }

  /**
   Get called for all drag-and-drop enabled window/views in their `draggingEntered(_:)`.

   - Parameters:
     - sender: The `NSDraggingInfo` object received in `draggingEntered(_:)`.
     - isPlaylist: True when the caller is `PlaylistViewController`
   - Returns: The `NSDragOperation`.
   */
  func acceptFromPasteboard(_ sender: NSDraggingInfo, isPlaylist: Bool = false) -> NSDragOperation {
    // ignore events from this window
    // must check `mainWindow.loaded` otherwise window will be lazy-loaded unexpectedly
    if mainWindow.loaded && (sender.draggingSource as? NSView)?.window === mainWindow.window {
      return []
    }

    // get info
    let pb = sender.draggingPasteboard
    guard let types = pb.types else { return [] }

    if types.contains(.nsFilenames) {
      guard let paths = pb.propertyList(forType: .nsFilenames) as? [String] else { return [] }
      // The drag is answered from the names of the dragged paths alone, as the drop is, so that the main thread does not read the
      // filesystem: a path that is not a subtitle or playlist file may be a folder or a playable file.
      // check 3d lut files
      if paths.count == 1 && Utility.lut3dExt.contains(paths[0].lowercasedPathExtension) {
        return .copy
      }

      if isPlaylist {
        return paths.contains { !Utility.blacklistExt.contains($0.lowercasedPathExtension) } ? .copy : []
      }

      return canOpen(droppedPaths: paths) ? .copy : []
    } else if types.contains(.nsURL) {
      return .copy
    } else if let droppedString = pb.string(forType: .string) {
      return Regex.url.matches(droppedString) || Regex.filePath.matches(droppedString) ? .copy : []
    }
    return []
  }

  /// Whether any of the dropped paths can be opened, judged by its extension alone without reading any file: a path that is not a
  /// subtitle or multiple-file playlist file may be a folder or a playable file, a playlist file dropped alone is opened as a
  /// playlist, and a subtitle file is loaded when no playable file is found.
  func canOpen(droppedPaths paths: [String]) -> Bool {
    if paths.count == 1 && Utility.playlistFileExt.contains(paths[0].lowercasedPathExtension) {
      return true
    }
    return paths.contains { path in
      let ext = path.lowercasedPathExtension
      return !Utility.blacklistExt.contains(ext) || Utility.supportedFileExt[.sub]!.contains(ext)
    }
  }

  /**
   Get called for all drag-and-drop enabled window/views in their `performDragOperation(_:)`.

   - Parameters:
     - sender: The `NSDraggingInfo` object received in `performDragOperation(_:)`.
   - Returns: The result for `performDragOperation(_:)`.
   */
  func openFromPasteboard(_ sender: NSDraggingInfo, useGlobalOpenRouting: Bool = false) -> Bool {
    // get info
    let pb = sender.draggingPasteboard
    guard let types = pb.types else { return false }

    if types.contains(.nsFilenames) {
      guard let droppedPaths = pb.propertyList(forType: .nsFilenames) as? [String] else { return false }
      // A drop none of whose paths can be opened is refused, judged by their extensions alone so that the main thread does not
      // read the filesystem.
      guard canOpen(droppedPaths: droppedPaths) else { return false }
      // Resolving aliases, and making file URLs, which tells a folder from a file, read the filesystem, so they are done off the
      // main thread, then the files are opened on it.
      openQueue.async { [self] in
        let paths = Utility.resolvePaths(droppedPaths)
        let urls = paths.map { URL(fileURLWithPath: $0) }
        DispatchQueue.main.async { [self] in
          openDropped(paths: paths, urls: urls, useGlobalOpenRouting: useGlobalOpenRouting)
        }
      }
      // The files are found off the main thread, so whether any of them, or a subtitle file in their place, can be opened is not
      // known when the drop is answered. The drop is accepted.
      return true
    } else if types.contains(.nsURL) {
      guard let url = pb.propertyList(forType: .nsURL) as? [String] else { return false }
      openURLString(url[0])
      return true
    } else if let droppedString = pb.string(forType: .string) {
      if Regex.url.matches(droppedString) || Regex.filePath.matches(droppedString) {
        openURLString(droppedString)
        return true
      } else {
        Utility.showAlert("unsupported_url")
        return false
      }
    }
    return false
  }

  /// Open the dropped files, given by their paths with aliases resolved and by their file URLs: a 3D LUT file dropped alone is added
  /// as a video filter, and otherwise the files are opened, a subtitle file among them being loaded when none can be played.
  private func openDropped(paths: [String], urls: [URL], useGlobalOpenRouting: Bool) {
    // check 3d lut files
    if paths.count == 1 && Utility.lut3dExt.contains(paths[0].lowercasedPathExtension) {
      addVideoFilter(MPVFilter(lavfiName: "lut3d", label: "iina_quickl3d", paramDict: [
        "file": paths[0],
        "interp": "nearest"
        ])) { [self] added in
        if added {
          sendOSD(.addFilter("3D LUT"))
        }
      }
      return
    }

    // try open files
    let opened = { [self] (loadedFileCount: Int?) in
      guard let loadedFileCount else { return }
      if loadedFileCount == 0 {
        // if no playable files, try add subtitle files
        for url in urls {
          if !url.hasDirectoryPath && Utility.supportedFileExt[.sub]!.contains(url.pathExtension.lowercased()) {
            loadExternalSubFile(url)
          }
        }
      } else if loadedFileCount == 1 {
        // loaded one file
        info.shouldAutoLoadFiles = true
      } else {
        // add multiple files to playlist
        sendOSD(.addToPlaylist(loadedFileCount))
      }
    }
    if useGlobalOpenRouting {
      PlayerCore.openURLs(urls, completion: opened)
    } else {
      openURLs(urls, completion: opened)
    }
  }
}
