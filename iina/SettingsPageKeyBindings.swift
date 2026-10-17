//
//  SettingsKeyBindings.swift
//  iina
//
//  Created by Hechen Li on 2026-02-01.
//  Copyright © 2026 lhc. All rights reserved.
//

fileprivate let ui = SettingsUIHelper.sharedUI


class SettingsPageKeyBindings: SettingsPage {
  override var identifier: String {
    "key.bindings"
  }
  
  override var title: String {
    return NSLocalizedString("preference.keybindings", comment: "Key Bindings")
  }

  override var image: NSImage {
    return .sf("keyboard", withConfiguration: symbolConfiguration)!
  }

  override var localizationTable: String {
    "SettingsKeyBindingLocalizable"
  }
  
  override var showSubSections: Bool { false }

  private lazy var configEditor: ConfigEditor = ConfigEditor()

  override func content() -> [SettingsSection] {
    return sections {
      sectionMediaControl()
      sectionConfiguration()
    }
  }

  private func sectionMediaControl() -> SettingsSection {
    return section {
      SettingsList {
        SettingsItem.Switch()
          .bindTo(.useMediaKeys)
          .image(name: ["playpause.circle", "playpause"])
          .withHelpLink(AppData.wikiLink.appending("/Manage-Key-Bindings"))
      }
    }
  }

  private func sectionConfiguration() -> SettingsSection {
    return section {
      SettingsList {
        SettingsItem.General(title: .text_KeyBindingSet)
          .image(name: ["book.and.wrench", "wrench.adjustable", "wrench"])
          .withValueView(configEditor.chooserView)
        SettingsItem.Custom()
          .view(configEditor.editorView)
        SettingsItem.Switch()
          .bindTo(.displayKeyBindingRawValues)
      }
    }
  }
}


private extension NSUserInterfaceItemIdentifier {
  static let columnID = NSUserInterfaceItemIdentifier("MainColumn")
}


class ConfigEditor: SettingsAccessory.Base {
  fileprivate typealias KC = PrefKeyBindingViewController

  private let prefObserver = Preference.Observer()
  let chooserView: NSView
  let editorView: NSView

  let kbTableView: NSTableView
  let searchField: NSSearchField

  let chooserPopupButton: NSPopUpButton
  let addConfBtn: NSButton
  let delConfBtn: NSButton
  let addKeyMappingBtn: NSButton

  var mappingController: NSArrayController

  let fallbackDefault = "IINA Default"

  /// The configs the editor last listed, with `PrefKeyBindingViewController.listConfigs` off the main thread. The built-in configs'
  /// files are looked up there too, the editor using the same lookups as the old preferences page.
  private(set) var configs = PrefKeyBindingViewController.InputConfigs()

  var configNames: [String] {
    return configs.names
  }

  /// Checks a new config's name against the built-in configs and the user's configs the editor last listed, so that it does not list
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

  var currentConfName: String!
  var currentConfFilePath: String!

  // This variable is to prevent `NSTableView.reloadData()` in the `loadConfigFile` to trigger `loadConfigFile` again thus forming an infinite loop
  var isLoadingConfig = false

  override init() {
    self.mappingController = NSArrayController()
    self.kbTableView = NSTableView()
    self.searchField = NSSearchField()
    searchField.translatesAutoresizingMaskIntoConstraints = false

    self.chooserPopupButton = NSPopUpButton()
    chooserPopupButton.translatesAutoresizingMaskIntoConstraints = false
    chooserPopupButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)

    self.chooserView = NSView()
    chooserView.translatesAutoresizingMaskIntoConstraints = false
    self.editorView = NSView()
    editorView.translatesAutoresizingMaskIntoConstraints = false

    self.addConfBtn = NSButton()
    self.delConfBtn = NSButton()
    addConfBtn.bezelStyle = .push
    delConfBtn.bezelStyle = .push

    self.addKeyMappingBtn = NSButton()

    super.init()

    kbTableView.bind(.content, to: mappingController, withKeyPath: "arrangedObjects", options: nil)
    kbTableView.bind(.selectionIndexes, to: mappingController, withKeyPath: "selectionIndexes", options: nil)
    kbTableView.delegate = self
    kbTableView.headerView = nil
    kbTableView.target = self

    let column = NSTableColumn(identifier: .columnID)
    column.title = "Items"
    kbTableView.addTableColumn(column)

    addConfBtn.translatesAutoresizingMaskIntoConstraints = false
    addConfBtn.image = .init(systemSymbolName: "square.grid.3x1.folder.badge.plus", accessibilityDescription: "Add Configuration")
    addConfBtn.target = self
    addConfBtn.action = #selector(addConfBtnAction)
    delConfBtn.translatesAutoresizingMaskIntoConstraints = false
    delConfBtn.image = .init(systemSymbolName: "trash", accessibilityDescription: "Delete Configuration")
    delConfBtn.target = self
    delConfBtn.action = #selector(deleteConfFileAction)

