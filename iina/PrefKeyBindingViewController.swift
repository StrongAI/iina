//
//  PrefKeyBindingViewController.swift
//  iina
//
//  Created by lhc on 12/12/2016.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa

fileprivate let fm = FileManager.default
fileprivate typealias KC = PrefKeyBindingViewController

@objcMembers
class PrefKeyBindingViewController: PreferenceViewController, PreferenceWindowEmbeddable {

  override var nibName: NSNib.Name {
    return NSNib.Name("PrefKeyBindingViewController")
  }

  var preferenceTabTitle: String {
    return NSLocalizedString("preference.keybindings", comment: "Keybindings")
  }

  var preferenceTabImage: NSImage {
    return .sf("keyboard", withConfiguration: symbolConfiguration)!
  }

  var preferenceContentIsScrollable: Bool {
    return false
  }

  static let defaultConfigMap: KeyValuePairs<String, String> = [
    "IINA Default": "iina-default-input",
    "mpv Default": "input",
    "VLC Default": "vlc-default-input",
    "Movist Default": "movist-default-input",
    "Movist v2 Default": "movist-v2-default-input",
  ]

  let fallbackDefault = "IINA Default"

  /// The files of the built-in input configs, by name, looked up in the bundle. Read only by `listConfigs`.
  private static let defaultConfigs: [String: String] = {
    var configs: [String: String] = [:]
    for (key, value) in defaultConfigMap {
      configs[key] = Bundle.main.path(forResource: value, ofType: "conf", inDirectory: "config")!
    }
    return configs
  }()

  /// The files of the user's input configs, by name, listed from the user's input config folder, which is made first unless it
  /// exists. Read only by `listConfigs`.
  private static var userConfigs: [String: String] {
    do {
      Utility.createDirIfNotExist(url: Utility.userInputConfDirURL)
      let files = try fm.contentsOfDirectory(at: Utility.userInputConfDirURL, includingPropertiesForKeys: nil)
      let configFiles = files.filter { $0.pathExtension == "conf" }
      return Dictionary(uniqueKeysWithValues: configFiles.map { ($0.deletingPathExtension().lastPathComponent, $0.path) })
    } catch {
      Logger.fatal("Cannot get user config file!")
    }
  }

  /// The built-in input configs and the user's, by name, as listed by `listConfigs`.
  struct InputConfigs {
    /// The files of the built-in configs.
    var defaults: [String: String] = [:]
    /// The files of the user's configs.
    var users: [String: String] = [:]

    /// The names of the configs, the built-in ones first in their order, then the user's, sorted.
    var names: [String] {
      return KC.defaultConfigMap.map { $0.key } + Array(users.keys).sorted()
    }

    func path(forConfig name: String) -> String? {
      return defaults[name] ?? users[name]
    }
  }

  /// List the input configs, looking the built-in ones up in the bundle and listing the user's input config folder. This reads the
  /// file system, so it is called only on `PlayerCore.keyBindingsQueue`; tests replace it to hold the listing.
  static var listConfigs: () -> InputConfigs = {
    return InputConfigs(defaults: defaultConfigs, users: userConfigs)
  }

  /// Whether `name` is the name of a built-in config, which is known without looking the config up.
  static func isDefaultConfig(_ name: String) -> Bool {
    return defaultConfigMap.contains { $0.key == name }
  }

  /// List the input configs and read the key mappings of the config named `name` on `PlayerCore.keyBindingsQueue`, so that the main
  /// thread does not wait for the file system, then hand `completion` the configs listed, the file of the config, nil if it has
  /// none, and its key mappings, nil if they cannot be read, on the main thread.
  static func readConfig(named name: String, then completion: @escaping (InputConfigs, String?, [KeyMapping]?) -> Void) {
    PlayerCore.keyBindingsQueue.async {
      let configs = listConfigs()
      let path = configs.path(forConfig: name)
      let mappings = path.flatMap { KeyMapping.parseInputConf(at: $0) }
      DispatchQueue.main.async { completion(configs, path, mappings) }
    }
  }

