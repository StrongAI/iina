//
//  JavascriptAPIUtils.swift
//  iina
//
//  Created by Collider LI on 2/3/2019.
//  Copyright © 2019 lhc. All rights reserved.
//

import Foundation
import JavaScriptCore

fileprivate func searchBinary(_ file: String, in url: URL) -> URL? {
  let url = url.appendingPathComponent(file)
  return FileManager.default.fileExists(atPath: url.path) ? url : nil
}

fileprivate extension Process {
  var descriptionDict: [String: Any] {
    return [
      "status": terminationStatus
    ]
  }
}

@objc protocol JavascriptAPIUtilsExportable: JSExport {
  func fileInPath(_ file: String) -> JSValue
  func resolvePath(_ path: String) -> String?
  func exec(_ file: String, _ args_: Any, _ cwd: JSValue?, _ stdoutHook_: JSValue?, _ stderrHook_: JSValue?) -> JSValue?
  func ask(_ title: String) -> Bool
  func prompt(_ title: String) -> String?
  func chooseFile(_ title: String, _ options: [String: Any]) -> Any
  func keychainWrite(_ service: String, _ name: String, _ password: String) -> JSValue
  func keychainRead(_ service: String, _ name: String) -> JSValue
  func open(_ url: String) -> Bool
  func preferredLocalizations() -> Any
}

class JavascriptAPIUtils: JavascriptAPI, JavascriptAPIUtilsExportable {
  func keychainWrite(_ service: String, _ name: String, _ password: String) -> JSValue {
    let serviceName = "\(pluginInstance.plugin.identifier) - \(service)"
    return createPromise { resolve, _ in
      if service.isEmpty {
        resolve.call(withArguments: [false])
        return
      }
      // The Keychain is written on its queue, so that the script's thread does not wait for securityd or for a Keychain access
      // prompt. The promise is settled on the main thread.
      KeychainAccess.queue.async {
        let written: Bool
        do {
          try KeychainAccess.write(username: name, password: password, forService: .init(serviceName))
          written = true
        } catch {
          written = false
        }
        DispatchQueue.main.async { resolve.call(withArguments: [written]) }
      }
    }
  }
  
  func keychainRead(_ service: String, _ name: String) -> JSValue {
    let serviceName = "\(pluginInstance.plugin.identifier) - \(service)"
    return createPromise { resolve, _ in
      if service.isEmpty {
        resolve.call(withArguments: [false])
        return
      }
      // The Keychain is read on its queue, so that the script's thread does not wait for securityd or for a Keychain access
      // prompt. The promise is settled on the main thread.
      KeychainAccess.queue.async {
        let result: Any
        do {
          result = try KeychainAccess.read(username: name, forService: .init(serviceName)).password
        } catch {
          result = false
        }
        DispatchQueue.main.async { resolve.call(withArguments: [result]) }
      }
    }
  }
  
  override func extraSetup() {
    context.evaluateScript("""
    iina.utils.ERROR_BINARY_NOT_FOUND = -1;
    iina.utils.ERROR_RUNTIME = -2;
    """)
  }

  func fileInPath(_ file: String) -> JSValue {
    guard permitted(to: .accessFileSystem), !file.isEmpty else {
      return createPromise { resolve, _ in resolve.call(withArguments: [false]) }
    }
    let path = parsePath(file, forceLocalPath: false).path
    return createPromise { [unowned self] resolve, _ in
      // The binary is looked for on the plugin's queue, as exec looks for it, so that the script's thread does not wait for the
      // file system. The promise is settled on the main thread.
      self.pluginInstance.queue.async {
        let found = searchBinary(file, in: Utility.binariesURL) != nil || searchBinary(file, in: Utility.exeDirURL) != nil
          || path.map { FileManager.default.fileExists(atPath: $0) } ?? false
        DispatchQueue.main.async { resolve.call(withArguments: [found]) }
      }
    }
  }

  func resolvePath(_ path: String) -> String? {
    guard permitted(to: .accessFileSystem) else {
      return nil
    }
    return parsePath(path).path
  }

