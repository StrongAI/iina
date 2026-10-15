//
//  InitialWindowController.swift
//  iina
//
//  Created by lhc on 27/6/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Cocoa

// FIXME: Move the strings after 1.5.0
fileprivate let ui = UIHelper(table: "InitialWindowController")

fileprivate extension NSUserInterfaceItemIdentifier {
  static let openFile = NSUserInterfaceItemIdentifier("openFile")
  static let openURL = NSUserInterfaceItemIdentifier("openURL")
  static let recentFile = NSUserInterfaceItemIdentifier("recentFile")
}

fileprivate class GrayHighlightRowView: NSTableRowView {
  override func drawSelection(in dirtyRect: NSRect) {
    if self.selectionHighlightStyle != .none {
      let selectionRect = NSInsetRect(self.bounds, 0, 0)
      NSColor.initialWindowLastFileBackground.setFill()
      let selectionPath = NSBezierPath.init(roundedRect: selectionRect, xRadius: 4, yRadius: 4)
      selectionPath.fill()
    }
  }
}

class InitialWindowController: NSWindowController {
  weak var player: PlayerCore!

  var loaded = false

  var recentFilesTableView: NSTableView!
  var overlayView: NSView!
  var lastFileContainerView: InitialWindowViewActionButton!
  var lastFileIcon: NSImageView!
  var lastFileNameLabel: NSTextField!
  var lastPositionLabel: NSTextField!
  var recentFilesTableTopConstraint: NSLayoutConstraint!

  private let observedPrefKeys: [Preference.Key] = [.themeMaterial]
  private var currentlyHoveredRow: GrayHighlightRowView?

  override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
    guard let keyPath, let change else { return }