  /// Change the input config files with `change` on `PlayerCore.keyBindingsQueue`, so that the main thread does not wait for the file
  /// system, then call `completion` on the main thread with the error `change` threw, if any. Changes are made in the order asked,
  /// before the configs are listed or read again.
  static func changeConfigFiles(_ change: @escaping () throws -> Void, then completion: @escaping (Error?) -> Void) {
    PlayerCore.keyBindingsQueue.async {
      var thrown: Error?
      do {
        try change()
      } catch {
        thrown = error
      }
      DispatchQueue.main.async { completion(thrown) }
    }
  }

  /// The configs the page last listed, with `listConfigs` off the main thread.
  private(set) var configs = InputConfigs()

  private var cachedConfigNames: [String] = []

  var configNames: [String] {
    return configs.names
  }

  var currentConfName: String!
  var currentConfFilePath: String!
  
  // This variable is to prevent `NSTableView.reloadData()` in the `loadConfigFile` to trigger `loadConfigFile` again thus forming an infinite loop
  var isLoadingConfig = false

  var shouldEnableEdit: Bool = true

  // MARK: - Outlets

  @IBOutlet weak var confTableView: NSTableView!
  @IBOutlet weak var kbTableView: NSTableView!
  @IBOutlet weak var configHintLabel: NSTextField!
  @IBOutlet weak var addKmBtn: NSButton!
  @IBOutlet weak var removeKmBtn: NSButton!
  @IBOutlet weak var showConfFileBtn: NSButton!
  @IBOutlet weak var deleteConfFileBtn: NSButton!
  @IBOutlet weak var newConfigBtn: NSButton!
  @IBOutlet weak var duplicateConfigBtn: NSButton!
  @IBOutlet weak var useMediaKeysButton: NSButton!
  @IBOutlet weak var keyMappingSearchField: NSSearchField!
  @IBOutlet var mappingController: NSArrayController!

  /// Checks a new config's name against the built-in configs and the user's configs the page last listed, so that it does not list
  /// them on the main thread. Where the new config's file is made, a file of its name is looked for again.
  lazy var configNameValidator: Utility.InputValidator<String> = { [unowned self] input in
    if input.isEmpty {
      return .valueIsEmpty
    }
    if KC.isDefaultConfig(input) || configs.users[input] != nil {
      return .valueAlreadyExists
    }
    return .ok
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    cachedConfigNames = configNames

    kbTableView.delegate = self
    kbTableView.doubleAction = Preference.bool(for: .displayKeyBindingRawValues) ? nil : #selector(editRow)
    confTableView.dataSource = self
    confTableView.delegate = self

    removeKmBtn.isEnabled = false

    useMediaKeysButton.title = NSLocalizedString("preference.system_media_control", comment: "Use system media control")

    // Load the config file saved in user default
    loadConfigFile(Preference.string(for: .currentInputConfigName), true)
    // The commands are shown translated with the key binding translator's tables, which are read off the main thread.
    KeyBindingTranslator.load { [weak self] in self?.kbTableView.reloadData() }

    NotificationCenter.default.addObserver(forName: .iinaKeyBindingChanged, object: nil, queue: .main, using: saveToConfFile)
  }

  // MARK: - IBActions

  func showKeyBindingPanel(key: String = "", action: String = "", ok: @escaping (String, String) -> Void) {
    let panel = NSAlert()
    let keyRecordViewController = KeyRecordViewController()
    keyRecordViewController.keyCode = key
    keyRecordViewController.action = action
    panel.messageText = NSLocalizedString("keymapping.title", comment: "Key Mapping")
    panel.informativeText = NSLocalizedString("keymapping.message", comment: "Press any key to record.")
    panel.accessoryView = keyRecordViewController.view
    panel.window.initialFirstResponder = keyRecordViewController.keyRecordView
    let okButton = panel.addButton(withTitle: NSLocalizedString("general.ok", comment: "OK"))
    okButton.cell!.bind(.enabled, to: keyRecordViewController, withKeyPath: "ready", options: nil)
    panel.addButton(withTitle: NSLocalizedString("general.cancel", comment: "Cancel"))
    panel.beginSheetModal(for: view.window!) { respond in
      if respond == .alertFirstButtonReturn {
        let rawKey = KeyCodeHelper.escapeReservedMpvKeys(keyRecordViewController.keyCode)
        ok(rawKey, keyRecordViewController.action)
      }
    }
  }

