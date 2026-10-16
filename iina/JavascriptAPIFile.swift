//
//  JavascriptAPIFile.swift
//  iina
//
//  Created by Collider LI on 22/9/2020.
//  Copyright © 2020 lhc. All rights reserved.
//

import Foundation
import JavaScriptCore

@objc protocol JavascriptAPIFileExportable: JSExport {
  func list(_ path: String, _ options: [String: Any]) -> JSValue
  func exists(_ path: String) -> JSValue
  func write(_ path: String, _ content: String) -> JSValue
  func read(_ path: String, _ options: [String: Any]) -> JSValue
  func trash(_ path: String) -> JSValue
  func delete(_ path: String) -> JSValue
  func showInFinder(_ path: String)
  func handle(_ path: String, _ mode: String) -> JSValue
}

/// A file system error reported to the script, which rejects the promise of the request with `message`.
fileprivate struct FileFailure: Error {
  let message: String
}

/// A promise in `context` that runs `work` on `queue` and is settled on the main thread: resolved with what `answer` makes of the
/// value `work` returns, or with `undefined` when it returns `nil`, and rejected with the message of the `FileFailure` it throws.
fileprivate func fileRequest(in context: JSContext, on queue: DispatchQueue, _ work: @escaping () throws -> Any?,
                             answer: @escaping (Any, JSContext) -> Any = { value, _ in value }) -> JSValue {
  let executor: @convention(block) (JSValue, JSValue) -> Void = { resolve, reject in
    queue.async {
      let result = Result(catching: work)
      DispatchQueue.main.async {
        switch result {
        case .success(let value):
          resolve.call(withArguments: value.map { [answer($0, resolve.context)] } ?? [])
        case .failure(let error):
          let message = (error as? FileFailure)?.message ?? error.localizedDescription
          reject.call(withArguments: [JSValue(newErrorFromMessage: message, in: reject.context)!])
        }
      }
    }
  }
  return context.objectForKeyedSubscript("Promise")!.construct(withArguments: [JSValue(object: executor, in: context)!])
}

class JavascriptAPIFile: JavascriptAPI, JavascriptAPIFileExportable {
  /// The serial queue the plugin's files are read and written on, so that the script's thread does not wait for the file system,
  /// and the plugin's file requests are carried out in the order it made them.
  lazy var queue = DispatchQueue(label: "com.colliderli.iina.plugin.\(pluginInstance.plugin.identifier).file",
                                 qos: .userInitiated)

  /// A promise settled with the result of `work`, which runs on `queue`. A path is expanded, and a path the plugin may not use
  /// reported, on the script's thread before `work` is queued.
  private func request(_ work: @escaping () throws -> Any?) -> JSValue {
    return fileRequest(in: context, on: queue, work)
  }

  func exists(_ path: String) -> JSValue {
    guard let filePath = parsePath(path).path else { return request { false } }

    return request { FileManager.default.fileExists(atPath: filePath) }
  }

  func list(_ path: String, _ options: [String: Any]) -> JSValue {
    guard let dirPath = parsePath(path).path else { return request { nil } }

    var fmOptions: FileManager.DirectoryEnumerationOptions = []
    if !(options["includeSubDir"] as? Bool == true) {
      fmOptions.insert([
        .skipsPackageDescendants,
        .skipsSubdirectoryDescendants
      ])
    }

    return request {
      let dirURL = URL(fileURLWithPath: dirPath)
      let urls = try? FileManager.default.contentsOfDirectory(
        at: dirURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options:fmOptions
      )

      let pathPrefixCount = dirURL.path.count
      return urls?.map {
        [
          "filename": $0.lastPathComponent,
          "path": $0.path.dropFirst(pathPrefixCount),
          "isDir": $0.isExistingDirectory
        ] as [String: Any]
      }
    }
  }

  func write(_ path: String, _ content: String) -> JSValue {
    log("file.write \(path): \(content.count)", level: .debug)
    let (filePath_, local) = parsePath(path)
    guard let filePath = filePath_ else { return request { nil } }

    return request {
      if !local && FileManager.default.fileExists(atPath: filePath) {
        throw FileFailure(message: "Cannot overwrite existing file at \(path). Overwriting is only supported for @tmp and @data files.")
      }

      do {
        try content.write(toFile: filePath, atomically: true, encoding: .utf8)
      } catch let error {
        throw FileFailure(message: "Cannot write file: \(error.localizedDescription)")
      }
      return nil
    }
  }

  func read(_ path: String, _ options: [String: Any]) -> JSValue {
    guard let filePath = parsePath(path).path else { return request { nil } }

    var encoding = String.Encoding.utf8
    if let encodingString = options["encoding"] as? String {
      guard let enc = stringEncodingFromName(encodingString) else {
        throwError(withMessage: "Unknown encoding \"\(encodingString)\"")
        return JSValue(undefinedIn: context)
      }
      encoding = enc
    }

    return request {
      do {
        return try String(contentsOfFile: filePath, encoding: encoding)
      } catch let error {
        throw FileFailure(message: "Cannot read file: \(error.localizedDescription)")
      }
    }
  }

  func trash(_ path: String) -> JSValue {
    log("file.trash \(path)", level: .debug)
    guard let filePath = parsePath(path).path else { return request { nil } }

    return request {
      do {
        try FileManager.default.trashItem(at: URL(fileURLWithPath: filePath), resultingItemURL: nil)
      } catch let error {
        throw FileFailure(message: "Cannot trash file: \(error.localizedDescription)")
      }
      return nil
    }
  }

