//
//  JavascriptPlugin.swift
//  iina
//
//  Created by Collider LI on 11/9/2018.
//  Copyright © 2018 lhc. All rights reserved.
//

import Foundation
import JavaScriptCore
import Just

fileprivate let githubRepoRegex = Regex("^[\\w-]+/[\\w-]+$")
fileprivate let idRegex = Regex("^([\\w-_]+\\.)+[\\w-_]+$")

class JavascriptPlugin: NSObject {
  enum Permission: String {
    case networkRequest = "network-request"
    case showOSD = "show-osd"
    case showAlert = "show-alert"
    case displayVideoOverlay = "video-overlay"
    case accessFileSystem = "file-system"

    var isDangerous: Bool {
      switch self {
      case .networkRequest, .accessFileSystem:
        return true
      default:
        return false
      }
    }
  }

  enum PluginError: Error {
    case fileNotFound(String)
    case cannotUnpackage(String, String)
    case invalidURL(String)
    case cannotDownload(String, String)
    case cannotLoadPlugin
  }

  static var hasYTDL: Bool {
    return plugins.contains { $0.enabled && $0.identifier == "io.iina.ytdl" }
  }

  /// The installed plugins, in the order the user put them in, read from the plugins folder by `loadPlugins(then:)` and empty until
  /// then. Read and set on the main thread.
  static var plugins: [JavascriptPlugin] = [] {
    didSet {
      NotificationCenter.default.post(Notification(name: .iinaPluginChanged))
    }
  }

  /// Whether the plugins folder has been read into `plugins`.
  private static var pluginsLoaded = false

  /// The callers to tell on the main thread once the plugins folder being read has been read, `nil` while it is not being read.
  private static var whenPluginsLoaded: [() -> Void]?

  var globalInstance: JavascriptPluginInstance?

  @objc var enabled: Bool {
    didSet {
      UserDefaults.standard.set(enabled, forKey: "PluginEnabled." + identifier)
      guard enabled else {
        removeSubProviders()
        reloadInstances()
        return
      }
      registerSubProviders()
      // The instances of the plugin read its entry scripts, which are read on the install queue first, so that the main thread does
      // not wait for the file system. The instances are made on the main thread once they are read, unless the plugin has been
      // disabled meanwhile.
      let urls = [entryURL, globalEntryURL].compactMap { $0 }
      JavascriptPlugin.installQueue.async { [self] in
        let scripts = urls.reduce(into: [URL: String]()) { $0[$1] = try? String(contentsOf: $1) }
        DispatchQueue.main.async { [self] in
          guard enabled else { return }
          entryScripts = scripts
          reloadInstances()
          // Instances made from here on read their entry scripts from the files.
          entryScripts = [:]
        }
      }
    }
  }

  /// Make or release the instances of the plugin, globally and in every player, as `enabled` asks, and tell the windows.
  private func reloadInstances() {
    reloadGlobalInstance()
    PlayerCore.reloadPluginForAll(self)
    NotificationCenter.default.post(Notification(name: .iinaPluginChanged))
  }

  let name: String
  let authorName: String
  let authorEmail: String?
  let authorURL: String?
  var identifier: String
  let version: String
  let desc: String?
  /// The plugin is a symlink of an external folder, mainly by the CLI
  var isExternal: Bool = false

  var root: URL
  let entryPath: String
  let globalEntryPath: String?
  let preferencesPage: String?
  let helpPage: String?

  let githubRepo: String?
  let githubVersion: Int?

  let permissions: Set<Permission>
  let domainList: [String]

  var subProviders: [[String: String]]?
  let sidebarTabName: String?

  var entryURL: URL
  var globalEntryURL: URL?
  var preferencesPageURL: URL?
  var helpPageURL: URL?
  var githubURLString: String? {
    guard let githubRepo else { return nil }
    return "https://github.com/\(githubRepo)"
  }

  var supportAutoUpdate: Bool { githubRepo == nil || githubVersion == nil }