  @IBAction func addKeyMappingBtnAction(_ sender: AnyObject) {
    showKeyBindingPanel { key, action in
      guard !key.isEmpty && !action.isEmpty else { return }
      if action.hasPrefix("@iina") {
        let trimmedAction = action[action.index(action.startIndex, offsetBy: "@iina".count)...].trimmingCharacters(in: .whitespaces)
        self.mappingController.addObject(KeyMapping(rawKey: key,
                                        rawAction: trimmedAction,
                                        isIINACommand: true))
      } else {
        self.mappingController.addObject(KeyMapping(rawKey: key, rawAction: action))
      }

      self.kbTableView.scrollRowToVisible((self.mappingController.arrangedObjects as! [AnyObject]).count - 1)
      NotificationCenter.default.post(Notification(name: .iinaKeyBindingChanged))
    }
  }

  @IBAction func removeKeyMappingBtnAction(_ sender: AnyObject) {
    mappingController.remove(sender)
    NotificationCenter.default.post(Notification(name: .iinaKeyBindingChanged))
  }

  @IBAction func newConfFileAction(_ sender: AnyObject) {
    Utility.quickPromptPanel("config.new", validator: configNameValidator, sheetWindow: view.window) { newName in
      self.newConfigFilePath(forName: newName) { newFilePath in
        self.createConfig(named: newName, at: newFilePath)
      }
    }
  }

  /// Make an empty config file at `path` off the main thread, then load it as the config named `name`.
  func createConfig(named name: String, at path: String) {
    KC.changeConfigFiles({
      guard fm.createFile(atPath: path, contents: nil, attributes: nil) else { throw CocoaError(.fileWriteUnknown) }
    }) { [self] error in
      guard error == nil else {
        Utility.showAlert("config.cannot_create", sheetWindow: view.window)
        return
      }
      loadConfigFile(name)
    }
  }

  @IBAction func duplicateConfFileAction(_ sender: AnyObject) {
    Utility.quickPromptPanel("config.duplicate", validator: configNameValidator, sheetWindow: view.window) { newName in
      self.newConfigFilePath(forName: newName) { newFilePath in
        self.duplicateConfig(named: newName, at: newFilePath)
      }
    }
    
  }

  /// Copy the current config's file to `path` off the main thread, then load the copy as the config named `name`.
  func duplicateConfig(named name: String, at path: String) {
    let currentPath = currentConfFilePath!
    KC.changeConfigFiles({ try fm.copyItem(atPath: currentPath, toPath: path) }) { [self] error in
      if let error {
        Utility.showAlert("config.cannot_create", arguments: [error.localizedDescription], sheetWindow: view.window)
        return
      }
      loadConfigFile(name)
    }
  }
  
  @IBAction func configFileListDoubleAction(_ sender: NSTableView) {
    guard shouldEnableEdit else { return }
    Utility.quickPromptPanel("config.rename", validator: configNameValidator, sheetWindow: view.window) { newName in
      self.newConfigFilePath(forName: newName) { newFilePath in
        self.renameConfig(to: newName, at: newFilePath)
      }
    }
  }

  /// Move the current config's file to `path` off the main thread, then load it as the config named `name`.
  func renameConfig(to name: String, at path: String) {
    let currentPath = currentConfFilePath!
    KC.changeConfigFiles({ try fm.moveItem(atPath: currentPath, toPath: path) }) { [self] error in
      if let error {
        Utility.showAlert("config.cannot_create", arguments: [error.localizedDescription], sheetWindow: view.window)
        return
      }
      loadConfigFile(name)
    }
  }

  @IBAction func showConfFileAction(_ sender: AnyObject) {
    Utility.revealInFinder(filesAtPaths: [currentConfFilePath])
  }