    switch keyPath {

    case Preference.Key.themeMaterial.rawValue:
      if let newValue = change[.newKey] as? Int {
        setMaterial(Preference.Theme(rawValue: newValue))
      }

    default:
      return
    }
  }

  /// The serial queue the window looks at files on: whether the last played file exists, the paths the recent documents resolve
  /// to and the icons it shows, so that the main thread does not wait for the file system or LaunchServices.
  static let fileQueue = DispatchQueue(label: "IINAInitialWindowFiles", qos: .userInitiated)

  /// The recent documents the table lists, which leave out the last played file, and the icon of each, found on `fileQueue`.
  private(set) var recentDocuments: [URL] = []
  private var recentDocumentIcons: [NSImage] = []
  private var lastPlaybackURL: URL?

  init(playerCore: PlayerCore) {
    self.player = playerCore
    super.init(window: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func showWindow(_ sender: Any?) {
    if !loaded {
      createWindow()
    }
    super.showWindow(sender)
  }

  private func createWindow() {
    let paddingH = CGFloat(30)

    let window = CommonWindow(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
      styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.setFrameAutosaveName("IINAWelcomeWindow")
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isMovableByWindowBackground = true

    let contentView = InitialWindowContentView()
    window.contentView = contentView
    window.initialFirstResponder = contentView

    let mainView = NSView()
    mainView.translatesAutoresizingMaskIntoConstraints = false
    mainView.wantsLayer = true
    contentView.addSubview(mainView)
    mainView.padding(.all)

    let visualEffectView = NSVisualEffectView()
    visualEffectView.translatesAutoresizingMaskIntoConstraints = false
    visualEffectView.blendingMode = .behindWindow
    visualEffectView.material = .underWindowBackground
    visualEffectView.state = .active
    mainView.addSubview(visualEffectView)
    visualEffectView.padding(.all)

    self.overlayView = NSView()
    overlayView.translatesAutoresizingMaskIntoConstraints = false
    mainView.addSubview(overlayView)
    overlayView.padding(.all)

    let infoButton = NSButton()
    infoButton.translatesAutoresizingMaskIntoConstraints = false
    infoButton.bezelStyle = .circular
    infoButton.isBordered = false
    infoButton.controlSize = .large
    infoButton.image = .sf("info.circle")?.tinted(.systemOrange)
    infoButton.target = self
    infoButton.action = #selector(showBetaInfoPopover)
    mainView.addSubview(infoButton)
    infoButton.padding(.trailing(16), .top(16))

    // header

    let appIcon = ui.image(nil, size: 68)
    appIcon.translatesAutoresizingMaskIntoConstraints = false

    let iinaLabel = NSTextField(labelWithString: "IINA")
    iinaLabel.font = .systemFont(ofSize: 20, weight: .bold)
    let versionLabel = NSTextField(labelWithString: "")
    versionLabel.translatesAutoresizingMaskIntoConstraints = false
    versionLabel.textColor = .secondaryLabelColor

    let header = ui.hStack(spacing: 12, appIcon, ui.vStack(spacing: 4, iinaLabel, versionLabel))
    mainView.addSubview(header)
    header.padding(.top(48), .leading(paddingH - 6), .trailing(paddingH))

    // open button

    let openFileButton = ui.button("qsU-lZ-WQq.title", target: AppDelegate.shared,
                                   action: #selector(AppDelegate.openFile(_:)))
    let openURLButton = ui.button("FKG-Tz-TCV.title", target: AppDelegate.shared,
                                  action: #selector(AppDelegate.openURL(_:)))
    openFileButton.controlSize = .large
    openURLButton.controlSize = .large
    let actions = ui.hStack(spacing: 12, openFileButton, openURLButton)
    mainView.addSubview(actions)
    actions.padding(.top(64), .trailing(paddingH))

    // resume last file

    self.lastFileContainerView = InitialWindowViewActionButton()
    // Hidden until the last played file is found to exist.
    lastFileContainerView.isHidden = true
    lastFileContainerView.translatesAutoresizingMaskIntoConstraints = false
    lastFileContainerView.size(height: 32)
    self.lastFileIcon = ui.image("clock.arrow.trianglehead.counterclockwise.rotate.90", "clock", size: 16)
    let resumeLabel = ui.label("KWZ-BM-GBN.title", canCompress: false)
    self.lastFileNameLabel = NSTextField(labelWithString: "")
    lastFileNameLabel.translatesAutoresizingMaskIntoConstraints = false
    lastFileNameLabel.lineBreakMode = .byTruncatingMiddle
    lastFileNameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    self.lastPositionLabel = NSTextField(labelWithString: "")
    lastPositionLabel.translatesAutoresizingMaskIntoConstraints = false
    lastPositionLabel.textColor = .secondaryLabelColor
    lastPositionLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    let lastFileRow = ui.hStack(spacing: 6,
                                lastFileIcon, resumeLabel, lastFileNameLabel,
                                ui.flexibleSpace(),
                                lastPositionLabel)
    lastFileContainerView.addSubview(lastFileRow)
    lastFileRow.padding(.horizontal(10), .vertical(6))

    mainView.addSubview(lastFileContainerView)
    lastFileContainerView.spacing(.top(16), to: header).padding(.horizontal(paddingH))

    // table

    self.recentFilesTableView = NSTableView()
    recentFilesTableView.headerView = nil
    recentFilesTableView.backgroundColor = .clear
    recentFilesTableView.rowHeight = 28
    recentFilesTableView.style = .plain
    recentFilesTableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    recentFilesTableView.addTableColumn(NSTableColumn(identifier: .recentFile))
    let scrollView = NSScrollView()
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.documentView = recentFilesTableView

    mainView.addSubview(scrollView)
    self.recentFilesTableTopConstraint = scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 24)
    recentFilesTableTopConstraint.isActive = true
    scrollView.padding(.bottom(24), .horizontal(paddingH - 6))

    self.window = window
    // make the content view the first responder, so key events are received by keyDown()
    recentFilesTableView.refusesFirstResponder = true
    window.autorecalculatesKeyViewLoop = false
    window.initialFirstResponder = contentView
    window.makeFirstResponder(nil)

    loaded = true
    appIcon.unregisterDraggedTypes()
    contentView.registerForDraggedTypes([.nsFilenames, .nsURL, .string])

    let infoDict = InfoDictionary.shared
    let (version, build) = infoDict.version
    switch infoDict.buildType {
    case .release:
      versionLabel.stringValue = version
      infoButton.isHidden = true
    case .beta:
      versionLabel.stringValue = "\(version) (build \(build))"
    case .nightly:
      versionLabel.stringValue = "\(version)+g\(infoDict.shortCommitSHA ?? "")"
    case .debug:
      versionLabel.stringValue = "\(version)+g\(infoDict.shortCommitSHA ?? "")"
    }

    recentFilesTableView.delegate = self
    recentFilesTableView.dataSource = self
    recentFilesTableView.action = #selector(self.onTableClicked)
    setMaterial(Preference.enum(for: .themeMaterial))
    observedPrefKeys.forEach { key in
      UserDefaults.standard.addObserver(self, forKeyPath: key.rawValue, options: .new, context: nil)
    }
    reloadData()

    // The app's icon is looked up on the file queue, so that the main thread does not wait for LaunchServices.
    let bundlePath = Bundle.main.bundlePath
    Self.fileQueue.async {
      let iconImage = NSWorkspace.shared.icon(forFile: bundlePath)
      DispatchQueue.main.async { appIcon.image = iconImage }
    }
  }

  @objc private func showBetaInfoPopover(_ sender: NSButton) {
    let width = CGFloat(240)
    let labels = [
      "H7D-2H-wQn.title",
      "s3U-4u-gYp.title",
      "3aN-Hg-GkT.title",
      "I6R-Jl-2Jk.title",
      "BIz-NQ-0qD.title"
    ].enumerated().map { (index, key) in
      let label = ui.label(key, wrapping: true, canCompress: false)
      label.size(width: width)
      if index == 0 {
        label.textColor = .secondaryLabelColor
        label.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
      } else {
        label.font = if index % 2 == 1 {
          NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        } else {
          NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        }
      }
      label.setHTMLValue(ui.localized(key))
      return label
    }
    let view = NSView()
    let stackView = ui.vStack(spacing: 10, labels)
    view.addSubview(stackView)
    stackView.padding(.all(20))
    let popover = NSPopover()
    popover.behavior = .transient
    popover.contentViewController = NSViewController()
    popover.contentViewController?.view = view
    popover.contentSize = NSSize(width: width + 20 * 2, height: 200)
    popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
  }

  private func setMaterial(_ theme: Preference.Theme?) {
    guard let window, let theme else { return }

    window.appearance = NSAppearance(iinaTheme: theme)

    let gradientLayer = CAGradientLayer()
    gradientLayer.colors = window.effectiveAppearance.isDark ?
    [NSColor.black.withAlphaComponent(0.4).cgColor, NSColor.black.withAlphaComponent(0.1).cgColor] :
      [NSColor.black.withAlphaComponent(0.1).cgColor, NSColor.black.withAlphaComponent(0).cgColor]
    overlayView.wantsLayer = true
    overlayView.layer = gradientLayer

    lastFileContainerView.updateBackground()
  }

  @objc func onTableClicked() {
    openRecentItemFromTable(recentFilesTableView.clickedRow)
  }

  private func openRecentItemFromTable(_ rowIndex: Int) {
    if let url = recentDocuments[at: rowIndex] {
      player.openURL(url)
    }
  }

  /// Show the last played file, when it exists, and the recent documents with their icons.
  private func show(lastPlaybackURL: URL?, lastPosition: Double, recentDocuments: [URL], icons: [NSImage]) {
    self.lastPlaybackURL = lastPlaybackURL
    if let lastPlaybackURL {
      // if last file exists
      lastFileContainerView.isHidden = false
      lastFileIcon.image = .sf("clock.arrow.trianglehead.counterclockwise.rotate.90", "clock")
      lastFileNameLabel.stringValue = lastPlaybackURL.lastPathComponent
      lastPositionLabel.stringValue = VideoTime(lastPosition).stringRepresentation
      recentFilesTableTopConstraint.constant = 42 + 18
    } else {
      lastFileContainerView.isHidden = true
      recentFilesTableTopConstraint.constant = 42
    }
    self.recentDocuments = recentDocuments
    recentDocumentIcons = icons
    recentFilesTableView.reloadData()

    if lastFileContainerView.isHidden && recentFilesTableView.numberOfRows > 0 {
      recentFilesTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }
  }

  func reloadData() {
    guard loaded else { return }
    // The settings and the recent documents are read on the main thread. Whether the last played file exists, the paths the
    // recent documents resolve to and their icons are found on the file queue, so that the main thread does not wait for the
    // file system or LaunchServices, and are then shown on the main thread.
    let lastFile = Preference.bool(for: .recordRecentFiles) && Preference.bool(for: .resumeLastPosition)
      ? Preference.url(for: .iinaLastPlayedFilePath) : nil
    let lastPosition = Preference.double(for: .iinaLastPlayedFilePosition)
    let documents = NSDocumentController.shared.recentDocumentURLs
    let verbose = Logger.isEmitting(.verbose)
    Self.fileQueue.async { [weak self] in
      let lastPlaybackURL = lastFile.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
      // Need to call resolvingSymlinksInPath() on both sides, because it changes "/private/var" to "/var" as a special case,
      // even though "/var" points to "/private/var" (i.e. it changes it the opposite direction from what is expected).
      // This is probably a kludge on Apple's part to avoid breaking legacy FreeBSD code.
      let resolvedLast = lastPlaybackURL?.resolvingSymlinksInPath()
      let recentDocuments = documents.filter { $0.resolvingSymlinksInPath() != resolvedLast }
      let icons = recentDocuments.map { NSWorkspace.shared.icon(forFile: $0.path) }

      if verbose {
        Logger.log("InitialWindow.reloadData(): LastPlaybackURL: \(resolvedLast?.path ?? "<none>")", level: .verbose)

        for (index, url) in documents.enumerated() {
          Logger.log("InitialWindow.reloadData(): RecentDocuments_Unfiltered[\(index)]: \(url.resolvingSymlinksInPath().path)", level: .verbose)
        }

        for (index, url) in recentDocuments.enumerated() {
          Logger.log("InitialWindow.reloadData(): Loaded RecentDocuments[\(index)]: \(url.resolvingSymlinksInPath().path)", level: .verbose)
        }
      }

      DispatchQueue.main.async {
        self?.show(lastPlaybackURL: lastPlaybackURL, lastPosition: lastPosition, recentDocuments: recentDocuments, icons: icons)
      }
    }
  }
}

extension InitialWindowController: NSTableViewDelegate, NSTableViewDataSource {

  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    // uses custom highlight for table row
    return GrayHighlightRowView()
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    return recentDocuments.count
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let cell: NSTableCellView
    if let reusableCell = tableView.makeView(withIdentifier: .recentFile, owner: self) as? NSTableCellView {
      cell = reusableCell
    } else {
      cell = NSTableCellView()
      cell.identifier = .recentFile
      let icon = ui.image(nil, size: 16)
      icon.translatesAutoresizingMaskIntoConstraints = false
      let label = NSTextField(labelWithString: "")
      label.translatesAutoresizingMaskIntoConstraints = false
      label.lineBreakMode = .byTruncatingMiddle
      label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      cell.imageView = icon
      cell.textField = label
      cell.addSubview(icon)
      cell.addSubview(label)
      icon.padding(.leading(8))
      icon.center(.y)
      label.spacing(.leading(6), to: icon)
      label.padding(.trailing(8))
      label.center(.y)
    }

    let url = recentDocuments[row]
    cell.imageView?.image = recentDocumentIcons[at: row]
    cell.textField?.stringValue = url.lastPathComponent
    return cell
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    if recentFilesTableView.selectedRow >= 0 {
      // remove "LastFile" button highlight
      lastFileContainerView.updateBackground(.clear)
    } else {
      // re-highlight "LastFile" button
      lastFileContainerView.updateBackground()
    }
  }

  override func keyDown(with event: NSEvent) {
    let keyChar = KeyCodeHelper.keyMap[event.keyCode]?.0
    switch keyChar {
      case "ENTER", "KP_ENTER":  // RETURN or (keypad ENTER)
        if recentFilesTableView.selectedRow >= 0 {
          // If user selected a row in the table using the keyboard, use that
          openRecentItemFromTable(recentFilesTableView.selectedRow)
        } else if let lastURL = lastPlaybackURL {
          // If no row selected in table, most recent file button is selected. Use that if it exists
          player.openURL(lastURL)
        } else if recentFilesTableView.numberOfRows > 0 {
          // Most recent file no longer exists? Try to load next one
          openRecentItemFromTable(0)
        }
      case "DOWN":  // DOWN arrow
        if recentDocuments.count == 0 || (recentFilesTableView.selectedRow >= recentFilesTableView.numberOfRows - 1) {
          super.keyDown(with: event)  // invalid command: beep at user
        } else {
          // default: let recentFilesTableView handle it
          recentFilesTableView.keyDown(with: event)
        }
      case "UP":  // UP arrow
        if !lastFileContainerView.isHidden {   // recent file btn is displayed?
          if recentFilesTableView.selectedRow == -1 {  // ...and recent file btn already highlighted?
            super.keyDown(with: event)  // invalid command: beep at user
            return
          } else if recentFilesTableView.selectedRow == 0 {  // ... top row of table is highlighted?
            // yes: deselect all rows of table. This will fire selectionChanged which will highlight lastFileContainerView
            recentFilesTableView.selectRowIndexes(IndexSet(), byExtendingSelection: false)
            return
          }
        } else if recentFilesTableView.selectedRow == 0 || recentDocuments.isEmpty {
          super.keyDown(with: event)  // invalid command: beep at user
          return
        }
        // default: let recentFilesTableView handle it
        recentFilesTableView.keyDown(with: event)
      default:
        super.keyDown(with: event)
    }
  }
}


class InitialWindowContentView: NSView {

  var player: PlayerCore {
    return (window!.windowController as! InitialWindowController).player
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    return player.acceptFromPasteboard(sender)
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    return player.openFromPasteboard(sender, useGlobalOpenRouting: true)
  }

}


class InitialWindowViewActionButton: NSView {
  let normalBackground = NSColor.initialWindowLastFileBackground
  let hoverBackground = NSColor.initialWindowLastFileBackgroundHover
  let pressedBackground = NSColor.initialWindowLastFileBackgroundPressed

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setup()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setup()
  }

  private func setup() {
    self.wantsLayer = true
    self.layer?.cornerRadius = 8
    self.addTrackingArea(NSTrackingArea(rect: .zero,
      options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: nil))
  }

  override func mouseEntered(with event: NSEvent) {
    updateBackground(hoverBackground)
  }

  override func mouseExited(with event: NSEvent) {
    updateBackground(normalBackground)
  }

  override func mouseDown(with event: NSEvent) {
    updateBackground(pressedBackground)
    if let lastFile = Preference.url(for: .iinaLastPlayedFilePath),
       let windowController = window?.windowController as? InitialWindowController {
      windowController.player.openURL(lastFile)
    }
  }

  override func mouseUp(with event: NSEvent) {
    updateBackground(hoverBackground)
  }

  func updateBackground(_ color: NSColor? = nil) {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      self.layer?.backgroundColor = (color ?? normalBackground).cgColor
    }
  }
}