    let chooserStackView = ui.hStack(chooserPopupButton, delConfBtn, addConfBtn)
    chooserView.addSubview(chooserStackView)
    chooserStackView.padding(.all(8))

    addKeyMappingBtn.translatesAutoresizingMaskIntoConstraints = false
    addKeyMappingBtn.imagePosition = .imageOnly
    addKeyMappingBtn.bezelStyle = .circular
    addKeyMappingBtn.image = .sf("plus")
    addKeyMappingBtn.target = self
    addKeyMappingBtn.action = #selector(addKeyMappingAction)
    addKeyMappingBtn.size(width: 26, height: 26)

    let headerViewContainer = NSView()
    headerViewContainer.translatesAutoresizingMaskIntoConstraints = false
    headerViewContainer.size(height: 32)
    let headerView = ui.hStack(searchField, addKeyMappingBtn)
    headerViewContainer.addSubview(headerView)
    headerView.padding(.top(8), .leading(16), .trailing(16))

    let editorStackView = ui.vStack(align: .leading, spacing: 0, headerViewContainer, kbTableView)

    searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
    searchField.bind(
      .predicate, to: mappingController, withKeyPath: "filterPredicate",
      options: [
        .predicateFormat: "(readableAction contains[cd] $value) OR (prettyCommand contains[cd] $value)",
      ]
    )

    editorView.addSubview(editorStackView)
    editorStackView.padding(.leading(16), .trailing, .vertical)

    NotificationCenter.default.addObserver(forName: .iinaKeyBindingChanged, object: nil, queue: .main, using: saveToConfFile)