  /// Remove the current config's file off the main thread, then load the default config.
  @IBAction func deleteConfFileAction(_ sender: AnyObject) {
    let currentPath = currentConfFilePath!
    KC.changeConfigFiles({ try FileManager.default.removeItem(atPath: currentPath) }) { [self] error in
      if error != nil {
        Utility.showAlert("error_deleting_file", sheetWindow: view.window)
      }
      // Fallback to default
      loadConfigFile(fallbackDefault)
    }
  }

  @IBAction func importConfigBtnAction(_ sender: Any) {
    Utility.quickOpenPanel(title: "Select Config File to Import", chooseDir: false, sheetWindow: view.window, allowedFileTypes: ["conf"]) { url in
      guard url.isFileURL, url.lastPathComponent.hasSuffix(".conf") else { return }
      self.importConfig(from: url)
    }
  }

  /// Copy the config file at `url` into the user's input config folder off the main thread, then load the copy.
  func importConfig(from url: URL) {
    let newName = url.deletingPathExtension().lastPathComponent
    KC.changeConfigFiles({
      let newFilePath = Utility.userInputConfDirURL.appendingPathComponent(url.lastPathComponent).path
      try FileManager.default.copyItem(atPath: url.path, toPath: newFilePath)
    }) { [self] error in
      if let error {
        Utility.showAlert("config.cannot_create", arguments: [error.localizedDescription], sheetWindow: view.window)
        return
      }
      loadConfigFile(newName)
    }
  }

  @IBAction func displayRawValueAction(_ sender: NSButton) {
    kbTableView.doubleAction = Preference.bool(for: .displayKeyBindingRawValues) ? nil : #selector(editRow)
    kbTableView.reloadData()
  }

  @IBAction func openKeyBindingsHelpAction(_ sender: AnyObject) {
    Utility.open(URL(string: AppData.wikiLink.appending("/Manage-Key-Bindings"))!)
  }

  // MARK: - UI

  private func changeButtonEnabledStatus() {
    shouldEnableEdit = !isDefaultConfig(currentConfName)
    [showConfFileBtn, deleteConfFileBtn, addKmBtn].forEach { btn in
      btn.isEnabled = shouldEnableEdit
    }
    kbTableView.tableColumns.forEach { $0.isEditable = shouldEnableEdit }
    configHintLabel.stringValue = NSLocalizedString("preference.key_binding_hint_\(shouldEnableEdit ? "2" : "1")", comment: "preference.key_binding_hint")
  }

  /// Set the page's key mappings as the key bindings, then write them to the current config's file off the main thread.
  func saveToConfFile(_ sender: Notification) {
    // A page whose config has not been read yet has no key mappings to save.
    guard let currentConfFilePath else { return }
    let predicate = mappingController.filterPredicate
    mappingController.filterPredicate = nil
    let keyMappings = mappingController.arrangedObjects as! [KeyMapping]
    for mapping in keyMappings {
      mapping.rawKey = KeyCodeHelper.escapeReservedMpvKeys(mapping.rawKey)
    }
    setKeybindingsForPlayerCore()
    mappingController.filterPredicate = predicate
    let inputConf = KeyMapping.generateInputConf(from: keyMappings)
    KC.changeConfigFiles({ try inputConf.write(toFile: currentConfFilePath, atomically: true, encoding: .utf8) }) { [self] error in
      if error != nil {
        Utility.showAlert("config.cannot_write", sheetWindow: view.window)
      }
    }
  }


  // MARK: - Private