  /// The queue the plugins' preferences files are read on, so that the main thread does not wait for the file system.
  static let preferencesQueue = DispatchQueue(label: "com.colliderli.iina.plugin.preferences", qos: .userInitiated)

  /// The plugin's preferences, read from its preferences file by `loadPreferences(then:)` and empty until then, with the values set
  /// since. Read and set on the main thread once `loadPreferences(then:)` has called back.
  var preferences: [String: Any] = [:]

  /// Whether the preferences file has been read into `preferences`.
  private var preferencesLoaded = false

  /// The callers to tell on the main thread once the preferences file being read has been read, `nil` while it is not being read.
  private var whenPreferencesLoaded: [() -> Void]?

  /// Read the preferences file on `preferencesQueue` unless it has been read, then call `completion` on the main thread once it has
  /// been, after the completions asked for before it.
  func loadPreferences(then completion: @escaping () -> Void) {
    guard !preferencesLoaded else {
      DispatchQueue.main.async(execute: completion)
      return
    }
    guard whenPreferencesLoaded == nil else {
      whenPreferencesLoaded?.append(completion)
      return
    }
    whenPreferencesLoaded = [completion]
    JavascriptPlugin.preferencesQueue.async { [self] in
      let read = NSDictionary(contentsOfFile: preferencesFileURL.path) as? [String: Any] ?? [:]
      DispatchQueue.main.async { [self] in
        preferences = read
        preferencesLoaded = true
        let completions = whenPreferencesLoaded ?? []
        whenPreferencesLoaded = nil
        completions.forEach { $0() }
      }
    }
  }
  let defaultPreferences: [String: Any]

  /// Read the plugins folder into `plugins` unless it has been read, then call `completion` on the main thread once it has been, after
  /// the completions asked for before it.
  static func loadPlugins(then completion: @escaping () -> Void) {
    guard !pluginsLoaded else {
      DispatchQueue.main.async(execute: completion)
      return
    }
    guard whenPluginsLoaded == nil else {
      whenPluginsLoaded?.append(completion)
      return
    }
    whenPluginsLoaded = [completion]
    readPlugins { read in
      plugins = read
      pluginsLoaded = true
      let completions = whenPluginsLoaded ?? []
      whenPluginsLoaded = nil
      completions.forEach { $0() }
    }
  }

  /// Read the plugins folder again, replacing `plugins` with the plugins read, then call `completion` on the main thread.
  static func recreateAllPlugins(then completion: @escaping () -> Void) {
    readPlugins { read in
      plugins = read
      pluginsLoaded = true
      completion()
    }
  }

  /// Read the plugins in the plugins folder on `installQueue`, so that the main thread does not wait for the file system, then hand
  /// them to `completion` on the main thread in the order the user put them in, a plugin whose identifier an earlier one has given a
  /// new one and the user told.
  static private func readPlugins(then completion: @escaping ([JavascriptPlugin]) -> Void) {
    guard IINA_ENABLE_PLUGIN_SYSTEM else {
      DispatchQueue.main.async { completion([]) }
      return
    }

    installQueue.async {
      guard let contents = try?
        FileManager.default.contentsOfDirectory(at: Utility.pluginsURL,
                                                includingPropertiesForKeys: [.isDirectoryKey],
                                                options: [.skipsHiddenFiles, .skipsPackageDescendants])
      else {
        Logger.log("Unable to read plugin directory.")
        DispatchQueue.main.async { completion([]) }
        return
      }

      let read = contents
        .filter {
          ($0.pathExtension == "iinaplugin" && $0.isExistingDirectory) ||
            ($0.pathExtension == "iinaplugin-dev")
        }
        .compactMap { path_ -> JavascriptPlugin? in
          let isDev = path_.pathExtension == "iinaplugin-dev"
          let path = isDev ? path_.resolvingSymlinksInPath() : path_
          return JavascriptPlugin(filename: path.lastPathComponent, externalURL: isDev ? path : nil)
        }

      // The alert is shown on the main thread.
      DispatchQueue.main.async {
        let orderArray = UserDefaults.standard.array(forKey: "PluginOrder") as? [String] ?? []
        let order = Array(NSOrderedSet(array: orderArray)) as! [String]
        let orderDict = [String: Int](uniqueKeysWithValues: zip(order, 0...order.count))
        var identifiers = Set<String>()

        for plugin in read {
          if identifiers.contains(plugin.identifier) {
            Utility.showAlert("duplicated_plugin_id", comment: nil, arguments: [plugin.identifier])
            plugin.identifier += ".\(UUID().uuidString)"
          }
          identifiers.insert(plugin.identifier)
        }

        let result = read.sorted { orderDict[$0.identifier, default: Int.max] < orderDict[$1.identifier, default: Int.max] }
        savePluginOrder(result)
        completion(result)
      }
    }
  }