    prefObserver.add(.displayKeyBindingRawValues) { [unowned self] _ in
      kbTableView.reloadData()
    }
    loadConfigFile(Preference.string(for: .currentInputConfigName), true)
    // The commands are shown translated with the key binding translator's tables, which are read off the main thread.
    KeyBindingTranslator.load { [weak self] in self?.kbTableView.reloadData() }
  }

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

    guard let configName else {
      fallback()
      return
    }

    // The configs are listed, and the config read, off the main thread.
    KC.readConfig(named: configName) { [self] configs, confFilePath, mapping in
      self.configs = configs
      guard let confFilePath else {
        fallback()
        return
      }

      populateChooser(select: configName)
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

  private func populateChooser(select currentConfName: String? = nil) {
    guard let menu = chooserPopupButton.menu else { return }

    menu.removeAllItems()
    for name in configNames {
      let isDefaultConfig = KC.isDefaultConfig(name)
      menu.addItem(withTitle: name, image: isDefaultConfig ? ["lock"] : nil,
                   action: #selector(configSelected), target: self, obj: name)
    }

    if let currentConfName {
      chooserPopupButton.selectItem(withTitle: currentConfName)
    }
  }

  /// Set the editor's key mappings as the key bindings, then write them to the current config's file off the main thread.
  func saveToConfFile(_ sender: Notification) {
    // An editor whose config has not been read yet has no key mappings to save.
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

  @objc private func configSelected() {
    guard !isLoadingConfig else { return }
    guard let item = chooserPopupButton.selectedItem, item.title != currentConfName else { return }
    loadConfigFile(item.title)
    changeButtonEnabledStatus()
  }

  @objc private func addConfBtnAction() {
    let menu = NSMenu()
    if #available(macOS 14.0, *) {
      menu.addItem(.sectionHeader(title: ui.localized(.text_NewKeyBindingSet)))
    } else {
      menu.addItem(withTitle: ui.localized(.text_NewKeyBindingSet))
      menu.addItem(.separator())
    }
    menu.addItem(withTitle: ui.localized(.text_CreateAnEmptySet),
                 action: #selector(newConfFileAction), target: self)
    menu.addItem(withTitle: ui.localized(.text_DuplicateCurrentSet),
                 action: #selector(duplicateConfFileAction), target: self)
    menu.addItem(withTitle: ui.localized(.text_ImportAnExistingConfigFile),
                 action: #selector(importConfigAction), target: self)
    menu.addItem(.separator())
    menu.addItem(withTitle: ui.localized(.text_ShowTheConfigFileIn),
                 action: #selector(showConfFileAction), target: self)
    NSMenu.popUpContextMenu(menu, with: NSApp.currentEvent!, for: addConfBtn)
  }

  @objc func newConfFileAction(_ sender: AnyObject) {
    Utility.quickPromptPanel("config.new", validator: configNameValidator, sheetWindow: addConfBtn.window) { newName in
      self.newConfigFilePath(forName: newName) { newFilePath in
        self.createConfig(named: newName, at: newFilePath)
      }
    }
  }

  /// Make an empty config file at `path` off the main thread, then load it as the config named `name`.
  func createConfig(named name: String, at path: String) {
    KC.changeConfigFiles({
      guard FileManager.default.createFile(atPath: path, contents: nil, attributes: nil) else {
        throw CocoaError(.fileWriteUnknown)
      }
    }) { [self] error in
      guard error == nil else {
        Utility.showAlert("config.cannot_create", sheetWindow: addConfBtn.window)
        return
      }
      loadConfigFile(name)
    }
  }

  @objc func duplicateConfFileAction(_ sender: AnyObject) {
    Utility.quickPromptPanel("config.duplicate", validator: configNameValidator, sheetWindow: addConfBtn.window) { newName in
      self.newConfigFilePath(forName: newName) { newFilePath in
        self.duplicateConfig(named: newName, at: newFilePath)
      }
    }
  }

  /// Copy the current config's file to `path` off the main thread, then load the copy as the config named `name`.
  func duplicateConfig(named name: String, at path: String) {
    let currentPath = currentConfFilePath!
    KC.changeConfigFiles({ try FileManager.default.copyItem(atPath: currentPath, toPath: path) }) { [self] error in
      if let error {
        Utility.showAlert("config.cannot_create", arguments: [error.localizedDescription], sheetWindow: view.window)
        return
      }
      loadConfigFile(name)
    }
  }

  @objc func importConfigAction(_ sender: Any) {
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

  @objc func showConfFileAction(_ sender: AnyObject) {
    Utility.revealInFinder(filesAtPaths: [currentConfFilePath])
  }

  @objc func deleteConfFileAction(_ sender: AnyObject) {
    guard isCurrentConfigEditable() else { return }
    Task { @MainActor in
      guard await Dialogs.ask("delete_keybindingset").show(in: kbTableView.window!) else { return }
      deleteCurrentConfig()
    }
  }

  /// Remove the current config's file off the main thread, then load the default config.
  func deleteCurrentConfig() {
    let currentPath = currentConfFilePath!
    KC.changeConfigFiles({ try FileManager.default.removeItem(atPath: currentPath) }) { [self] error in
      Task { @MainActor in
        if error != nil {
          await Dialogs.alert("error_deleting_file").show(in: view.window!)
        }
        // Fallback to default
        loadConfigFile(fallbackDefault)
      }
    }
  }

  @objc func addKeyMappingAction(_ sender: AnyObject) {
    Task { @MainActor in
      guard isCurrentConfigEditable() else {
        await Dialogs.alert("duplicate_config").show(in: kbTableView.window!)
        return
      }
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
  }

  @objc func removeKeyMappingAction(_ sender: ButtonWithObject) {
    guard let km = sender.object else { return }
    mappingController.remove(km)
    NotificationCenter.default.post(Notification(name: .iinaKeyBindingChanged))
  }

  @objc func editKeyMappingAction(_ sender: ButtonWithObject) {
    Task { @MainActor in
      guard isCurrentConfigEditable() else {
        await Dialogs.alert("duplicate_config").show(in: kbTableView.window!)
        return
      }
      guard let km = sender.object else { return }
      showKeyBindingPanel(key: km.rawKey, action: km.readableAction) { key, action in
        guard !key.isEmpty && !action.isEmpty else { return }
        km.rawKey = key
        km.rawAction = action
        self.kbTableView.reloadData()
        NotificationCenter.default.post(Notification(name: .iinaKeyBindingChanged))
      }
    }
  }

  @objc func showHelpForLockedSetAction(_ sender: ButtonWithObject) {
    Task {
      await Dialogs.alert("duplicate_config").show(in: kbTableView.window!)
    }
  }

  private func showKeyBindingPanel(key: String = "", action: String = "", ok: @escaping (String, String) -> Void) {
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
    panel.beginSheetModal(for: kbTableView.window!) { respond in
      if respond == .alertFirstButtonReturn {
        let rawKey = KeyCodeHelper.escapeReservedMpvKeys(keyRecordViewController.keyCode)
        ok(rawKey, keyRecordViewController.action)
      }
    }
  }

  private func changeButtonEnabledStatus() {
    let shouldEnableEdit = isCurrentConfigEditable()
    delConfBtn.isEnabled = shouldEnableEdit
    addKeyMappingBtn.image = shouldEnableEdit ? .sf("plus") : .customLockBadgeQuestionmark
  }

  /// Check whether or not a new config file with provided filename should be created, on `Utility.workspaceQueue` since the check
  /// reads the file system.
  /// - Parameter filename: the filename of the new config file
  /// - Parameter body: Called on the main thread with the path of the new config file if it could be created.
  func newConfigFilePath(forName filename: String, then body: @escaping (String) -> Void) {
    Utility.onWorkspaceQueue {
      // Check if there exists a config file with the same filename
      let filePath = Utility.userInputConfDirURL.appendingPathComponent(filename + ".conf").path
      let exists = FileManager.default.fileExists(atPath: filePath)
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

  /// Whether the current config is the user's, false until the config has been read.
  func isCurrentConfigEditable() -> Bool {
    guard let currentConfName else { return false }
    return !KC.isDefaultConfig(currentConfName)
  }

  private func setKeybindingsForPlayerCore() {
    PlayerCore.setKeyBindings(mappingController.arrangedObjects as! [KeyMapping])
    PlayerCore.inputConfPath = currentConfFilePath
  }
}

extension ConfigEditor: NSTableViewDelegate, NSMenuDelegate {
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard let km = (mappingController.arrangedObjects as? [KeyMapping])?[at: row] else { return nil }
    let cell = (tableView.makeView(withIdentifier: .columnID, owner: self) as? KeyMappingCell) ?? KeyMappingCell()

    cell.setup(keyMapping: km, isSelected: row == tableView.selectedRow, self)
    return cell
  }

  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    return RowView()
  }

  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    return 32
  }
}


fileprivate class KeyMappingCell: NSTableCellView {
  var keyLabel: NSTextField!
  var actionLabel: NSTextField!
  var editButton: ButtonWithObject!
  var removeButton: ButtonWithObject!
  var lockHelpButton: ButtonWithObject!
  weak var editor: ConfigEditor!

  func setup(keyMapping km: KeyMapping, isSelected: Bool, _ editor: ConfigEditor) {
    self.editor = editor

    if keyLabel == nil || actionLabel == nil {
      self.identifier = .columnID

      let actionLabel = NSTextField(labelWithString: "")
      actionLabel.translatesAutoresizingMaskIntoConstraints = false

      let spacer = NSView()
      spacer.translatesAutoresizingMaskIntoConstraints = false
      spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

      func createActionButton(symbol: String, action: Selector) -> ButtonWithObject {
        let image = NSImage.sf(symbol)!
        let button = ButtonWithObject(
          title: "", image: image, target: editor, action: action)
        button.bezelStyle = .circular
        button.size(width: 20, height: 20)
        button.isHidden = true
        return button
      }

      self.editButton = createActionButton(
        symbol: "pencil", action: #selector(editor.editKeyMappingAction))
      self.removeButton = createActionButton(
        symbol: "trash.fill", action: #selector(editor.removeKeyMappingAction))
      self.lockHelpButton = createActionButton(
        symbol: "custom.lock.badge.questionmark", action: #selector(editor.showHelpForLockedSetAction))

      let keyBox = NSBox()
      keyBox.translatesAutoresizingMaskIntoConstraints = false
      keyBox.titlePosition = .noTitle
      keyBox.boxType = .custom
      keyBox.borderWidth = 1
      keyBox.borderColor = .separatorColor
      keyBox.fillColor = .controlBackgroundColor
      keyBox.cornerRadius = 4
      keyBox.contentViewMargins = .zero
      let keyLabel = NSTextField(labelWithAttributedString: NSAttributedString(string: ""))
      keyLabel.translatesAutoresizingMaskIntoConstraints = false
      keyBox.contentView?.addSubview(keyLabel)
      keyBox.size(height: 28)
      keyLabel.padding(.horizontal(4)).center(.y, with: keyBox.contentView)

      self.keyLabel = keyLabel
      self.actionLabel = actionLabel

      let stackView = NSStackView(views: [actionLabel, spacer, lockHelpButton, removeButton, editButton, keyBox])
      stackView.translatesAutoresizingMaskIntoConstraints = false
      stackView.orientation = .horizontal
      stackView.alignment = .centerY

      self.addSubview(stackView)
      stackView.padding(.vertical, .horizontal(4))
    }

    selectionChanged(isSelected)

    if Preference.bool(for: .displayKeyBindingRawValues) {
      keyLabel.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
      actionLabel.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    } else {
      keyLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .regular)
      actionLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    }

    keyLabel.attributedStringValue = km.attributedKeyForDisplay
    actionLabel.stringValue = km.actionForDisplay
    removeButton.object = km
    editButton.object = km
  }

  func selectionChanged(_ selected: Bool) {
    if editor.isCurrentConfigEditable() {
      editButton.isHidden = !selected
      removeButton.isHidden = !selected
      lockHelpButton.isHidden = true
    } else {
      lockHelpButton.isHidden = !selected
    }
  }
}


class ButtonWithObject : NSButton {
  weak var object: KeyMapping?
}


class RowView: NSTableRowView {
  override var isSelected: Bool {
    didSet {
      // Push selection state to the cell view
      for subview in subviews {
        (subview as? KeyMappingCell)?.selectionChanged(isSelected)
      }
    }
  }
}