  /// This function firstly reloads the table data, select the config file row, then load the config file.
  /// If the target config file cannot be found, or the file cannot be parsed correctly, it will fallback to the default config.
  /// - Parameter configName: the target config name
  private func loadConfigFile(_ configName: String?, _ initialSetup: Bool = false) {
    guard configName != Preference.string(for: .currentInputConfigName) || initialSetup else { return }
    isLoadingConfig = true
    
    func fallback() {
      isLoadingConfig = false
      DispatchQueue.main.async {
        Utility.showAlert("keybinding_config.error", arguments: [configName ?? "Unknown"], sheetWindow: self.view.window)
      }
      loadConfigFile(fallbackDefault)
    }

    guard let configName = configName else { fallback(); return }

    // The configs are listed, and the config read, off the main thread.
    KC.readConfig(named: configName) { [self] configs, confFilePath, mapping in
      self.configs = configs
      guard let confFilePath else { fallback(); return }

      cachedConfigNames = configNames
      confTableView.reloadData()
      if let index = cachedConfigNames.firstIndex(of: configName) {
        confTableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
      }
      currentConfName = configName
      currentConfFilePath = confFilePath

      guard let mapping else { fallback(); return }

      mappingController.content = nil
      mappingController.add(contentsOf: mapping)
      mappingController.setSelectionIndexes(IndexSet())

      changeButtonEnabledStatus()

      if !initialSetup {
        Preference.set(currentConfName, for: .currentInputConfigName)
        setKeybindingsForPlayerCore()
      }

      isLoadingConfig = false
    }
  }

  /// Check whether or not a new config file with provided filename should be created, on `Utility.workspaceQueue` since the check
  /// reads the file system.
  /// - Parameter filename: the filename of the new config file
  /// - Parameter body: Called on the main thread with the path of the new config file if it could be created.
  func newConfigFilePath(forName filename: String, then body: @escaping (String) -> Void) {
    Utility.onWorkspaceQueue {
      // Check if there exists a config file with the same filename
      let filePath = Utility.userInputConfDirURL.appendingPathComponent(filename + ".conf").path
      let exists = fm.fileExists(atPath: filePath)
      DispatchQueue.main.async {
        guard exists else {
          body(filePath)
          return
        }
        Utility.quickAskPanel("config.file_existing", sheetWindow: self.view.window) { result in
          if result == .alertFirstButtonReturn {
            Utility.revealInFinder(filesAtPaths: [filePath])
          }
        }
      }
    }
  }

  private func isDefaultConfig(_ conf: String) -> Bool {
    return KC.isDefaultConfig(conf)
  }

  private func setKeybindingsForPlayerCore() {
    PlayerCore.setKeyBindings(mappingController.arrangedObjects as! [KeyMapping])
    PlayerCore.inputConfPath = currentConfFilePath
  }

}

// MARK: - NSTableViewDelegate, NSTableViewDataSource

extension PrefKeyBindingViewController: NSTableViewDelegate, NSTableViewDataSource {

  // NSTableViewDataSource

  func numberOfRows(in tableView: NSTableView) -> Int {
    return cachedConfigNames.count
  }

  func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
    let name = cachedConfigNames[row]
    return [
      "name": name,
      "isHidden": !isDefaultConfig(name)
    ] as [String: Any]
  }

  // NSTableViewDelegate

  func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?, row: Int) -> Bool {
    if tableView == kbTableView {
      return Preference.bool(for: .displayKeyBindingRawValues)
    } else {
      return false
    }
  }

  @objc func editRow() {
    guard shouldEnableEdit else {
      Utility.showAlert("duplicate_config", sheetWindow: view.window)
      return
    }
    guard kbTableView.selectedRow != -1 else { return }
    let selectedData = mappingController.selectedObjects[0] as! KeyMapping
    showKeyBindingPanel(key: selectedData.rawKey, action: selectedData.readableAction) { key, action in
      guard !key.isEmpty && !action.isEmpty else { return }
      selectedData.rawKey = key
      selectedData.rawAction = action
      self.kbTableView.reloadData()
      NotificationCenter.default.post(Notification(name: .iinaKeyBindingChanged))
    }
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    guard !isLoadingConfig else { return }
    if let tableView = notification.object as? NSTableView, tableView == confTableView {
      guard let title = cachedConfigNames[at: confTableView.selectedRow], title != currentConfName else { return }
      loadConfigFile(title)
    }
    removeKmBtn.isEnabled = shouldEnableEdit && kbTableView.selectedRow != -1
  }

}