  func exec(_ file: String, _ args_: Any, _ cwd: JSValue?, _ stdoutHook_: JSValue?, _ stderrHook_: JSValue?) -> JSValue? {
    guard permitted(to: .accessFileSystem) else {
      return nil
    }
    
    guard let args = args_ as? [String] else {
      throwError(withMessage: "The exec args parameter must be a string array")
      return nil
    }

    return createPromise { [unowned self] resolve, reject in
      // The paths are expanded, and the plugin's folders and log subsystem read, on the script's thread, which they belong to.
      // A named path that is not absolute is expanded here, so that it can report an invalid path to the script.
      let namedPath: String? = file.contains("/") ? (file.first == "/" ? file : parsePath(file).path ?? "") : nil
      var cwdPath: String?
      if let cwd, cwd.isString {
        cwdPath = parsePath(cwd.toString()).path
      }
      let plugin = self.pluginInstance.plugin!
      let pluginFolders = [plugin.dataFolderURL.path, plugin.tmpFolderURL.path]
      let subsystem = self.pluginInstance.subsystem
      var stdoutHook: JSValue?
      var stderrHook: JSValue?
      if let hookVal = stdoutHook_, hookVal.isObject {
        stdoutHook = hookVal
      }
      if let hookVal = stderrHook_, hookVal.isObject {
        stderrHook = hookVal
      }

      // The binary is looked up, its permission fixed and its process started on the plugin's queue, so that the script's thread does
      // not wait for the file system or for the process to be spawned. The promise is settled on the main thread.
      self.pluginInstance.queue.async {
        var path = ""
        var args = args
        if let namedPath {
          // it should be an existing file
          path = namedPath
          // make sure the file exists
          guard FileManager.default.fileExists(atPath: path) else {
            DispatchQueue.main.async { reject.call(withArguments: [-1, "Cannot find the binary \(file)"]) }
            return
          }
        } else {
          if let url = searchBinary(file, in: Utility.binariesURL) ?? searchBinary(file, in: Utility.exeDirURL) {
            // a binary included in IINA's bundle?
            if #available(macOS 13.0, *) {
              path = url.path(percentEncoded: false)
            } else {
              path = url.path
            }
          } else {
            // assume it's a system command
            args.insert(file, at: 0)
          }
        }

        // If this binary belongs to the plugin but doesn't have exec permission, try fix it
        if !FileManager.default.isExecutableFile(atPath: path) && pluginFolders.contains(where: { path.hasPrefix($0) }) {
          do {
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(integerLiteral: 0o755)], ofItemAtPath: path)
          } catch {
            DispatchQueue.main.async {
              reject.call(withArguments: [-2, "The binary is not executable, and execute permission cannot be added"])
            }
            return
          }
        }

        let (stdout, stderr) = (Pipe(), Pipe())
        let process = Process()
        process.environment = ["LC_ALL": "en_US.UTF-8"]
        process.launchPath = path
        process.arguments = args
        if let cwdPath {
          process.currentDirectoryPath = cwdPath
        }
        process.standardOutput = stdout
        process.standardError = stderr

        var stdoutContent = ""
        var stderrContent = ""

        // An empty read means EOF. The handlers are also cleared after the process
        // exits, but that runs on pluginInstance.queue, which a long-running exec
        // can block, and until then the handler would keep firing on a spinning CPU.
        stdout.fileHandleForReading.readabilityHandler = { file in
          let data = file.availableData
          guard !data.isEmpty else {
            file.readabilityHandler = nil
            return
          }
          guard let output = String(data: data, encoding: .utf8) else { return }
          stdoutContent += output
          stdoutHook?.call(withArguments: [output])
        }
        stderr.fileHandleForReading.readabilityHandler = { file in
          let data = file.availableData
          guard !data.isEmpty else {
            file.readabilityHandler = nil
            return
          }
          guard let output = String(data: data, encoding: .utf8) else { return }
          stderrContent += output
          stderrHook?.call(withArguments: [output])
        }
        Logger.log("Executing \(path) \(args.joined(separator: " "))", subsystem: subsystem)
        do {
          try process.run()
        } catch {
          DispatchQueue.main.async { reject.call(withArguments: ["Execution failed reporting: \(error.localizedDescription)"]) }
          return
        }

        process.waitUntilExit()
        stderr.fileHandleForReading.readabilityHandler = nil
        stdout.fileHandleForReading.readabilityHandler = nil
        DispatchQueue.main.async {
          resolve.call(withArguments: [[
            "status": process.terminationStatus,
            "stdout": stdoutContent,
            "stderr": stderrContent
          ] as [String: Any]])
        }
      }
    }
  }

  func ask(_ title: String) -> Bool {
    let panel = NSAlert()
    panel.messageText = title
    panel.addButton(withTitle: NSLocalizedString("general.ok", comment: "OK"))
    panel.addButton(withTitle: NSLocalizedString("general.cancel", comment: "Cancel"))
    return panel.runModal() == .alertFirstButtonReturn
  }

  func prompt(_ title: String) -> String? {
    let panel = NSAlert()
    panel.messageText = title
    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 60))
    input.lineBreakMode = .byWordWrapping
    input.usesSingleLineMode = false
    panel.accessoryView = input
    panel.addButton(withTitle: NSLocalizedString("general.ok", comment: "OK"))
    panel.addButton(withTitle: NSLocalizedString("general.cancel", comment: "Cancel"))
    panel.window.initialFirstResponder = input
    if panel.runModal() == .alertFirstButtonReturn {
      return input.stringValue
    }
    return nil
  }

  func chooseFile(_ title: String, _ options: [String: Any]) -> Any {
    let chooseDir = options["chooseDir"] as? Bool ?? false
    let allowedFileTypes = options["allowedFileTypes"] as? [String]
    return createPromise { resolve, reject in
      Utility.quickOpenPanel(title: title, chooseDir: chooseDir, allowedFileTypes: allowedFileTypes) { result in
        resolve.call(withArguments: [result.path])
      }
    }
  }

  func open(_ url: String) -> Bool {
    // always open web links
    if let url = URL(string: url) {
      if url.scheme == "https" || url.scheme == "http" {
        Utility.open(url)
        return true
      }
    }
    // might be a file path
    let (path, isLocal) = parsePath(url)
    guard let path else {
      log("utils.open: path cannot be found", level: .error)
      return false
    }
    if isLocal {
      Utility.open(fileAtPath: path)
      return true
    }
    return whenPermitted(to: .accessFileSystem) {
      Utility.open(fileAtPath: path)
      return true
    } ?? false
  }

  func preferredLocalizations() -> Any {
    return Bundle.main.preferredLocalizations
  }
}
