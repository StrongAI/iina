//
//  AboutWindowController.swift
//  iina
//
//  Created by lhc on 31/12/2016.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa
import Just

fileprivate extension NSUserInterfaceItemIdentifier {
  static let dataSourceItem = NSUserInterfaceItemIdentifier(rawValue: "dataSourceItem")
}

struct Contributor: Decodable {
  let avatarURL: String

  enum CodingKeys: String, CodingKey {
    case avatarURL = "avatar_url"
  }
}

class AboutWindowController: NSWindowController {

  override var windowNibName: NSNib.Name {
    return NSNib.Name("AboutWindowController")
  }

  @IBOutlet weak var windowBackgroundBox: NSBox!
  @IBOutlet weak var iconImageView: NSImageView!
  @IBOutlet weak var iinaLabel: NSTextField! {
    didSet {
      iinaLabel.font = NSFont.systemFont(ofSize: 24, weight: .light)
    }
  }
  @IBOutlet weak var versionLabel: NSTextField!
  @IBOutlet weak var mpvVersionLabel: NSTextField!
  @IBOutlet weak var ffmpegVersionLabel: NSTextField!
  @IBOutlet weak var buildView: NSView!
  @IBOutlet weak var buildBranchButton: NSButton!
  @IBOutlet weak var buildDateLabel: NSTextField!

  @IBOutlet var detailTextView: NSTextView!
  @IBOutlet var creditsTextView: NSTextView!

  @IBOutlet weak var licenseButton: AboutWindowButton!
  @IBOutlet weak var contributorsButton: AboutWindowButton!
  @IBOutlet weak var creditsButton: AboutWindowButton!
  @IBOutlet weak var tabView: NSTabView!
  @IBOutlet weak var contributorsCollectionView: NSCollectionView!
  @IBOutlet weak var contributorsFooterView: NSVisualEffectView!

  private lazy var contributors = getContributors()

  /// The queue the window's contribution and credits texts are read on, so that the main thread does not wait for the file system.
  static let queue = DispatchQueue(label: "IINAAboutWindowController", qos: .userInitiated)