  static func loadGlobalInstances() {
    plugins.forEach { plugin in
      guard plugin.enabled else { return }
      if plugin.globalEntryPath != nil {
        plugin.globalInstance = .init(player: nil, plugin: plugin)
      }
    }
  }

  func reloadGlobalInstance(forced: Bool = false) {
    guard globalEntryPath != nil else { return }

    if globalInstance == nil {
      guard enabled else { return }
      globalInstance = .init(player: nil, plugin: self)
    } else {
      if enabled {
        // no need to reload, unless forced
        guard forced else { return }
        globalInstance = .init(player: nil, plugin: self)
      } else {
        globalInstance = nil
      }
    }
  }

  static func savePluginOrder(_ values: [JavascriptPlugin]? = nil) {
    UserDefaults.standard.set((values ?? plugins).map({ $0.identifier }), forKey: "PluginOrder")
  }

  /// The serial queue plugins are downloaded, unpacked, read and moved on, so that the main thread does not wait for the network,
  /// for the processes that unpack them or for the file system.
  static let installQueue = DispatchQueue(label: "IINAPluginInstall", qos: .userInitiated)

  /// Run `work` on `installQueue` and hand back what it returns or throws.
  static func onInstallQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      installQueue.async { continuation.resume(with: Result { try work() }) }
    }
  }

  /// Makes each HTTP GET request of finding, downloading and updating a plugin on GitHub, waiting for its answer. It exists so that
  /// tests can answer the requests in its place, without the network.
  static var getFromGitHub: (String) -> HTTPResult = { Just.get($0) }

  @discardableResult
  static func create(fromPackageURL url: URL) throws -> JavascriptPlugin {
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw PluginError.fileNotFound(url.path)
    }

    Logger.log("Installing plugin from file: \(url.path)", level: .debug)

    let pluginsRoot = Utility.pluginsURL
    let tempFolder = ".temp.\(UUID().uuidString)"
    let tempZipFile = "\(tempFolder).zip"
    let tempDecompressDir = "\(tempFolder)-1"

    defer {
      [tempZipFile, tempDecompressDir].forEach { item in
        try? FileManager.default.removeItem(at: pluginsRoot.appendingPathComponent(item))
      }
    }

    func removeTempPluginFolder() {
      try? FileManager.default.removeItem(at: pluginsRoot.appendingPathComponent(tempFolder))
    }

    let cmd = [
      "cp '\(url.path)' '\(tempZipFile)'",
      "mkdir '\(tempFolder)' '\(tempDecompressDir)'",
      "unzip '\(tempZipFile)' -d '\(tempDecompressDir)'",
      "mv '\(tempDecompressDir)'/* '\(tempFolder)'/"
    ].joined(separator: " && ")
    let (process, stdout, stderr) = Process.run(["/bin/sh", "-c", cmd], at: pluginsRoot)

    guard process.terminationStatus == 0 else {
      let outText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "None"
      let errText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "None"
      removeTempPluginFolder()
      throw PluginError.cannotUnpackage(outText, errText)
    }

    guard let plugin = JavascriptPlugin(filename: tempFolder) else {
      removeTempPluginFolder()
      throw PluginError.cannotLoadPlugin
    }
    return plugin
  }

  @discardableResult
  static func standardizeGithubURL(_ urlString: String) throws -> URL {
    var formatted: String
    if githubRepoRegex.matches(urlString) {
      formatted = "https://github.com/\(urlString)"
    } else {
      guard Regex("^https://github.com/[\\w-]+/[\\w-]+/?$").matches(urlString) else {
        throw PluginError.invalidURL(urlString)
      }
      formatted = urlString
    }

    guard let url = NSURL(string: formatted)?.standardized else {
      throw PluginError.invalidURL(formatted)
    }
    return url
  }

  @discardableResult
  static func create(fromGitURL urlString: String) throws -> JavascriptPlugin {
    let url = try standardizeGithubURL(urlString)

    Logger.log("Installing plugin from GitHub URL: \(url)", level: .debug)

    let pluginsRoot = Utility.pluginsURL
    let tempFolder = ".temp.\(UUID().uuidString)"
    let tempZipFile = "\(tempFolder).zip"
    let tempDecompressDir = "\(tempFolder)-1"
    let githubMasterURL = url.appendingPathComponent("archive/main.zip").absoluteString

    defer {
      [tempZipFile, tempDecompressDir].forEach { item in
        try? FileManager.default.removeItem(at: pluginsRoot.appendingPathComponent(item))
      }
    }
    
    // If there is a iinaplgz file inside the latest release, use the plgz file
    
    let response = getFromGitHub("https://api.github.com/repos\(url.path)/releases/latest")

    if response.ok,
       let json = response.json as? [String: Any],
       let assets = json["assets"] as? [[String: Any]],
       let plgzItem = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".iinaplgz") ?? false }),
       let dlURL = plgzItem["browser_download_url"] as? String
    {
      do {
        let plgzName = plgzItem["name"] as! String
        let destURL = Utility.tempDirURL.appendingPathComponent(plgzName)
        let downloadResponse = getFromGitHub(dlURL)
        try downloadResponse.content?.write(to: destURL)
        return try create(fromPackageURL: destURL)
      } catch {
        Logger.log("Cannot find an iinaplgz file in the latest release", level: .debug)
      }
    }
    
    // Otherwise, install from source
    Logger.log("Installing from source", level: .debug)

    func removeTempPluginFolder() {
      try? FileManager.default.removeItem(at: pluginsRoot.appendingPathComponent(tempFolder))
    }

    let cmd = [
      "curl -fsSL '\(githubMasterURL)' > '\(tempZipFile)'",
      "mkdir '\(tempFolder)' '\(tempDecompressDir)'",
      "unzip '\(tempZipFile)' -d '\(tempDecompressDir)'",
      "mv '\(tempDecompressDir)'/*/* '\(tempFolder)'/"
    ].joined(separator: " && ")
    let (process, stdout, stderr) = Process.run(["/bin/sh", "-c", cmd], at: pluginsRoot)

    guard process.terminationStatus == 0 else {
      let outText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "None"
      let errText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "None"
      removeTempPluginFolder()
      throw PluginError.cannotDownload(outText, errText)
    }

    guard let plugin = JavascriptPlugin(filename: tempFolder) else {
      removeTempPluginFolder()
      throw PluginError.cannotLoadPlugin
    }

    if plugin.githubVersion == nil || plugin.githubURLString == nil {
      Logger.log("The plugin \(plugin.name) doesn't contain a ghVersion field or its ghRepo doesn't match the current requested URL \(url.absoluteString).", level: .warning)
    }
    return plugin
  }

  init?(filename: String, externalURL: URL? = nil) {
    // find package
    let url = externalURL ?? Utility.pluginsURL.appendingPathComponent(filename)
    Logger.log("Loading JS plugin from \(url.path)")
    guard url.isFileURL && url.isExistingDirectory else {
      Logger.log("The plugin package doesn't exist.")
      return nil
    }

    // read package
    guard
      let data = try? Data(contentsOf: url.appendingPathComponent("Info.json"), options: .mappedIfSafe),
      let jsonResult = try? JSONSerialization.jsonObject(with: data, options: .mutableLeaves),
      let jsonDict = jsonResult as? [String: Any]
      else {
      Logger.log("Cannot read plugin package content.", level: .error)
      return nil
    }

    // read json
    guard
      let name = jsonDict["name"] as? String,
      let author = jsonDict["author"] as? [String: String],
      let authorName = author["name"],
      let identifier = jsonDict["identifier"] as? String,
      let version = jsonDict["version"] as? String,
      let entry = jsonDict["entry"] as? String
      else {
      Logger.log("Info.json must contain these keys: name, author, identifier, version and entry.", level: .error)
      return nil
    }

    guard idRegex.matches(identifier) else {
      Logger.log("Plugin ID \"\(identifier)\"should comply with the Reverse domain name notation", level: .error)
      return nil
    }

    self.root = url

    // e.g. "localized": { "fr": { "name": ..., "description": ..., "sidebarTab": { "name": ... } } }
    let l10nDict = jsonDict["localized"] as? [String: [String: Any]] ?? [:]
    // Also search for "en" (we assume Info.json is in English; won't cause big problem if it's not).
    let preferredLang = Bundle.preferredLocalizations(from: ["en"] + Array(l10nDict.keys)).first
    let preferredL10n: [String: Any]? = preferredLang.flatMap { l10nDict[$0] }

    func l10n(_ key: String, fallback: String?) -> String? {
      if let preferredL10n, let value = preferredL10n[key] as? String {
        return value
      }
      return fallback
    }

    func l10nNested(_ key: String, _ subKey: String, fallback: String?) -> String? {
      if let preferredL10n, let value = (preferredL10n[key] as? [String: Any])?[subKey] as? String {
        return value
      }
      return fallback
    }

    self.name = l10n("name", fallback: name) ?? name
    self.version = version
    self.entryPath = entry
    self.globalEntryPath = jsonDict["globalEntry"] as? String
    self.authorName = authorName
    self.authorURL = author["url"]
    self.authorEmail = author["email"]
    self.identifier = identifier
    self.desc = l10n("description", fallback: jsonDict["description"] as? String)
    self.preferencesPage = jsonDict["preferencesPage"] as? String
    self.helpPage = jsonDict["helpPage"] as? String
    self.domainList = (jsonDict["allowedDomains"] as? [String]) ?? []
    self.subProviders = jsonDict["subtitleProviders"] as? [[String: String]]

    if externalURL != nil {
      self.isExternal = true
    }

    if let sidebarTabDef = jsonDict["sidebarTab"] as? [String: String] {
      self.sidebarTabName = l10nNested("sidebarTab", "name", fallback: sidebarTabDef["name"])
    } else {
      self.sidebarTabName = nil
    }

    self.enabled = UserDefaults.standard.bool(forKey: "PluginEnabled." + identifier)

    if let ghRepo = jsonDict["ghRepo"] as? String {
      if githubRepoRegex.matches(ghRepo) {
        self.githubRepo = ghRepo
      } else {
        Logger.log("Invalid ghRepo format", level: .error)
        return nil
      }
    } else {
      self.githubRepo = nil
    }
    self.githubVersion = jsonDict["ghVersion"] as? Int

    var permissions = Set<Permission>()
    if let permList = jsonDict["permissions"] as? [String] {
      permList.forEach {
        if let p = Permission(rawValue: $0) {
          permissions.insert(p)
        } else {
          Logger.log("Unknown permission: \($0)", level: .warning)
        }
      }
    }
    self.permissions = permissions

    guard let entryURL = resolvePath(entryPath, root: root) else {
      Logger.log("The entry file \(entryPath) doesn't exist", level: .error)
      return nil
    }
    self.entryURL = entryURL
    
    if let globalEntryPath {
      guard let globalEntryURL = resolvePath(globalEntryPath, root: root) else {
        Logger.log("The entry file \(globalEntryPath) doesn't exist", level: .error)
        return nil
      }
      self.globalEntryURL = globalEntryURL
    }
    
    self.preferencesPageURL = resolvePath(preferencesPage, root: root)
    self.helpPageURL = resolvePath(helpPage, root: root, allowNetwork: true)

    if let defaultPreferences = jsonDict["preferenceDefaults"] as? [String: Any] {
      self.defaultPreferences = defaultPreferences
    } else {
      Logger.log("Unable to read preferenceDefaults", level: .warning)
      self.defaultPreferences = [:]
    }

    super.init()

    if (enabled) {
      // A plugin is made on `installQueue` when it is installed or updated, while the subtitle providers are registered on the main
      // thread, where they are read.
      if Thread.isMainThread {
        registerSubProviders()
      } else {
        DispatchQueue.main.async { self.registerSubProviders() }
      }
    }
    Logger.log("Loaded JS plugin: \(name) \(version)\(enabled ? "" : " (disabled)")")
  }

  func registerSubProviders() {
    guard let subProviders else { return }
    for provider in subProviders {
      guard let spID = provider["id"], let spName = provider["name"] else {
        Logger.log("A subtitle provider declaration should have an id and a name.", level: .error)
        continue
      }
      OnlineSubtitle.Providers.registerFromPlugin(identifier, name, id: spID, name: spName)
    }
  }

  func removeSubProviders() {
    OnlineSubtitle.Providers.removeAllFromPlugin(identifier)
  }

  func normalizePath() {
    let pluginsURL = Utility.pluginsURL
    let fileManager = FileManager.default

    var dest = pluginsURL.appendingPathComponent("\(identifier).iinaplugin")
    if fileManager.fileExists(atPath: dest.path) {
      for i in 2..<Int.max {
        dest = pluginsURL.appendingPathComponent("\(identifier)-\(i).iinaplugin")
        if !fileManager.fileExists(atPath: dest.path) { break }
      }
    }

    do {
      try fileManager.moveItem(at: self.root, to: dest)
      self.root = dest
      self.entryURL = resolvePath(entryPath, root: root)!
      if let globalEntryPath {
        self.globalEntryURL = resolvePath(globalEntryPath, root: root)!
      }
      self.preferencesPageURL = resolvePath(preferencesPage, root: root)
      self.helpPageURL = resolvePath(helpPage, root: root, allowNetwork: true)
    } catch let error {
      // The plugin is moved on `installQueue` when it is updated, while the alert is shown on the main thread.
      if Thread.isMainThread {
        Utility.showAlert(error.localizedDescription)
      } else {
        DispatchQueue.main.async { Utility.showAlert(error.localizedDescription) }
      }
    }
  }

  /// The entry scripts read on `installQueue` for the instances made once the plugin is updated, by the URL of each script. An
  /// instance whose entry script is not here reads it from its file.
  var entryScripts: [URL: String] = [:]

  /// Read the entry scripts of the plugin into `entryScripts`.
  func readEntryScripts() {
    for url in [entryURL, globalEntryURL].compactMap({ $0 }) {
      entryScripts[url] = try? String(contentsOf: url)
    }
  }

  @discardableResult
  func remove() -> Int? {
    let pos = JavascriptPlugin.plugins.firstIndex(of: self)
    if let pos {
      JavascriptPlugin.plugins.remove(at: pos)
    }
    // The files are removed on the install queue, so that the main thread does not wait for the file system, and before any plugin
    // is moved into the plugins folder after this.
    let root = root
    JavascriptPlugin.installQueue.async { try? FileManager.default.removeItem(at: root) }
    return pos
  }

  func checkNewVersion() async throws -> String? {
    try await withCheckedThrowingContinuation { continuation in
      guard let ghVersion = githubVersion, let ghRepo = githubRepo else {
        continuation.resume(returning: nil)
        return
      }
      // The request waits for its answer, so it is made off the main thread.
      DispatchQueue.global(qos: .userInitiated).async {
        let result = JavascriptPlugin.getFromGitHub("https://raw.githubusercontent.com/\(ghRepo)/main/Info.json")
        if result.ok,
           let json = result.json as? [String: Any],
           let newGHVersion = json["ghVersion"] as? Int,
           let newVersion = json["version"] as? String {
          if newGHVersion > ghVersion {
            continuation.resume(returning: newVersion)
          } else {
            continuation.resume(returning: nil)
          }
        } else {
          continuation.resume(throwing: PluginError.cannotDownload(result.description, result.text ?? ""))
        }
      }
    }
  }

  /// The updated plugin, downloaded from GitHub and unpacked on `installQueue`, so that the caller does not wait for the network,
  /// the processes that unpack it or the file system.
  func updated() async throws -> JavascriptPlugin? {
    if let ghURL = githubURLString {
      let identifier = identifier
      return try await JavascriptPlugin.onInstallQueue {
        let plugin = try JavascriptPlugin.create(fromGitURL: ghURL)
        guard plugin.identifier == identifier else {
          Logger.log("The updated plugin has an identifier \(plugin.identifier), which doesn't match the current one (\(identifier))", level: .error)
          throw PluginError.cannotLoadPlugin
        }
        return plugin
      }
    }
    return nil
  }

  func syncPreferences() {
    // The file is written once it has been read, so that preferences not yet read are not written over.
    loadPreferences { [self] in
      let url = preferencesFileURL
      Utility.createFileIfNotExist(url: url)
      do {
        try (preferences as NSDictionary).write(to: url)
      } catch let e {
        Logger.log("Unable to write preferences file: \(e.localizedDescription)", level: .error)
      }
    }
  }

  private var preferencesFileURL: URL {
    let url = Utility.pluginsURL
      .appendingPathComponent(".preferences", isDirectory: true)
    Utility.createDirIfNotExist(url: url)
    return url.appendingPathComponent("\(identifier).plist", isDirectory: false)
  }

  /// The URL of `dataURL`, without the folder being created.
  var dataFolderURL: URL {
    Utility.pluginsURL.appendingPathComponent(".data", isDirectory: true).appendingPathComponent(identifier, isDirectory: true)
  }

  /// The URL of `tmpURL`, without the folder being created.
  var tmpFolderURL: URL {
    Utility.tempDirURL.appendingPathComponent("iina-\(identifier)", isDirectory: true)
  }

  lazy var dataURL: URL = {
    let url = dataFolderURL
    Utility.createDirIfNotExist(url: url)
    return url
  }()

  lazy var tmpURL: URL = {
    let url = tmpFolderURL
    Utility.createDirIfNotExist(url: url)
    return url
  }()

  func localizedPermissions(_ permissions: Set<Permission>? = nil, newLine: String = "\n") -> [(name: String, desc: String, isDangerous: Bool)] {
    let permissions = permissions ?? self.permissions

    let sorted = permissions.sorted { (a, b) in
      let da = a.isDangerous, db = b.isDangerous
      if da == db { return a.rawValue < b.rawValue }
      return da
    }

    return sorted.map { permission in
      func localize(_ key: String) -> String {
        return NSLocalizedString("permissions.\(permission.rawValue).\(key)", comment: "")
      }
      var desc = localize("desc")
      if case .networkRequest = permission {
        if domainList.contains("*") {
          desc += "\(newLine)- \(localize("any_site"))"
        } else {
          desc += "\(newLine)- "
          desc += domainList.joined(separator: "\(newLine)- ")
        }
      }

      return (name: localize("name"), desc: desc, isDangerous: permission.isDangerous)
    }
  }
}


fileprivate func resolvePath(_ path: String?, root: URL, allowNetwork: Bool = false) -> URL? {
  guard let path else { return nil }
  if path.hasPrefix("http://") || path.hasPrefix("https://") {
    if allowNetwork { return URL(string: path) }
    else { return nil }
  } else {
    let url = root.appendingPathComponent(path).standardized
    if url.absoluteString.hasPrefix(root.absoluteString) {
      guard FileManager.default.fileExists(atPath: url.path) else {
        Logger.log("The file \(path) doesn't exist", level: .error)
        return nil
      }
      return url
    } else {
      Logger.log("The file path \(path) is invalid", level: .error)
      return nil
    }
  }
}