  func delete(_ path: String) -> JSValue {
    log("file.delete \(path)", level: .debug)
    let (filePath_, local) = parsePath(path)
    guard let filePath = filePath_ else { return request { nil } }

    guard local else {
      throwError(withMessage: "file.delete can only be called for @tmp and @data files.")
      return JSValue(undefinedIn: context)
    }
    return request {
      do {
        try FileManager.default.removeItem(atPath: filePath)
      } catch let error {
        throw FileFailure(message: "Cannot delete file: \(error.localizedDescription)")
      }
      return nil
    }
  }

  func move(_ source: String, _ dest: String) -> JSValue {
    log("file.move \(source) -> \(dest)", level: .debug)
    guard let sourcePath = parsePath(source).path, let destPath = parsePath(dest).path else { return request { nil } }

    return request {
      do {
        try FileManager.default.moveItem(atPath: sourcePath, toPath: destPath)
      } catch let error {
        throw FileFailure(message: "Cannot move file: \(error.localizedDescription)")
      }
      return nil
    }
  }

  func showInFinder(_ path: String) {
    guard let filePath = parsePath(path).path else { return }

    Utility.revealInFinder(filesAtPaths: [filePath])
  }

  func handle(_ path: String, _ mode: String) -> JSValue {
    guard let filePath = parsePath(path).path else { return request { nil } }

    let handleMode: JavascriptFileHandle.Mode
    switch mode {
    case "read":
      handleMode = .read
    case "write":
      handleMode = .write
    default:
      throwError(withMessage: "file.handle: mode should be \"read\" or \"write\".")
      return JSValue(undefinedIn: context)
    }
    let queue = self.queue
    return request {
      if let handle = JavascriptFileHandle(url: URL(fileURLWithPath: filePath), mode: handleMode, queue: queue) {
        return handle
      }
      throw FileFailure(message: "file.handle: cannot create file handle")
    }
  }
}


@objc protocol JavascriptFileHandleExportable: JSExport {
  func offset() -> JSValue
  func seekTo(_ offset: UInt64) -> JSValue
  func seekToEnd() -> JSValue
  func read(_ length: Int) -> JSValue
  func readToEnd() -> JSValue
  func write(_ data: JSValue) -> JSValue
  func close() -> JSValue
}

class JavascriptFileHandle: NSObject, JavascriptFileHandleExportable {
  enum Mode {
    case read, write
  }

  private var handle: FileHandle
  private var mode: Mode
  /// The queue of the file API that opened the handle, which the handle is moved, read, written and closed on, after the plugin's
  /// file requests made before.
  private let queue: DispatchQueue

  init?(url: URL, mode: Mode, queue: DispatchQueue) {
    do {
      self.handle = mode == .read ? try FileHandle(forReadingFrom: url) : try FileHandle(forWritingTo: url)
      self.mode = mode
      self.queue = queue
    } catch {
      return nil
    }
  }

  /// A promise settled with the result of `work`, which runs on `queue`, made in the context of the script calling the handle.
  private func request(_ work: @escaping () throws -> Any?,
                       answer: @escaping (Any, JSContext) -> Any = { value, _ in value }) -> JSValue {
    return fileRequest(in: JSContext.current()!, on: queue, work, answer: answer)
  }

  /// The bytes read from the handle, as a `Uint8Array` in `context`.
  private static func bytes(_ data: Any, in context: JSContext) -> Any {
    return createUInt8Array(fromData: data as! Data, in: context) ?? JSValue(undefinedIn: context)!
  }

  func offset() -> JSValue {
    return request { self.handle.offsetInFile }
  }

  func seekTo(_ offset: UInt64) -> JSValue {
    return request {
      self.handle.seek(toFileOffset: offset)
      return nil
    }
  }

  func seekToEnd() -> JSValue {
    return request {
      self.handle.seekToEndOfFile()
      return nil
    }
  }

  func read(_ length: Int) -> JSValue {
    guard mode == .read else {
      return request { nil }
    }
    return request({ self.handle.readData(ofLength: length) }, answer: Self.bytes)
  }

  func readToEnd() -> JSValue {
    guard mode == .read else {
      return request { nil }
    }
    return request({ self.handle.readDataToEndOfFile() }, answer: Self.bytes)
  }

  func write(_ data: JSValue) -> JSValue {
    if data.isString {
      guard let utf8Data = data.toString()!.data(using: .utf8) else { return request { nil } }
      return request {
        self.handle.write(utf8Data)
        return nil
      }
    }

    let context = JSContext.current()!
    var buffer: [UInt8] = []
    let setter: @convention(block) (UInt8) -> Void = { value in
      buffer.append(value)
    }
    context.setObject(setter, forKeyedSubscript: "__iina_data_setter" as NSString)
    context.setObject(data, forKeyedSubscript: "__iina_data_value" as NSString)
    context.evaluateScript("""
    for (value of __iina_data_value) {
      __iina_data_setter(value);
    }
    """)
    context.setObject(nil, forKeyedSubscript: "__iina_data_setter" as NSString)
    context.setObject(nil, forKeyedSubscript: "__iina_data_value" as NSString)

    let bytes = Data(buffer)
    return request {
      self.handle.write(bytes)
      return nil
    }
  }

  func close() -> JSValue {
    return request {
      self.handle.closeFile()
      return nil
    }
  }
}