  /// The text of the RTF file `name` in the app bundle, or `nil` if it cannot be read.
  static func readText(_ name: String) -> NSAttributedString? {
    guard let url = Bundle.main.url(forResource: name, withExtension: "rtf") else { return nil }
    return try? NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                   documentAttributes: nil)
  }

  override func windowDidLoad() {
    super.windowDidLoad()

    window?.titlebarAppearsTransparent = true
    window?.titleVisibility = .hidden

    windowBackgroundBox.fillColor = .windowBackgroundColor
    iconImageView.image = NSApp.applicationIconImage

    let (version, build) = InfoDictionary.shared.version
    versionLabel.stringValue = "\(version) Build \(build)"

    // The mpv version is read without waiting for the defaults' mpv to start, and shown once it is read.
    MPVOptionDefaults.shared.versions { [weak self] mpvVersion, _ in self?.mpvVersionLabel.stringValue = mpvVersion }
    ffmpegVersionLabel.stringValue = "FFmpeg \(String(cString: av_version_info()))"

    // Use a localized date for the build date.
    let toString = DateFormatter()
    toString.dateStyle = .medium
    toString.timeStyle = .medium

    switch InfoDictionary.shared.buildType {
    case .nightly:
      if let buildDate = InfoDictionary.shared.buildDate,
         let buildSHA = InfoDictionary.shared.shortCommitSHA {
        buildDateLabel.stringValue = toString.string(from: buildDate)
        buildDateLabel.isHidden = false
        buildBranchButton.title = "NIGHTLY " + buildSHA
        buildBranchButton.action = #selector(self.openCommitLink)
        buildBranchButton.isHidden = false
      }
    case .debug:
      if let buildDate = InfoDictionary.shared.buildDate,
         let buildBranch = InfoDictionary.shared.buildBranch,
         let buildSHA = InfoDictionary.shared.shortCommitSHA {
        buildDateLabel.stringValue = toString.string(from: buildDate)
        buildDateLabel.isHidden = false
        buildBranchButton.title = buildBranch + " " + buildSHA
        buildBranchButton.action = #selector(self.openCommitLink)
        buildBranchButton.isHidden = false
      }
    default:
      break
    }

    // The contribution and credits texts are read off the main thread and shown once they are read.
    Self.queue.async {
      let (contribution, credits) = (Self.readText("Contribution"), Self.readText("Credits"))
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        for (textView, text) in [(detailTextView, contribution), (creditsTextView, credits)] {
          guard let textView, let text else { continue }
          textView.textStorage?.setAttributedString(text)
          textView.textColor = NSColor.secondaryLabelColor
        }
      }
    }

    contributorsCollectionView.dataSource = self
    contributorsCollectionView.backgroundColors = [.clear]
    contributorsCollectionView.register(AboutWindowContributorAvatarItem.self, forItemWithIdentifier: .dataSourceItem)

    let image = NSImage(size: contributorsFooterView.frame.size)
    let rect = CGRect(origin: .zero, size: contributorsFooterView.frame.size)
    image.lockFocus()
    let loc: [CGFloat] = [0, 0.3, 0.6, 0.8, 1]
    let colors: [CGFloat] = [1, 0.95, 0.8, 0.05, 0]
    let gradient = NSGradient(colors: colors.map { NSColor(white: 0.925, alpha: $0) }, atLocations: loc, colorSpace: .deviceGray)
    gradient!.draw(in: rect, angle: 90)
    image.unlockFocus()
    contributorsFooterView.material = .windowBackground
    contributorsFooterView.maskImage = image

    contributorsCollectionView.enclosingScrollView?.contentInsets.bottom = contributorsFooterView.frame.height * loc[colors.firstIndex(of: 0)! - 1]
  }

  @objc func openCommitLink() {
    guard let commitSHA = InfoDictionary.shared.buildCommit else { return }
    Utility.open(.init(string: "https://github.com/iina/iina/commit/\(commitSHA)")!)
  }

  @IBAction func sectionBtnAction(_ sender: NSButton) {
    tabView.selectTabViewItem(at: sender.tag)
    [licenseButton, contributorsButton, creditsButton].forEach {
      $0?.state = $0 == sender ? .on : .off
      $0?.updateState()
    }
  }

  @IBAction func contributorsBtnAction(_ sender: Any) {
    Utility.open(URL(string: AppData.contributorsLink)!)
  }

  @IBAction func translatorsBtnAction(_ sender: Any) {
    Utility.open(URL(string: AppData.crowdinMembersLink)!)
  }
}

extension AboutWindowController: NSCollectionViewDataSource {
  func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
    return contributors.count
  }

  func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
    let item = contributorsCollectionView.makeItem(withIdentifier: .dataSourceItem, for: indexPath) as! AboutWindowContributorAvatarItem
    item.imageView?.image = nil
    guard let contributor = contributors[at: indexPath.item] else { return item }
    item.avatarURL = contributor.avatarURL
    return item
  }

  private func getContributors() -> [Contributor] {
    // This method will be called only once when `self.contributors` is needed,
    // i.e. when `contributorsCollectionView` is being initialized.
    loadContributors(from: "https://api.github.com/repos/iina/iina/contributors")
    return []
  }

  private func loadContributors(from url: String) {
    Just.get(url, asyncCompletionHandler: { response in
      let prevCount = self.contributors.count
      guard let data = response.content,
        let contributors = try? JSONDecoder().decode([Contributor].self, from: data) else {
          return
      }
      self.contributors.append(contentsOf: contributors)
      // avoid possible crash
      guard self.contributors.count > prevCount else { return }
      let insertIndices = ([Int](prevCount..<self.contributors.count)).map {
        IndexPath(item: $0, section: 0)
      }
      DispatchQueue.main.sync {
        self.contributorsCollectionView.insertItems(at: Set(insertIndices))
      }
      if let nextURL = response.links["next"]?["url"] {
        self.loadContributors(from: nextURL)
      }
    })
  }
}

class AboutWindowButton: NSButton {

  override func awakeFromNib() {
    wantsLayer = true
    layer?.cornerRadius = 4
    updateState()
  }

  func updateState() {
    if let cell = self.cell as? NSButtonCell {
      cell.backgroundColor = state == .on ? .controlAccentColor : .clear
    }
    attributedTitle = NSAttributedString(string: title,
                                         attributes: [.foregroundColor: state == .on ? NSColor.white : NSColor.labelColor])
  }
}
