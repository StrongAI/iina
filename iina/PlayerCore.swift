//
//  PlayerCore.swift
//  iina
//
//  Created by lhc on 8/7/16.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa

class PlayerCore: NSObject {

  /// Minimum value to set a mpv loop point to.
  ///
  /// Setting a loop point to zero disables looping, so when loop points are being adjusted IINA must insure the mpv property is not
  /// set to zero. However using `Double.leastNonzeroMagnitude` as the minimum value did not work because mpv truncates
  /// the value when storing the A-B loop points in the watch later file. As a result the state of the A-B loop feature is not properly
  /// restored when the movies is played again. Using the following value as the minimum for loop points avoids this issue.
  static private let minLoopPointTime = 0.000001

  // MARK: - Multiple instances

  static let first: PlayerCore = createPlayerCore()

  static private weak var _lastActive: PlayerCore?

  /// - Important: Code referencing this property **must** be run on the main thread as getting the value of this property _may_
  ///              result in a reference the `active` property and that requires use of the main thread.
  static var lastActive: PlayerCore {
    get {
      return _lastActive ?? active
    }
    set {
      _lastActive = newValue
    }
  }

  /// - Important: Code referencing this property **must** be run on the main thread because it references
  ///              [NSApplication.mainWindow`](https://developer.apple.com/documentation/appkit/nsapplication/1428723-mainwindow)
  static var active: PlayerCore {
    if let wc = NSApp.mainWindow?.windowController as? PlayerWindowController {
      return wc.player
    } else {
      return first
    }
  }

  static var newPlayerCore: PlayerCore {
    return findIdlePlayerCore() ?? createPlayerCore()
  }

  static var activeOrNew: PlayerCore {
    if playerCores.isEmpty {
      return first
    }
    if Preference.bool(for: .alwaysOpenInNewWindow) {
      return newPlayerCore
    } else {
      return active
    }
  }

  static var nonIdle: [PlayerCore] {
    return playerCores.filter { $0.info.state != .idle }
  }

  static var playerCores: [PlayerCore] = []
  static private var playerCoreCounter = 0

  static private func findIdlePlayerCore() -> PlayerCore? {
    playerCores.first { $0.info.state == .idle && !$0.backgroundTaskInUse && $0.opensFindingFiles.isEmpty }
  }

  static private func createPlayerCore() -> PlayerCore {
    let pc = PlayerCore()
    pc.label = "\(playerCoreCounter)"
    playerCores.append(pc)
    pc.startMPV()
    pc.loadPlugins()
    playerCoreCounter += 1
    return pc
  }

  static func activeOrNewForMenuAction(isAlternative: Bool) -> PlayerCore {
    let useNew = Preference.bool(for: .alwaysOpenInNewWindow) != isAlternative
    return useNew ? newPlayerCore : active
  }

  /**
   Opens the URLs in the right window or windows, depending on user settings.

   The files are found off the main thread, so they are opened after this returns.

   - Parameter completion: Called on the main thread once the files have been opened, with `nil`
   if no further action is needed, like opened a BD Folder; otherwise the count of playable files.
   */
  static func openURLs(_ urls: [URL], completion: ((Int?) -> Void)? = nil) {
    let openInCurrentWindow = !Preference.bool(for: .alwaysOpenInNewWindow)
    if openInCurrentWindow {
      // open all urls in the active window if any (or, all in one new window)
      activeOrNew.openURLs(urls, completion: completion)
    } else if
      urls.count > 1,
      Preference.bool(for: .groupSimultaneousOpensInPlaylist)
    {
      // create new window, open all urls in that window
      // this purposefully ignores `allowDuplicatePlayers`
      newPlayerCore.openURLs(urls, completion: completion)
    } else {
      // open each url in its own new window. accumulate the open results, which come on the main thread
      var result: Int? = nil
      // The opens not yet finished, plus one until every url has been handed out.
      var unfinished = 1
      let finish = { (openResult: Int?) in
        if let openResult {
          result = (result ?? 0) + openResult
        }
        unfinished -= 1
        if unfinished == 0 {
          completion?(result)
        }
      }
      for url in urls {
        // skip if url is already open in some player
        if !Preference.bool(for: .allowDuplicatePlayers) {
          let activePlayerCores = playerCores.filter { $0.info.state != .idle }
          let relevantActivePlayerCore = activePlayerCores.first { $0.info.currentURL == url }

          if let relevantActivePlayerCore {
            relevantActivePlayerCore.currentController.window?.makeKeyAndOrderFront(nil)
            continue
          }
          // A player whose open of this url is still finding its files stays idle until it shows the url.
          if playerCores.contains(where: { $0.opensFindingFiles.contains { $0.contains(url) } }) {
            continue
          }
        }

        // open url, combine open result into the result
        unfinished += 1
        newPlayerCore.openURLs([url], completion: finish)
      }
      finish(nil)
    }
  }

  // MARK: - Fields

  private var observers: [NSObjectProtocol] = []

  lazy var subsystem = Logger.makeSubsystem("player\(label!)", ["play.circle"])

  func log(_ message: @autoclosure () -> String, level: Logger.Level = .debug) {
    Logger.log(message, level: level, subsystem: subsystem)
  }

  var label: String!
  var isManagedByPlugin = false
  var userLabel: String?
  var disableUI = false
  var disableWindowAnimation = false

  var touchBarSupport: TouchBarSupport {
    get {
      return self._touchBarSupport as! TouchBarSupport
    }
  }
  private var _touchBarSupport: Any?

  /// `true` if this Mac is _known to_ have a  [Touch Bar](https://support.apple.com/guide/mac-help/use-the-touch-bar-mchlbfd5b039/mac).
  ///
  /// In order to adhere to energy efficiency best practices IINA should stop the timer that synchronizes the UI when it is not needed.
  /// As one job of the timer is to update the Touch Bar on Macs that have one, IINA needs information such as:
  /// - Does this host have a Touch Bar?
  /// - Is the Touch Bar configured to show app controls?
  /// - Is the Touch Bar awake?
  /// - Is the host being operated in closed clamshell mode?
  ///
  /// This is the kind of information needed to avoid running the timer and updating controls that are not visible. Unfortunately in the
  /// documentation for [NSTouchBar](https://developer.apple.com/documentation/appkit/nstouchbar) Apple
  /// indicates "There’s no need, and no API, for your app to know whether or not there’s a Touch Bar available". So this property is
  /// set based off whether `AppKit` has requested that a `NSTouchBar` object be created by calling
  /// [MakeTouchBar](https://developer.apple.com/documentation/appkit/nsresponder/2544690-maketouchbar).
  /// This property is used to avoid running the timer on Macs that do not have a Touch Bar. It also may avoid running the timer when a
  /// MacBook with a Touch Bar is being operated in closed clamshell mode as `AppKit` will not call `MakeTouchBar` when the
  /// Touch Bar is asleep.
  var needsTouchBar = false

  /// A dispatch queue for auto load feature.
  let backgroundQueue: DispatchQueue
  let playlistQueue: DispatchQueue
  let thumbnailQueue: DispatchQueue
  /// A serial queue for finding the files to open, so that successive opens keep the order they were asked in.
  let openQueue: DispatchQueue

  /**
   This ticket will be increased each time before a new task being submitted to `backgroundQueue`.

   Each task holds a copy of ticket value at creation, so that a previous task will perceive and
   quit early if new tasks is awaiting.

   **See also**:

   `autoLoadFilesInCurrentFolder(ticket:)`
   */
  @Atomic var backgroundQueueTicket = 0

  /// Identifies the playlist of the opened file. The task matching the files in the folder of the opened file, which adds them to
  /// the playlist, holds a copy of the ticket value at creation.
  let folderPlaylistTicket = FolderPlaylistTicket()

  enum TicketExpiredError: Error {
    case ticketExpired
  }

  private var backgroundTaskInUse = false

  /// The URLs of each open finding its files on the queue for opening files, in the order the opens were asked. The player stays
  /// idle until they open the files, and is not handed out as an idle player in the meantime. Read and written on the main thread.
  private(set) var opensFindingFiles: [[URL]] = []

  var initialWindow: InitialWindowController!

  var mainWindow: MainWindowController!
  var miniPlayer: MiniPlayerWindowController!

  var currentController: PlayerWindowController {
    return isInMiniPlayer ? miniPlayer : mainWindow
  }

  var currentWindow: NSWindow? {
    currentController.window
  }

  var mpv: MPVController!

  var receivedEndFileWhileLoading: Bool = false

  var plugins: [JavascriptPluginInstance] = []
  private var pluginMap: [String: JavascriptPluginInstance] = [:]
  var events = EventController()

  /// The controller that generates thumbnails.
  ///
  /// Thumbnail generation is cancelled from the thread of the queue for reading `mpv` events as well as from the main thread,
  /// so the controller is created with the player and not on first use.
  let ffmpegController = FFmpegController()

  lazy var info: PlaybackInfo = PlaybackInfo(self)

  var syncUITimer: Timer?

  var displayOSD: Bool = true

  var isInMiniPlayer = false
  /// Set this to `true` if user changes "music mode" status manually. This disables `autoSwitchToMusicMode`
  /// functionality for the duration of this player even if the preference is `true`. But if they manually change the
  /// "music mode" status again, change this to `false` so that the preference is honored again.
  var overrideAutoSwitchToMusicMode = false

  var isSearchingOnlineSubtitle = false

  /// For supporting mpv `--shuffle` arg, to shuffle playlist when launching from command line
  @Atomic private var shufflePending = false

  // test seeking
  var triedUsingExactSeekForCurrentFile: Bool = false
  var useExactSeekForCurrentFile: Bool = true

  var isPlaylistVisible: Bool {
    isInMiniPlayer ? miniPlayer.isPlaylistVisible : mainWindow.sidebars.isShowing(.playlist)
  }

  /// The A loop point established by the [mpv](https://mpv.io/manual/stable/) A-B loop command.
  var abLoopA: Double {
    /// Returns the value of the A loop point, a timestamp in seconds if set, otherwise returns zero.
    /// - Note: The value of the A loop point is not required by mpv to be before the B loop point.
    /// - Returns:value of the mpv option `ab-loop-a` as mpv last reported it
    get { info.abLoopA }
    /// Sets the value of the A loop point as an absolute timestamp in seconds.
    ///
    /// The loop points of the mpv A-B loop command can be adjusted at runtime. This method updates the A loop point. Setting a
    /// loop point to zero disables looping, so this method will adjust the value so it is not equal to zero in order to require use of the
    /// A-B command to disable looping.
    /// - Precondition: The A loop point must have already been established using the A-B loop command otherwise the attempt
    ///     to change the loop point will be ignored.
    /// - Note: The value of the A loop point is not required by mpv to be before the B loop point.
    set {
      guard info.abLoopStatus == .aSet || info.abLoopStatus == .bSet else { return }
      mpv.setDoubleAsync(MPVOption.PlaybackControl.abLoopA, max(PlayerCore.minLoopPointTime, newValue))
    }
  }

  /// The B loop point established by the [mpv](https://mpv.io/manual/stable/) A-B loop command.
  var abLoopB: Double {
    /// Returns the value of the B loop point, a timestamp in seconds if set, otherwise returns zero.
    /// - Note: The value of the B loop point is not required by mpv to be after the A loop point.
    /// - Returns:value of the mpv option `ab-loop-b` as mpv last reported it
    get { info.abLoopB }
    /// Sets the value of the B loop point as an absolute timestamp in seconds.
    ///
    /// The loop points of the mpv A-B loop command can be adjusted at runtime. This method updates the B loop point. Setting a
    /// loop point to zero disables looping, so this method will adjust the value so it is not equal to zero in order to require use of the
    /// A-B command to disable looping.
    /// - Precondition: The B loop point must have already been established using the A-B loop command otherwise the attempt
    ///     to change the loop point will be ignored.
    /// - Note: The value of the B loop point is not required by mpv to be after the A loop point.
    set {
      guard info.abLoopStatus == .bSet else { return }
      mpv.setDoubleAsync(MPVOption.PlaybackControl.abLoopB, max(PlayerCore.minLoopPointTime, newValue))
    }
  }

  var isABLoopActive: Bool {
    abLoopA != 0 && abLoopB != 0 && info.abLoopCount != "0"
  }

  /// Whether to only use the URL's filename when calculating the mpv
  /// [Watch Later](https://mpv.io/manual/stable/#watch-later) MD5 sum.
  ///
  /// This supports the mpv
  /// [ignore-path-in-watch-later-config](https://mpv.io/manual/stable/#options-ignore-path-in-watch-later-config)
  /// option. As this option is only used by advanced users there is intentionally no support in IINA's UI for this option. This is also an
  /// option that you would set and not change as changing it means existing watch later files will no longer be found. For this reason
  /// IINA does not support dynamic changes to this option. The value of this option is read once `mpv` is initialized, without waiting
  /// for `mpv`, and stored when `mpv` answers, which is before it reports any file started. Setting this option requires IINA to be
  /// restarted.
  @Atomic var ignorePathInWatchLaterConfig = false

  /// The window geometry of mpv's `geometry` option, read once `mpv` is initialized without waiting for `mpv` and stored when `mpv`
  /// answers, which is before it reports any video size.
  @Atomic private var configuredGeometry: GeometryDef?

  /// Store the options `mpv` answered once it was initialized.
  func storeConfiguredOptions(ignorePathInWatchLaterConfig ignorePath: Bool, geometry: String) {
    if ignorePath {
      log("Will use filename instead of path when calculating watch later MD5 sum")
    }
    ignorePathInWatchLaterConfig = ignorePath
    configuredGeometry = GeometryDef.parse(geometry)
  }

  /// Whether to auto load files when opening the URL given in `pendingUrl`.
  private var pendingAutoLoad = false

  /// URL to open once an outstanding mpv stop command completes.
  private var pendingUrl: URL?

  let playerNumber: Int

  static var keyBindings: [String: KeyMapping] = [:]

  override init() {
    playerNumber = PlayerCore.playerCoreCounter
    backgroundQueue = DispatchQueue(label: "IINAPlayerCoreTask\(playerNumber)", qos: .background)
    playlistQueue = DispatchQueue(label: "IINAPlaylistTask\(playerNumber)", qos: .utility)
    thumbnailQueue = DispatchQueue(label: "IINAPlayerCoreThumbnailTask\(playerNumber)", qos: .utility)
    openQueue = DispatchQueue(label: "IINAPlayerCoreOpenTask\(playerNumber)", qos: .userInitiated)
    super.init()
    ffmpegController.delegate = self
    self.mpv = MPVController(playerCore: self)
    self.mainWindow = MainWindowController(playerCore: self)
    self.miniPlayer = MiniPlayerWindowController(playerCore: self)
    self.initialWindow = InitialWindowController(playerCore: self)
    self._touchBarSupport = TouchBarSupport(playerCore: self)
    TouchBarSettings.shared.addObserver(self, forKey: .PresentationModeFnModes)
    TouchBarSettings.shared.addObserver(self, forKey: .PresentationModeGlobal)
    TouchBarSettings.shared.addObserver(self, forKey: .PresentationModePerApp)
  }

  func observe(_ name: Notification.Name, block: @escaping (Notification) -> Void) {
    observers.append(NotificationCenter.default.addObserver(
      forName: name, object: self, queue: .main, using: block))
  }

  deinit {
    observers.forEach {
      NotificationCenter.default.removeObserver($0)
    }
  }

  // MARK: - Plugins

  static func reloadPluginForAll(_ plugin: JavascriptPlugin, forced: Bool = false) {
    playerCores.forEach { $0.reloadPlugin(plugin, forced: forced) }
    AppDelegate.shared.menuController?.updatePluginMenu()
  }

  func clearPlugins() {
    pluginMap.removeAll()
    plugins.removeAll()
  }

  func loadPlugins() {
    pluginMap.removeAll()
    plugins = JavascriptPlugin.plugins.compactMap { plugin in
      guard plugin.enabled else { return nil }
      let instance = JavascriptPluginInstance(player: self, plugin: plugin)
      pluginMap[plugin.identifier] = instance
      return instance
    }
  }

  func reloadPlugin(_ plugin: JavascriptPlugin, forced: Bool = false) {
    let id = plugin.identifier
    if let _ = pluginMap[id] {
      if plugin.enabled {
        // no need to reload, unless forced
        guard forced else { return }
        pluginMap[id] = JavascriptPluginInstance(player: self, plugin: plugin)
      } else {
        pluginMap.removeValue(forKey: id)
      }
    } else {
      guard plugin.enabled else { return }
      pluginMap[id] = JavascriptPluginInstance(player: self, plugin: plugin)
    }

    plugins = JavascriptPlugin.plugins.compactMap { pluginMap[$0.identifier] }
    mainWindow.sidebars.pluginView.updatePluginTabs()
  }

  // MARK: - Control

  private func open(_ url: URL?, shouldAutoLoad: Bool = false) {
    guard let url else {
      log("empty file path or url", level: .error)
      return
    }
    guard info.state != .stopping else {
      // The mpv core is currently processing an asynchronous stop command. To avoid the complexity
      // of coordinating two mpv commands executing at the same time, wait until the stop command
      // finishes and the core becomes idle before sending the loadfile command. The stop command
      // normally does not take long to complete, so this should not be noticeable to the user.
      log("Waiting for stop command to finish before opening: \(url.absoluteString)")
      pendingAutoLoad = shouldAutoLoad
      pendingUrl = url
      return
    }
    let isNetwork = !url.isFileURL || url.pathExtension.starts(with: "m3u")
    if isNetwork, info.state != .idle, let currentWindow {
      // Replace the player window with the loading window. Closing the player window will result in
      // an asynchronous stop command being sent to mpv. As described above, delay sending the
      // loadfile command until the stop command finishes.
      log("Closing window before opening: \(url.absoluteString)")
      pendingAutoLoad = shouldAutoLoad
      pendingUrl = url
      currentWindow.close()
      return
    }
    log("Open URL: \(url.absoluteString)")
    if shouldAutoLoad {
      info.shouldAutoLoadFiles = true
    }
    info.hdrEnabled = Preference.bool(for: .enableHdrSupport)
    let path = url.isFileURL ? url.path : url.absoluteString
    openMainWindow(path: path, url: url, isNetwork: isNetwork)
  }

  /**
   Open a list of urls. If there are more than one urls, add the remaining ones to
   playlist and disable auto loading.

   The files are found on the queue for opening files, which reads the filesystem, so they are
   opened after this returns.

   - Parameter completion: Called on the main thread once the files have been opened, with `nil`
   if no further action is needed, like opened a BD Folder; otherwise the count of playable files.
   */
  func openURLs(_ urls: [URL], shouldAutoLoad autoLoad: Bool = true, completion: ((Int?) -> Void)? = nil) {
    guard !urls.isEmpty else {
      completion?(0)
      return
    }
    opensFindingFiles.append(urls)
    openQueue.async { [self] in
      let urls = Utility.resolveURLs(urls)

      // Handle folder URL (to support mpv shuffle, etc), BD folders and m3u / m3u8 files first.
      // For these cases, mpv will load/build the playlist and notify IINA when it can be retrieved.
      if urls.count == 1 {
        let url = urls[0]

        if isBDFolder(url)
            || Utility.playlistFileExt.contains(url.absoluteString.lowercasedPathExtension) {
          DispatchQueue.main.async { [self] in
            opensFindingFiles.removeFirst()
            info.shouldAutoLoadFiles = false
            open(url)
            completion?(nil)
          }
          return
        }
      }

      let playableFiles = getPlayableFiles(in: urls)
      // The player and its windows are changed on the main thread.
      DispatchQueue.main.async { [self] in
        opensFindingFiles.removeFirst()
        let count = playableFiles.count

        // check playable files count
        if count == 0 {
          completion?(0)
          return
        }

        if !autoLoad {
          info.shouldAutoLoadFiles = false
        } else {
          info.shouldAutoLoadFiles = (count == 1)
        }

        // open the first file
        open(playableFiles[0])
        // add the remaining to playlist. Like the load file command open sends, this does not wait for mpv, so mpv adds them after
        // loading the first file.
        playableFiles[1..<count].forEach { url in
          mpv.playlistAppendAsync(url.isFileURL ? url.path : url.absoluteString)
        }

        // refresh playlist
        postNotification(.iinaPlaylistChanged)
        // send OSD
        if count > 1 {
          sendOSD(.addToPlaylist(count))
        }
        completion?(count)
      }
    }
  }

  func openURL(_ url: URL, shouldAutoLoad: Bool = true, completion: ((Int?) -> Void)? = nil) {
    openURLs([url], shouldAutoLoad: shouldAutoLoad, completion: completion)
  }

  func openURLString(_ str: String) {
    if str == "-" {
      openMainWindow(path: str, url: URL(string: "stdin")!, isNetwork: false)
      return
    }
    if str.first == "/" {
      openURL(URL(fileURLWithPath: str))
    } else {
      // For apps built with Xcode 15 or later the behavior of the URL initializer has changed when
      // running under macOS Sonoma or later. The behavior now matches URLComponents and will
      // automatically percent encode characters. Must not apply percent encoding to the string
      // passed to the URL initializer if the new new behavior is active.
      var performPercentEncoding = true
#if compiler(>=5.9)
      if #available(macOS 14, *) {
        performPercentEncoding = false
      }
#endif
      var pstr = str
      if performPercentEncoding {
        guard let encoded = str.addingPercentEncoding(withAllowedCharacters: .urlAllowed) else {
          log("Cannot add percent encoding for \(str)", level: .error)
          return
        }
        pstr = encoded
      }
      guard let url = URL(string: pstr) else {
        log("Cannot parse url for \(pstr)", level: .error)
        return
      }
      openURL(url)
    }
  }

  /// Open the given media in the main window.
  /// - Important: This method will ensure playback is paused before running the load command. If playback is not paused, audio
  ///     can start playing before video is shown. This is most noticeable with high resolution videos encoded with newer high
  ///     compression codecs (such as AV1), when running on older Macs that lack support for hardware decoding of the codec
  ///     used. Playback will be started once the video has been loaded and the size of the video is known (unless the "Pause"
  ///     setting is enabled under "When media is opened"). Playback is only paused before loading when media is manually opened
  ///     by the user in order to not disrupt gapless audio.
  /// - Parameters:
  ///   - path: Path to the media to open.
  ///   - url: URL of the media to open.
  ///   - isNetwork: Whether the media must be streamed over the network.
  private func openMainWindow(path: String, url: URL, isNetwork: Bool) {
    log("Opening \(path) in main window")
    info.currentURL = url
    info.mpvMd5 = Utility.mpvWatchLaterMd5(url, ignorePathInWatchLaterConfig)
    info.isNetworkResource = isNetwork
    info.audioTracks = []
    info.chapters = []
    info.playlist = []
    info.isShuffled = false
    info.subTracks = []
    info.thumbnails = []
    info.thumbnailsReady = false
    info.videoDuration = nil
    info.videoHeight = nil
    info.videoPosition = nil
    info.videoTracks = []
    info.videoWidth = nil
    if isNetwork {
      AppDelegate.shared.openURLWindow.showLoadingScreen(playerCore: self)
    }

    let _ = mainWindow.window
    mainWindow.pendingShow = true
    miniPlayer.pendingShow = true
    initialWindow.close()

    // Neither this pause nor force-window below waits for mpv, so that main never waits for it. Pausing paused
    // playback changes nothing, so whether playback is paused is not read. mpv runs these requests before the
    // load command below, which does not wait for it either.
    log("Pausing playback before running load command")
    mpv.setFlagAsync(MPVOption.PlaybackControl.pause, true, level: .verbose)
    info.pausedForLoading = true

#if USE_ICC_PROFILE_AUTO // See VideoView.setICCProfile.
    // If this mpv core is being reused icc-profile-auto may have been left set to true. This option
    // MUST be reset to false to avoid a crash that occurs if the mpv OSD is being used. Another way
    // to fix this would be to add this option to the mpv reset-on-next-file option. However the
    // user might override IINA and set that option themselves and not include icc-profile-auto.
    // Better to directly reset icc-profile-auto. See issue #5727 for details.
    // Does not wait for mpv, which resets it before the load command below.
    mpv.setFlagAsync(MPVOption.GPURendererOptions.iccProfileAuto, false)
#endif

    // Delay force-window until an actual file load to avoid Xcode-launched app startup hanging
    // while mpv tries to create a VO before IINA has entered its normal media-open path.
    mpv.asyncCommand(.set, args: [MPVOption.Window.forceWindow, "yes"], checkError: false, replyUserdata: 0,
                     level: .verbose)

    // The load file command replaces the playlist. Stop adding the files in the folder of the file
    // previously opened to the playlist.
    folderPlaylistTicket.abandon()

    // Send load file command
    info.justOpenedFile = true
    info.state = .loading
    // Does not wait for mpv, so mpv loads the file after the requests above and before the files openURLs adds to the playlist
    // after it. A load mpv refuses to take is checked as a waiting command checks it.
    mpv.asyncCommand(.loadfile, args: [path], replyUserdata: 0, level: .verbose)

    if Preference.bool(for: .autoRepeat) {
      let loopMode = Preference.DefaultRepeatMode(rawValue: Preference.integer(for: .defaultRepeatMode))
      // Like the load file command, this does not wait for mpv, which sets the loop after it.
      setLoopMode(loopMode == .file ? .file : .playlist)
    }
  }

  static func loadKeyBindings() {
    Logger.log("Loading key bindings")
    let userConfigs = PrefKeyBindingViewController.userConfigs
    let iinaDefaultConfPath = PrefKeyBindingViewController.defaultConfigs["IINA Default"]!
    var inputConfPath = iinaDefaultConfPath
    if let confFromUd = Preference.string(for: .currentInputConfigName) {
      if let currentConfigFilePath = Utility.getFilePath(Configs: userConfigs, forConfig: confFromUd, showAlert: false) {
        inputConfPath = currentConfigFilePath
      }
    }
    setKeyBindings(KeyMapping.parseInputConf(at: inputConfPath) ?? KeyMapping.parseInputConf(at: iinaDefaultConfPath)!)
  }

  static func setKeyBindings(_ keyMappings: [KeyMapping]) {
    Logger.log("Set key bindings (\(keyMappings.count) mappings)")
    // If multiple bindings map to the same key, choose the last one
    var keyBindingsDict: [String: KeyMapping] = [:]
    var orderedKeyList: [String] = []
    keyMappings.forEach {
      if $0.rawKey == "default-bindings" && $0.action.count == 1 && $0.action[0] == "start" {
        Logger.log("Skipping line: \"default-bindings start\"", level: .verbose)
      } else if let kb = filterSectionBindings($0) {
        let key = kb.normalizedMpvKey
        if keyBindingsDict[key] == nil {
          orderedKeyList.append(key)
        }
        keyBindingsDict[key] = kb
      }
    }
    PlayerCore.keyBindings = keyBindingsDict

    // For menu item bindings, filter duplicate keys as above, but preserve order
    var kbUniqueOrderedList: [KeyMapping] = []
    for key in orderedKeyList {
      kbUniqueOrderedList.append(keyBindingsDict[key]!)
    }

    AppDelegate.shared.menuController.updateKeyEquivalentsFrom(kbUniqueOrderedList)

    NotificationCenter.default.post(Notification(name: .iinaGlobalKeyBindingsChanged, object: kbUniqueOrderedList))
  }

  static private func filterSectionBindings(_ kb: KeyMapping) -> KeyMapping? {
    guard let section = kb.section else {
      return kb
    }

    if section == "default" {
      // Drop "{default}" because it is unnecessary and will get in the way of libmpv command execution
      let newRawAction = Array(kb.action.dropFirst()).joined(separator: " ")
      return KeyMapping(rawKey: kb.rawKey, rawAction: newRawAction, isIINACommand: kb.isIINACommand, comment: kb.comment)
    } else {
      Logger.log("Skipping binding from section \"\(section)\": \(kb.rawKey)", level: .verbose)
      return nil
    }
  }

  func startMPV() {
    // set path for youtube-dl
    let oldPath = String(cString: getenv("PATH")!)
    var path = Utility.exeDirURL.path + ":" + oldPath
    if let customYtdlPath = Preference.string(for: .ytdlSearchPath), !customYtdlPath.isEmpty {
      path = customYtdlPath + ":" + path
    }
    setenv("PATH", path, 1)
    log("Set path to \(path)")

    // set http proxy
    if let proxy = Preference.string(for: .httpProxy), !proxy.isEmpty {
      setenv("http_proxy", "http://" + proxy, 1)
      log("Set http_proxy to \(proxy)")
    }

    mpv.mpvInit()
    events.emit(.mpvInitialized)

    checkConfiguredAudioDevice()
  }

  /// Use the `auto` audio device when `mpv` does not list the audio device configured in settings, reading the list without waiting
  /// for `mpv`.
  func checkConfiguredAudioDevice() {
    let audioDevice = Preference.string(for: .audioDevice)!
    mpv.getNodeAsync(MPVProperty.audioDeviceList) { [self] list in
      guard !audioDevices(in: list as? [[String: String]] ?? []).contains(where: { $0.name == audioDevice }) else { return }
      log("Audio device configured in settings not found, will default to auto:\n  \(audioDevice)")
      setAudioDevice("auto")
    }
  }

  func initVideo() {
    // init mpv render context.
    mpv.mpvInitRendering()
    // `force-window=immediate` makes audio-only subtitle rendering work with `vo=libmpv`,
    // but setting it before render initialization can race the VO thread against IINA's
    // render context setup. Switch to `immediate` only after the render context exists.
    mpv.setString(MPVOption.Window.forceWindow, "immediate", level: .verbose)
    mainWindow.videoView.startDisplayLink()
    log("Initialized rendering")
    MemoryUsage.shared.logUsage("after rendering initialized")
  }

  // unload main window video view
  func uninitVideo() {
    guard mainWindow.loaded else { return }
    mainWindow.videoView.uninit()
  }

  private func savePlayerState() {
    savePlaybackPosition()
    refreshSyncUITimer()
  }

  /// Initiate shutdown of this player.
  ///
  /// This method is intended to only be used during application termination. Once shutdown has been initiated player methods
  /// **must not** be called.
  /// - Important: As a part of shutting down the player this method sends a quit command to mpv. Even though the command is
  ///     sent to mpv using the synchronous API mpv executes the quit command asynchronously. The player is not fully shutdown
  ///     until mpv finishes executing the quit command and shuts down.
  /// - Note: If the user clicks on `Quit` right after starting to play a video then the background task may still be running and
  ///     loading files into the playlist and adding subtitles. If that is the case then the background task **must be** stopped before
  ///     sending a `quit` command to mpv. If the background task is allowed to access mpv after a `quit` command has been
  ///     sent mpv could crash. The `stop` method takes care of instructing the background task to stop and will wait for it to stop
  ///     before sending a `stop` command to mpv. _However_ mpv will stop on its own if the end of the video is reached. When
  ///     that happens while IINA is quitting then this method may be called with the background task still running. If the background
  ///     task is still running this method only changes the player state. When the background task ends it will notice that shutting
  ///     down was in progress and will call this method again to continue the process of shutting down..
  func shutdown() {
    info.state = .shuttingDown
    guard !backgroundTaskInUse else { return }
    log("Shutting down")
    savePlayerState()
    mpv.mpvQuit()
  }

  /// Notify the task running in the background queue it should stop.
  ///
  /// The background queue will be instructed to stop by invalidating the ticket it owns. The background task polls the current ticket
  /// and eventually will notice it has changed and will abandon its work.
  private func stopBackgroundTask() {
    log("Stopping background task")
    $backgroundQueueTicket.withLock { $0 += 1 }
    folderPlaylistTicket.abandon()
  }

  /// Respond to the mpv core shutting down.
  /// - Important: Normally shutdown of the mpv core occurs after IINA has sent a `quit` command to the mpv core and that
  ///     asynchronous command completes. _However_ this can also occur when the user uses mpv's IPC interface to send a quit
  ///     command directly to mpv. Accessing a mpv core after it has shutdown is not permitted by mpv and can trigger a crash.
  ///     When IINA is in control of the termination sequence it is able to prevent access to the mpv core. For example, observers are
  ///     removed before sending the `quit` command. But when shutdown is initiated by mpv the actions IINA takes before
  ///     shutting down mpv are bypassed. This means a mpv initiated shutdown can't be made fully deterministic as there are inherit
  ///     windows of vulnerability that can not be fully closed. IINA has no choice but to support a mpv initiated shutdown as best it
  ///     can.
  func mpvHasShutdown() {
    let isMPVInitiated = info.state != .shuttingDown
    let suffix = isMPVInitiated ? " (initiated by mpv)" : ""
    log("Player has shutdown\(suffix)")
    info.state = .shutDown
    if isMPVInitiated {
      // The user must have used mpv's IPC interface to send a quit command directly to mpv. Must
      // perform the actions that were skipped when IINA's normal shutdown process was bypassed.
      if backgroundTaskInUse {
        stopBackgroundTask()
      }
      mpv.removeObservers()
      savePlayerState()
    }
    uninitVideo()
    postNotification(.iinaPlayerShutdown)
    if isMPVInitiated {
      // Initiate application termination. AppKit requires this be done from the main thread,
      // however the main dispatch queue must not be used to avoid blocking the queue as per
      // instructions from Apple.
      RunLoop.main.perform(inModes: [.common]) {
        NSApp.terminate(nil)
      }
    }
  }

  /// Switch the current player to mini player from the main window.
  ///
  /// - Parameters:
  ///     - showMiniPlayer: set to false when this function is called when tracklist is changed.
  ///     In this case, wait for `MPV_EVENT_VIDEO_RECONFIG` to show the mini player.
  ///
  /// This function is called:
  /// 1) On `trackListChanged`, it will check the current media and settings to determine whether
  /// or not to switch to mini player automatically
  /// 2) On user initiated button actions
  ///
  func switchToMiniPlayer(automatically: Bool = false, showMiniPlayer: Bool = true) {
    log("Switch to mini player, automatically=\(automatically)")
    if !automatically {
      // Toggle manual override
      overrideAutoSwitchToMusicMode = !overrideAutoSwitchToMusicMode
      Logger.log("Changed overrideAutoSwitchToMusicMode to \(overrideAutoSwitchToMusicMode)",
                 level: .verbose, subsystem: subsystem)
    }

    // The call to orderOut handles being in full screen mode if using the AppKit supplied full
    // screen mode, but if legacy full screen mode is being used then IINA needs to handle it.
    if mainWindow.fsState.isFullscreen, Preference.bool(for: .useLegacyFullScreen) {
      mainWindow.toggleWindowFullScreen()
    }
    // hide main window
    mainWindow.window?.orderOut(self)

    let needRestoreLayout = !miniPlayer.loaded
    let _ = miniPlayer.window

    miniPlayer.updateTitle()
    refreshSyncUITimer()
    let playlistView = mainWindow.sidebars.playlistView
    // force initialize the view
    let _ = playlistView.view
    let videoView = mainWindow.videoView
    // reset down shift for playlistView
    mainWindow.sidebars.playlistView.downShift = 0
    // hide sidebar
    if mainWindow.sidebars.isAnyVisible {
      mainWindow.sidebars.hideAllSideBars(animate: false)
    }

    // move playlist view
    playlistView.view.removeFromSuperview()
    miniPlayer.playlistWrapperView.addSubview(playlistView.view)
    playlistView.view.padding(.all)
    // move video view
    mainWindow.liveText.clearAnalysis()
    videoView.removeFromSuperview()
    miniPlayer.videoWrapperView.addSubview(videoView, positioned: .below, relativeTo: nil)
    Utility.quickConstraints(["H:|[v]|", "V:|[v]|"], ["v": videoView])

    miniPlayer.refreshArtworkVisibility()
    let (width, height) = miniPlayer.videoSizeForDisplayInMusicMode()
    let aspect = CGFloat(width) / CGFloat(height)
    miniPlayer.updateVideoViewAspectConstraint(withAspect: aspect)
    miniPlayer.window?.layoutIfNeeded()

    // in case of video size changed, reset mini player window size if playlist is folded
    if !miniPlayer.isPlaylistVisible {
      miniPlayer.setToInitialWindowSize(display: true, animate: false)
    }

    isInMiniPlayer = true

    // restore layout
    if needRestoreLayout {
      if !Preference.bool(for: .musicModeShowAlbumArt) {
        miniPlayer.toggleVideoView(self)
        if let origin = miniPlayer.window?.frame.origin {
          miniPlayer.window?.setFrameOrigin(.init(x: origin.x, y: origin.y + miniPlayer.videoView.frame.height))
        }
      }
      if Preference.bool(for: .musicModeShowPlaylist) {
        miniPlayer.togglePlaylist(self)
      }
    }

    currentController.setupUI()

    miniPlayer.pendingShow = true
    if showMiniPlayer {
      notifyWindowVideoSizeChanged()
    }
    mainWindow.forceDraw("entered music mode")
    postNotification(.iinaMusicModeChanged)
    events.emit(.musicModeChanged, data: true)
  }

  /// Switch the current player to main player from the mini player.
  ///
  /// - Parameters:
  ///     - showMainWindow: set to false when this function is called when tracklist is changed.
  ///     In this case, wait for `MPV_EVENT_VIDEO_RECONFIG` to show the main window. Also set to false
  ///     when the mini player is closed.
  ///
  /// This function is called:
  /// 1) On `trackListChanged`, it will check the current media and settings to determine whether
  /// or not to switch to main window automatically
  /// 2) On user initiated button actions
  /// 3) When closing the mini player
  ///
  func switchBackFromMiniPlayer(automatically: Bool = false, showMainWindow: Bool = true) {
    log("Switch to normal window from mini player, automatically=\(automatically)")
    if !automatically {
      overrideAutoSwitchToMusicMode = !overrideAutoSwitchToMusicMode
      Logger.log("Changed overrideAutoSwitchToMusicMode to \(overrideAutoSwitchToMusicMode)",
                 level: .verbose, subsystem: subsystem)
    }
    mainWindow.sidebars.playlistView.view.removeFromSuperview()
    mainWindow.sidebars.playlistView.isInMiniPlayer = false
    // add back video view
    miniPlayer.videoViewAspectConstraint?.isActive = false
    miniPlayer.videoViewAspectConstraint = nil
    mainWindow.addVideoViewToWindow()
    mainWindow.oscFloatingView.updatePosition()

    // hide mini player
    miniPlayer.window?.orderOut(nil)
    isInMiniPlayer = false

    mainWindow.pendingShow = true
    if showMainWindow {
      currentController.setupUI()
      mainWindow.updateTitle()
      notifyWindowVideoSizeChanged()
    }

    mainWindow.forceDraw("exited music mode")
    mainWindow.liveText.requestAnalysis()
    postNotification(.iinaMusicModeChanged)
    events.emit(.musicModeChanged, data: false)
  }

  // MARK: - MPV commands

  func togglePause(_ set: Bool? = nil) {
    PlaylistStepping.togglePause(self)
  }

  /// Pause playback.
  /// - Important: Setting the `pause` property will cause `mpv` to emit a `MPV_EVENT_PROPERTY_CHANGE` event. The
  ///     event will still be emitted even if the `mpv` core is idle. If the setting `Pause when machine goes to sleep` is
  ///     enabled then `PlayerWindowController` will call this method in response to a
  ///     `NSWorkspace.willSleepNotification`. That happens even if the window is closed and the player is idle. In
  ///     response the event handler in `MPVController` will call `VideoView.displayIdle`. The suspicion is that calling this
  ///     method results in a call to `CVDisplayLinkCreateWithActiveCGDisplays` which fails because the display is
  ///     asleep. Thus `setFlag` **must not** be called if the `mpv` core is idle or stopping. See issue
  ///     [#4520](https://github.com/iina/iina/issues/4520)
  func pause() {
    PlaylistStepping.pause(self)
  }

  /// Resume playback.
  /// - Important: Although primary responsibility for ensuring the display link is running when playback is in progress belongs to
  ///     the `pauseChanged` method, this method calls `displayActive` to provide more time for the display link to start up.
  func resume() {
    log("Resuming playback")
    mainWindow.videoView.displayActive()
    // Whether playback reached the end is asked without waiting for mpv. Playback restarts from the start when it did, and resumes,
    // once mpv answers, unless the user paused playback after asking to resume.
    let userPausesBeforeResume = info.userPauseCount
    mpv.getFlagAsync(MPVProperty.eofReached) { [self] eofReached in
      // On main because PlaybackInfo is confined to the main thread, see MPVController.queue.
      DispatchQueue.main.async { [self] in
        guard info.userPauseCount == userPausesBeforeResume else { return }
        if eofReached == true {
          seek(absoluteSecond: 0)
        }
        mpv.setFlagAsync(MPVOption.PlaybackControl.pause, false, level: .verbose)
      }
    }
  }

  /// Stop playback and unload the media.
  ///
  /// This method is called when a window closes. The player may be:
  /// - In one of the "active" states
  /// - In the `idle` state
  /// - In the `shutdown` state
  ///
  /// The player will be in one of the active states if the user closes the window or quits IINA while the video is playing or paused. If the
  /// end of the video is reached then the mpv core will go into the `idle` state. In this case the `stop` command must not be sent
  /// to mpv as the core is already stopped. The player will be in the `shutdown` state if quitting was initiated through mpv. When this
  /// happens the `mpvHasShutdown` method handles tasks required to stop the player. In this case this method has nothing to do.
  /// - Note: If playback is stopped right after starting to play the video then the background task may still be running and loading
  ///     files into the playlist and adding subtitles. If that is the case then the background task must be stopped before sending a
  ///     `stop` command to mpv. This happens asynchronously. This method will invalidate the ticket that the background task
  ///     periodically checks to get the task to end early. When the background task ends it will notice that stopping was in progress
  ///     and call this method again to continue the process of stopping. It is important to stop the background task as if it is still
  ///     running when the mpv core is shutdown it may call into mpv triggering a crash.
  func stop() {
    guard info.state != .shutDown else { return }
    // What mpv is asked is decided now, from the state the player has when asked to stop. The watch later configuration can only
    // be written while the player is active, and a player already stopped is neither paused nor sent a stop command.
    let writesWatchLater = info.state.active
    let stopsPlayback = info.state != .idle
    // Must first stop the background task if it is running. The stop command is sent once it has stopped and calls this again.
    let sendsStop = stopsPlayback && !backgroundTaskInUse
    // mpv is asked without waiting, once it has answered whether it saves the playback position, to write the watch later
    // configuration, to pause playback to free up machine resources when quitting, and to stop, in that order, so that the watch
    // later configuration holds the state playback had.
    savePlaybackPosition { [self] savesPosition in
      // The player is no longer stopping if mpv went idle on its own before answering, after which another file may be opening.
      guard info.state == .stopping else { return }
      if savesPosition && writesWatchLater {
        log("Write watch later config")
        mpv.asyncCommand(.writeWatchLaterConfig, replyUserdata: 0, level: .verbose)
      }
      log("Pausing playback before sending stop command")
      mpv.setFlagAsync(MPVOption.PlaybackControl.pause, true, level: .verbose)
      guard sendsStop else { return }
      mpv.asyncCommand(.stop, replyUserdata: 0, level: .verbose)
    }

    // The player may already be stopped in which case the state must not be set to stopping.
    if stopsPlayback {
      info.state = .stopping
    }

    if backgroundTaskInUse {
      stopBackgroundTask()
      return
    }

    if stopsPlayback {
      log("Stopping playback")
    }
    mainWindow.videoView.stopDisplayLink()
    info.$matchedSubs.withLock { $0.removeAll() }

    // Refresh UI synchronization as it will detect the player is stopping and shutdown the timer.
    refreshSyncUITimer()
  }

  /// Mute or unmute without waiting for `mpv`. With no state given this toggles the state last asked for, which is stored at once
  /// so that a second toggle made before `mpv` reports the first one toggles it back.
  func toggleMute(_ set: Bool? = nil) {
    let newState = set ?? !info.isMuted
    info.isMuted = newState
    mpv.setFlagAsync(MPVOption.Audio.mute, newState)
  }

  func seek(percent: Double, forceExact: Bool = false) {
    var percent = percent
    // mpv will play next file automatically when seek to EOF.
    // We clamp to a Range to ensure that we don't try to seek to 100%.
    // however, it still won't work for videos with large keyframe interval.
    if let duration = info.videoDuration?.second,
      duration > 0 {
      percent = percent.clamped(to: 0..<100)
    }
    let useExact = forceExact ? true : Preference.bool(for: .useExactSeek)
    // The seek is sent without waiting for mpv, so that the slider moving it never holds up the main thread.
    let args = FullLength.seekArguments(percent: percent, fullLength: info.fullLength, exact: useExact)
    mpv.asyncCommand(.seek, args: args, checkError: false, replyUserdata: 0, level: .verbose)
  }

  func seek(relativeSecond: Double, option: Preference.SeekOption, byScrolling: Bool = false) {
    switch option {

    case .relative:
      seek(relativeSecond, mode: "relative", byScrolling: byScrolling, level: .verbose)

    case .exact:
      seek(relativeSecond, mode: "relative+exact", byScrolling: byScrolling)

    case .auto:
      // for each file , try use exact and record interval first
      if !triedUsingExactSeekForCurrentFile {
        mpv.recordedSeekTimeListener = { [unowned self] interval in
          // if seek time < 0.05, then can use exact
          self.useExactSeekForCurrentFile = interval < 0.05
        }
        mpv.needRecordSeekTime = true
        triedUsingExactSeekForCurrentFile = true
      }
      let seekMode = useExactSeekForCurrentFile ? "relative+exact" : "relative"
      seek(relativeSecond, mode: seekMode, byScrolling: byScrolling)

    }
  }

  /// Send mpv the command to seek by the given number of seconds, asynchronously so that the main thread does not wait for mpv.
  ///
  /// A seek issued by a scroll carries the scroll-seek userdata. `MPVController` receives mpv's reply to it ahead of the seek the
  /// command causes, which lets it tell when that seek ends the file by running past its end. Any other seek carries userdata 0,
  /// which has no reply callback.
  private func seek(_ relativeSecond: Double, mode: String, byScrolling: Bool, level: Logger.Level = .debug) {
    mpv.asyncCommand(.seek, args: ["\(relativeSecond)", mode], checkError: false,
                     replyUserdata: byScrolling ? MPVController.UserData.scrollSeek : 0, level: level)
  }

  /// Send mpv the command to seek to the given time, asynchronously so that the main thread does not wait for mpv.
  func seek(absoluteSecond: Double) {
    mpv.asyncCommand(.seek, args: ["\(absoluteSecond)", "absolute+exact"], replyUserdata: 0)
  }

  func frameStep(backwards: Bool) {
    // When playback is paused the display link is stopped in order to avoid wasting energy on
    // It must be running when stepping to avoid slowdowns caused by mpv waiting for IINA to call
    // mpv_render_report_swap.
    mainWindow.videoView.displayActive()
    mpv.asyncCommand(backwards ? .frameBackStep : .frameStep, replyUserdata: 0)
  }

  /// Takes a screenshot, attempting to augment mpv's `screenshot` command with additional functionality & control, for example
  /// the ability to save to clipboard instead of or in addition to file, and displaying the screenshot's thumbnail via the OSD.
  /// Returns `true` if a command was sent to mpv; `false` if no command was sent.
  ///
  /// If the prefs for `Preference.Key.screenshotSaveToFile` and `Preference.Key.screenshotCopyToClipboard` are both `false`,
  /// this function does nothing and returns `false`.
  ///
  /// ## Determining screenshot flags
  /// If `keyBinding` is present, it should contain an mpv `screenshot` command. If its action includes any flags, they will be
  /// used. If `keyBinding` is not present or its command has no flags, the value for `Preference.Key.screenshotIncludeSubtitle` will
  /// be used to determine the flags:
  /// - If `true`, the command `screenshot subtitles` will be sent to mpv.
  /// - If `false`, the command `screenshot video` will be sent to mpv.
  ///
  /// Note: IINA overrides mpv's behavior in some ways:
  /// 1. As noted above, if the stored values for `Preference.Key.screenshotSaveToFile` and `Preference.Key.screenshotCopyToClipboard` are
  /// set to false, all screenshot commands will be ignored.
  /// 2. When no flags are given with `screenshot`: instead of defaulting to `subtitles` as mpv does, IINA will use the value for
  /// `Preference.Key.screenshotIncludeSubtitle` to decide between `subtitles` or `video`.
  @discardableResult
  func screenshot(fromKeyBinding keyBinding: KeyMapping? = nil) -> Bool {
    let saveToFile = Preference.bool(for: .screenshotSaveToFile)
    let saveToClipboard = Preference.bool(for: .screenshotCopyToClipboard)
    guard saveToFile || saveToClipboard else {
      log("Ignoring screenshot request: all forms of screenshots are disabled in prefs", level: .warning)
      return false
    }

    guard let vid = info.vid, vid > 0 else {
      log("Ignoring screenshot request: no video stream is being played", level: .warning)
      return false
    }

    log("Screenshot requested by user\(keyBinding == nil ? "" : " (rawAction: \(keyBinding!.rawAction))")")

    var commandFlags: [String] = []

    if let keyBinding {
      var canUseIINAScreenshot = true

      guard let commandName = keyBinding.action.first, commandName == MPVCommand.screenshot.rawValue else {
        log("Cannot take screenshot: unexpected first token in key binding action: \(keyBinding.rawAction)", level: .error)
        return false
      }
      if keyBinding.action.count > 1 {
        commandFlags = keyBinding.action[1].split(separator: "+").map{String($0)}

        for flag in commandFlags {
          switch flag {
          case "window", "subtitles", "video":
            // These are supported
            break
          case "each-frame":
            // Option is not currently supported by IINA's screenshot command
            canUseIINAScreenshot = false
          default:
            // Unexpected flag. Let mpv decide how to handle
            log("Unrecognized flag for mpv 'screenshot' command: '\(flag)'", level: .warning)
            canUseIINAScreenshot = false
          }
        }
      }

      if !canUseIINAScreenshot {
        let returnValue = mpv.command(rawString: keyBinding.rawAction)
        return returnValue == 0
      }
    }

    if commandFlags.isEmpty {
      let includeSubtitles = Preference.bool(for: .screenshotIncludeSubtitle)
      commandFlags.append(includeSubtitles ? "subtitles" : "video")
    }

    mpv.asyncCommand(.screenshot, args: commandFlags, replyUserdata: MPVController.UserData.screenshot)
    return true
  }

  /// Initializes and returns an image object with the contents of the specified URL.
  ///
  /// At this time, the normal [NSImage](https://developer.apple.com/documentation/appkit/nsimage/1519907-init)
  /// initializer will fail to create an image object if the image file was encoded in [JPEG XL](https://jpeg.org/jpegxl/) format.
  /// In older versions of macOS this will also occur if the image file was encoded in [WebP](https://en.wikipedia.org/wiki/WebP/)
  /// format. As these are supported formats for screenshots this method will fall back to using FFmpeg to create the `NSImage` if
  /// the normal initializer fails to return an object.
  /// - Parameter url: The URL identifying the image.
  /// - Returns: An initialized `NSImage` object or `nil` if the method cannot create an image representation from the contents
  ///       of the specified URL.
  private func createImage(_ url: URL) -> NSImage? {
    if let image = NSImage(contentsOf: url) {
      return image
    }
    // The following internal property was added to provide a way to disable the FFmpeg image
    // decoder should a problem be discovered by users running old versions of macOS.
    guard Preference.bool(for: .enableFFmpegImageDecoder) else { return nil }
    Logger.log("Using FFmpeg to decode screenshot: \(url)")
    return FFmpegController.createNSImage(withContentsOf: url)
  }

  func screenshotCallback() {
    let saveToFile = Preference.bool(for: .screenshotSaveToFile)
    let saveToClipboard = Preference.bool(for: .screenshotCopyToClipboard)
    guard saveToFile || saveToClipboard else { return }
    log("Screenshot done: saveToFile=\(saveToFile), saveToClipboard=\(saveToClipboard)", level: .verbose)

    guard let imageFolder = mpv.getString(MPVOption.Screenshot.screenshotDir) else { return }
    guard let lastScreenshotURL = Utility.getLatestScreenshot(from: imageFolder) else { return }
    guard let image = createImage(lastScreenshotURL) else {
      self.sendOSD(.screenshot)
      if !saveToFile {
        try? FileManager.default.removeItem(at: lastScreenshotURL)
      }
      return
    }
    if saveToClipboard {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.writeObjects([image])
    }
    guard Preference.bool(for: .screenshotShowPreview) else {
      self.sendOSD(.screenshot)
      if !saveToFile {
        try? FileManager.default.removeItem(at: lastScreenshotURL)
      }
      return
    }

    DispatchQueue.main.async {
      let osdView = ScreenshootOSDView()
      osdView.setImage(image,
                       size: image.size.shrink(toSize: NSSize(width: 300, height: 200)),
                       fileURL: saveToFile ? lastScreenshotURL : nil)
      self.sendOSD(.screenshot, forcedTimeout: 5, accessoryView: osdView.view, context: osdView)
      if !saveToFile {
        try? FileManager.default.removeItem(at: lastScreenshotURL)
      }
    }
  }

  /// Invoke the [mpv](https://mpv.io/manual/stable/) A-B loop command.
  ///
  /// The A-B loop command cycles mpv through these states:
  /// - Cleared (looping disabled)
  /// - A loop point set
  /// - B loop point set (looping enabled)
  ///
  /// When the command is first invoked it sets the A loop point to the timestamp of the current frame. When the command is invoked
  /// a second time it sets the B loop point to the timestamp of the current frame, activating looping and causing mpv to seek back to
  /// the A loop point. When the command is invoked again both loop points are cleared (set to zero) and looping stops.
  /// - Parameter completion: Called on the main thread with the loop points `mpv` answers once it has run the command.
  func abLoop(then completion: ((_ a: Double, _ b: Double) -> Void)? = nil) {
    // may subject to change
    // Neither the command nor the read of the loop points it sets waits for mpv, which answers them in the order they are asked.
    mpv.asyncCommand(.abLoop, replyUserdata: 0)
    // ab-loop-a and ab-loop-b read as "no" when not set, which is taken as zero, as a read of their values as numbers gives.
    mpv.getNodesAsync([MPVOption.PlaybackControl.abLoopA, MPVOption.PlaybackControl.abLoopB]) { [self] values in
      let a = values[0] as? Double ?? 0, b = values[1] as? Double ?? 0
      DispatchQueue.main.async { [self] in
        storeAbLoop(a: a, b: b)
        sendOSD(.abLoop(info.abLoopStatus))
        completion?(a, b)
      }
    }
  }

  /// Store the A-B loop status the given loop points, read from `mpv`, represent and show them on the play slider.
  private func storeAbLoop(a: Double, b: Double) {
    if a == 0 {
      if b == 0 {
        // Neither point is set, the feature is disabled.
        info.abLoopStatus = .cleared
      } else {
        // The B loop point is set without the A loop point having been set. This is allowed by mpv
        // but IINA is not supposed to allow mpv to get into this state, so something has gone
        // wrong. This is an internal error. Log it and pretend that just the A loop point is set.
        log("Unexpected A-B loop state, ab-loop-a is \(a) ab-loop-b is \(b)", level: .error)
        info.abLoopStatus = .aSet
      }
    } else {
      // A loop point has been set. B loop point must be set as well to activate looping.
      info.abLoopStatus = b == 0 ? .aSet : .bSet
    }
    log("Synchronized info.abLoopStatus \(info.abLoopStatus)")

    // If window is not loaded the play slider knobs can't be synchronized.
    guard mainWindow.loaded, info.state.active else { return }
    // The play slider has knobs representing the loop points, make insure the slider is in sync.
    mainWindow.syncSlider(abLoopA: a, abLoopB: b)
  }

  func togglePlaylistLoop() {
    let loopMode = getLoopMode()
    if loopMode == .playlist {
      setLoopMode(.off)
    } else {
      setLoopMode(.playlist)
    }
  }

  func toggleFileLoop() {
    let loopMode = getLoopMode()
    if loopMode == .file {
      setLoopMode(.off)
    } else {
      setLoopMode(.file)
    }
  }

  /// The loop mode the values of `loop-file` and `loop-playlist` stored in `info` give: the values `mpv` last reported, or that IINA
  /// asked it to set since. This does not ask `mpv`.
  func getLoopMode() -> LoopMode {
    let loopFileStatus = info.loopFile
    guard loopFileStatus != "inf" else { return .file }
    if let count = Int(loopFileStatus), count != 0 {
      return .file
    }
    let loopPlaylistStatus = info.loopPlaylist
    guard loopPlaylistStatus != "inf", loopPlaylistStatus != "force" else { return .playlist }
    guard let count = Int(loopPlaylistStatus) else {
      return .off
    }
    return count == 0 ? .off : .playlist
  }

  /// Ask `mpv` to set the given loop mode without waiting for it. The values asked for are stored at once, so that the loop mode
  /// read before `mpv` reports them is the one asked for.
  func setLoopMode(_ newMode: LoopMode) {
    for (name, value) in loopOptions(newMode) {
      storeLoopOption(name, value)
      mpv.setStringAsync(name, value)
    }
  }

  /// `mpv` reported a change of `loop-file` or `loop-playlist`: store the value it reported and show the loop mode it gives.
  func loopOptionChanged(_ name: String, _ value: String) {
    storeLoopOption(name, value)
    switch getLoopMode() {
    case .file:
      sendOSD(.fileLoop)
    case .playlist:
      sendOSD(.playlistLoop)
    default:
      sendOSD(.noLoop)
    }
    postNotification(.iinaLoopStatusChanged)
  }

  private func storeLoopOption(_ name: String, _ value: String) {
    if name == MPVOption.PlaybackControl.loopFile {
      info.loopFile = value
    } else {
      info.loopPlaylist = value
    }
  }

  /// The values of the `mpv` options that set the given loop mode, in the order they are set.
  private func loopOptions(_ mode: LoopMode) -> [(name: String, value: String)] {
    switch mode {
    case .playlist:
      return [(MPVOption.PlaybackControl.loopPlaylist, "inf"), (MPVOption.PlaybackControl.loopFile, "no")]
    case .file:
      return [(MPVOption.PlaybackControl.loopFile, "inf")]
    case .off:
      return [(MPVOption.PlaybackControl.loopPlaylist, "no"), (MPVOption.PlaybackControl.loopFile, "no")]
    }
  }

  func nextLoopMode() {
    setLoopMode(getLoopMode().next())
  }

  func toggleShuffle() {
    // The playlist read the change notice asks for is answered after mpv has shuffled it.
    if info.isShuffled {
      mpv.asyncCommand(.playlistUnshuffle, replyUserdata: 0)
      info.isShuffled = false
    } else {
      mpv.asyncCommand(.playlistShuffle, replyUserdata: 0)
      info.isShuffled = true
    }
    postNotification(.iinaPlaylistChanged)
  }

  func setVolume(_ volume: Double, constrain: Bool = true) {
    let maxVolume = Preference.integer(for: .maxVolume)
    let constrainedVolume = volume.clamped(to: 0...Double(maxVolume))
    let appliedVolume = constrain ? constrainedVolume : volume
    let shouldSendConstrainedVolumeOSD =
      constrain && volume != constrainedVolume && info.volume == appliedVolume
    info.volume = appliedVolume
    mpv.setDoubleAsync(MPVOption.Audio.volume, appliedVolume, level: .verbose)
    Preference.set(constrainedVolume, for: .softVolume)
    if shouldSendConstrainedVolumeOSD {
      // mpv won't send MPV_EVENT_PROPERTY_CHANGE if the volume is unchanged.
      sendOSD(.volume(constrainedVolume))
    }
  }

  func setTrack(_ index: Int, forType: MPVTrack.TrackType) {
    let name: String
    switch forType {
    case .audio:
      name = MPVOption.TrackSelection.aid
    case .video:
      name = MPVOption.TrackSelection.vid
    case .sub:
      name = MPVOption.TrackSelection.sid
    case .secondSub:
      name = MPVOption.Subtitles.secondarySid
    }
    // This does not wait for mpv. The track mpv selects is stored when it reports the change.
    mpv.setIntAsync(name, index)
  }

  func setSpeed(_ speed: Double) {
    let speed = max(AppData.mpvMinPlaybackSpeed, speed)
    mpv.setDoubleAsync(MPVOption.PlaybackControl.speed, speed)
  }

  func setVideoAspect(_ aspect: String) {
    if Regex.aspect.matches(aspect) {
      mpv.setStringAsync(MPVOption.Video.videoAspectOverride, aspect)
      info.unsureAspect = aspect
    } else {
      mpv.setStringAsync(MPVOption.Video.videoAspectOverride, "-1")
      // if not a aspect string, set aspect to default, and also the info string.
      info.unsureAspect = "Default"
    }
  }

  func setVideoRotate(_ degree: Int) {
    if AppData.rotations.firstIndex(of: degree)! >= 0 {
      mpv.setIntAsync(MPVOption.Video.videoRotate, degree)
    }
  }

  func setFlip(_ enable: Bool) {
    if enable {
      if info.flipFilter == nil {
        let vf = MPVFilter.flip()
        vf.label = Constants.FilterName.flip
        addVideoFilter(vf) { [self] added in
          if added {
            info.flipFilter = vf
          }
        }
      }
    } else {
      if let vf = info.flipFilter {
        removeVideoFilter(vf)
        info.flipFilter = nil
      }
    }
  }

  func setMirror(_ enable: Bool) {
    if enable {
      if info.mirrorFilter == nil {
        let vf = MPVFilter.mirror()
        vf.label = Constants.FilterName.mirror
        addVideoFilter(vf) { [self] added in
          if added {
            info.mirrorFilter = vf
          }
        }
      }
    } else {
      if let vf = info.mirrorFilter {
        removeVideoFilter(vf)
        info.mirrorFilter = nil
      }
    }
  }

  func toggleDeinterlace(_ enable: Bool) {
    mpv.setFlagAsync(MPVOption.Video.deinterlace, enable)
  }

  func toggleHardwareDecoding(_ enable: Bool) {
    let value = String(describing: Preference.enum(for: .hardwareDecoder) as
                       Preference.HardwareDecoderOption)
    mpv.setStringAsync(MPVOption.Video.hwdec, enable ? value : "no")
  }

  enum VideoEqualizerType {
    case brightness, contrast, saturation, gamma, hue
  }

  func setVideoEqualizer(forOption option: VideoEqualizerType, value: Int) {
    let optionName: String
    switch option {
    case .brightness:
      optionName = MPVOption.Equalizer.brightness
    case .contrast:
      optionName = MPVOption.Equalizer.contrast
    case .saturation:
      optionName = MPVOption.Equalizer.saturation
    case .gamma:
      optionName = MPVOption.Equalizer.gamma
    case .hue:
      optionName = MPVOption.Equalizer.hue
    }
    mpv.asyncCommand(.set, args: [optionName, value.description], replyUserdata: 0, level: .verbose)
  }

  /// Load the given video file as an extra video track, without waiting for `mpv`.
  func loadExternalVideoFile(_ url: URL) {
    mpv.asyncCommand(.videoAdd, args: [url.mpvStr]) { code in
      if code < 0 {
        self.log("Unsupported video: \(url.mpvStr)", level: .error)
        DispatchQueue.main.async {
          Utility.showAlert("unsupported_video")
        }
      }
    }
  }

  /// Load the given audio file as an extra audio track, without waiting for `mpv`.
  func loadExternalAudioFile(_ url: URL) {
    mpv.asyncCommand(.audioAdd, args: [url.mpvStr]) { code in
      if code < 0 {
        self.log("Unsupported audio: \(url.mpvStr)", level: .error)
        DispatchQueue.main.async {
          Utility.showAlert("unsupported_audio")
        }
      }
    }
  }

  /// Shows the Font Chooser window to select a new font for the player
  func chooseSubFont() {
    guard info.state.active else { return }
    // The font is read without waiting for mpv, and the picker is shown once mpv answers.
    mpv.getNodeAsync(MPVOption.Subtitles.subFont) { [self] subFont in
      DispatchQueue.main.async { [self] in
        Utility.quickFontPickerWindow(selecting: subFont as? String) { [self] result in
          if let result {
            setSubFont(result)
          }
        }
      }
    }
  }

  func toggleSubVisibility(_ set: Bool? = nil) {
    let newState = set ?? !info.isSubVisible
    mpv.setFlagAsync(MPVOption.Subtitles.subVisibility, newState)
  }

  func toggleSecondSubVisibility(_ set: Bool? = nil) {
    let newState = set ?? !info.isSecondSubVisible
    mpv.setFlagAsync(MPVOption.Subtitles.secondarySubVisibility, newState)
  }

  /// Load the given subtitle file, or reload it when it is loaded already, without waiting for `mpv`.
  ///
  /// `mpv` loads the file on a thread of its own, so a request made after this one can be handled before the file is loaded.
  func loadExternalSubFile(_ url: URL, delay: Bool = false, suppressError: Bool = false) {
    if let track = externalSubTrack(loadedFrom: url) {
      mpv.asyncCommand(.subReload, args: [String(track.id)], checkError: false, replyUserdata: 0)
      return
    }

    mpv.asyncCommand(.subAdd, args: [url.mpvStr], level: .verbose) { [self] code in
      subFileAdded(url, code, delay: delay, suppressError: suppressError)
    }
  }

  /// Load the given subtitle file, or reload it when it is loaded already, waiting for `mpv`, which loads it on a thread of its own,
  /// so that the requests made after this one are handled once the file is loaded. Not for the main thread.
  func loadExternalSubFileWaiting(_ url: URL, suppressError: Bool = false) {
    if let track = externalSubTrack(loadedFrom: url) {
      mpv.command(.subReload, args: [String(track.id)], checkError: false)
      return
    }

    mpv.command(.subAdd, args: [url.mpvStr], checkError: false, level: .verbose) { [self] code in
      subFileAdded(url, code, delay: false, suppressError: suppressError)
    }
  }

  /// The subtitle track loaded from the given file, if there is one.
  private func externalSubTrack(loadedFrom url: URL) -> MPVTrack? {
    var track: MPVTrack?
    info.$subTracks.withLock { track = $0.first(where: { $0.externalFilename == url.mpvStr }) }
    return track
  }

  /// Handle the error code `mpv` answered a request to add the given subtitle file with, telling the user when the file could not be
  /// added.
  private func subFileAdded(_ url: URL, _ code: Int32, delay: Bool, suppressError: Bool) {
    if code < 0 {
      self.log("Unsupported sub: \(url.mpvStr)", level: .error)
      // only show alert when the subtitle is added manually
      guard !suppressError else { return }
      // if another modal panel is shown, popping up an alert now will cause some infinite loop.
      if delay {
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.5) {
          Utility.showAlert("unsupported_sub")
        }
      } else {
        DispatchQueue.main.async {
          Utility.showAlert("unsupported_sub")
        }
      }
    }
  }

  /// Reload the subtitle tracks, then select the reloaded track of the subtitle file selected before, without waiting for `mpv`.
  /// - Parameter completion: Called on the main thread once the track list read after the reloads has been stored.
  func reloadAllSubs(then completion: (() -> Void)? = nil) {
    let currentSubName = info.currentTrack(.sub)?.externalFilename
    let reloads = DispatchGroup()
    info.$subTracks.withLock {
      for subTrack in $0 {
        reloads.enter()
        mpv.asyncCommand(.subReload, args: ["\(subTrack.id)"]) { code in
          if code < 0 {
            self.log("Failed reloading subtitles: error code \(code)", level: .error)
          }
          reloads.leave()
        }
      }
    }
    // mpv reloads a track on a thread of its own and answers once the track is added again, so the track list is read once every
    // reload has been answered, off the main thread.
    reloads.notify(queue: .global(qos: .userInitiated)) { [self] in
      mpv.getNodeAsync(MPVProperty.trackList) { [self] node in
        let tracks = trackList(from: node)
        DispatchQueue.main.async { [self] in
          storeTrackList(tracks)
          info.$subTracks.withLock {
            if let currentSub = $0.first(where: {$0.externalFilename == currentSubName}) {
              setTrack(currentSub.id, forType: .sub)
            }
          }
          completion?()
        }
      }
    }
  }

  func setAudioDelay(_ delay: Double) {
    mpv.setDoubleAsync(MPVOption.Audio.audioDelay, delay)
  }

  func setSubDelay(_ delay: Double, forPrimary: Bool = true) {
    let option = forPrimary ? MPVOption.Subtitles.subDelay : MPVOption.Subtitles.secondarySubDelay
    mpv.setDoubleAsync(option, delay)
  }

  func appendToPlaylist(_ path: String, silent: Bool = false) {
    mpv.playlistAppendAsync(path)
    info.isShuffled = false
    if !silent {
      postNotification(.iinaPlaylistChanged)
    }
  }

  func playlistMove(_ from: Int, to: Int) {
    mpv.playlistMoveAsync(from, to: to)
    info.isShuffled = false
    postNotification(.iinaPlaylistChanged)
  }

  func playlistReorder(newPlaylist: [MPVPlaylistItem]) {
    guard Set(info.playlist) == Set(newPlaylist) else { return }
    if info.playlist == newPlaylist { return }
    info.isShuffled = false
    // These do not wait for mpv, which clears the playlist and adds the files in the order they are asked.
    mpv.asyncCommand(.playlistClear, replyUserdata: 0)
    guard let currentPlaying = newPlaylist.firstIndex(where: { $0.isPlaying } ) else {
      for item in newPlaylist {
        mpv.playlistAppendAsync(item.filename)
      }
      return
    }

    for i in (0..<currentPlaying).reversed() {
      mpv.playlistInsertAsync(newPlaylist[i].filename, index: 0)
    }
    for i in currentPlaying + 1..<newPlaylist.count {
      mpv.playlistAppendAsync(newPlaylist[i].filename)
    }

    postNotification(.iinaPlaylistChanged)
  }

  func addToPlaylist(paths: [String], at index: Int = -1) {
    info.isShuffled = false
    // These do not wait for mpv, which adds the files in the order they are asked, after the requests made before. mpv appends a
    // file inserted at an index past the end of its playlist, so the length of the playlist is not needed.
    for (offset, path) in paths.enumerated() {
      if index >= 0 {
        mpv.playlistInsertAsync(path, index: index + offset)
      } else {
        mpv.playlistAppendAsync(path)
      }
    }
    postNotification(.iinaPlaylistChanged)
  }

  func playlistRemove(_ index: Int) {
    mpv.playlistRemoveAsync(index)
    info.isShuffled = false
    postNotification(.iinaPlaylistChanged)
  }

  func playlistRemove(_ indexSet: IndexSet) {
    guard !indexSet.isEmpty else { return }
    // mpv removes the entries in the order they are asked, so each index is moved back by the entries removed before it.
    var count = 0
    for i in indexSet {
      mpv.playlistRemoveAsync(i - count)
      count += 1
    }
    info.isShuffled = false
    postNotification(.iinaPlaylistChanged)
  }

  func clearPlaylist() {
    mpv.asyncCommand(.playlistClear, replyUserdata: 0)
    info.isShuffled = false
    postNotification(.iinaPlaylistChanged)
  }

  /// Play the entry at the given position in the playlist.
  /// - Important: This method will ensure playback is paused before changing the position in the playlist. If playback is not
  ///     paused, audio can start playing before video is shown. This is most noticeable with high resolution videos encoded with
  ///     newer high compression codecs (such as AV1), when running on older Macs that lack support for hardware decoding of the
  ///     codec used. Playback will be started once the video has been loaded and the size of the video is known (unless the "Pause"
  ///     setting is enabled under "When media is opened"). Playback is only paused when the user manually changes the position in
  ///     the playlist in order to not disrupt gapless audio.
  /// - Important: Although primary responsibility for ensuring the display link is running when playback is in progress belongs to
  ///     the `pauseChanged` method, this method calls `displayActive` to provide more time for the display link to start up
  ///     expecting that normally playback will be resumed by `notifyWindowVideoSizeChanged` once the file is loaded. Note
  ///     that when this method pauses playback `pauseChanged` will call `displayIdle`. That is not a problem as that method
  ///     does not immediately stop the display link. The link will still be running when `notifyWindowVideoSizeChanged`
  ///     resumes playback.
  /// - Important: The mpv
  ///     [playlist-play-index](https://mpv.io/manual/stable/#command-interface-playlist-play-index)
  ///     playlist manipulation command is intentionally used instead of setting the mpv
  ///     [playlist-pos](https://mpv.io/manual/stable/#command-interface-playlist-pos) property so that double
  ///     clicking in the playlist on the entry that is currently playing reloads that entry.
  /// - Parameter pos: Position of the entry in the playlist to be played.
  func playFileInPlaylist(_ pos: Int) {
    PlaylistStepping.play(self, at: pos)
  }

  /// Play the next or the previous entry in the playlist.
  /// - Important: This method will ensure playback is paused once `mpv` has accepted the change of position in the playlist,
  ///     before the entry moved to is loaded. When there is no entry to move to playback is left as it is. If playback is not
  ///     paused, audio can start playing before video is shown. This is most noticeable with high resolution videos encoded with
  ///     newer high compression codecs (such as AV1), when running on older Macs that lack support for hardware decoding of the
  ///     codec used. Playback will be started once the video has been loaded and the size of the video is known (unless the "Pause"
  ///     setting is enabled under "When media is opened"). Playback is only paused when the user manually changes the position in
  ///     the playlist in order to not disrupt gapless audio.
  /// - Important: Although primary responsibility for ensuring the display link is running when playback is in progress belongs to
  ///     the `pauseChanged` method, this method calls `displayActive` to provide more time for the display link to start up
  ///     expecting that normally playback will be resumed by `notifyWindowVideoSizeChanged` once the file is loaded. Note
  ///     that when this method pauses playback `pauseChanged` will call `displayIdle`. That is not a problem as that method
  ///     does not immediately stop the display link. The link will still be running when `notifyWindowVideoSizeChanged`
  ///     resumes playback.
  /// - Parameter nextMedia: When `true` play the next entry in the playlist; otherwise play the previous entry.
  func navigateInPlaylist(nextMedia: Bool) {
    PlaylistStepping.step(self, forward: nextMedia)
  }

  @discardableResult
  func playChapter(_ pos: Int) -> MPVChapter? {
    log("Seeking to chapter \(pos)", level: .verbose)
    let chapters = info.chapters
    guard pos < chapters.count else {
      return nil
    }
    let chapter = chapters[pos]
    mpv.asyncCommand(.seek, args: ["\(chapter.time.second)", "absolute"], replyUserdata: 0)
    resume()
    // need to update time pos
    syncUITime()
    return chapter
  }

  func setCrop(fromString str: String) {
    let vwidth = info.videoWidth!
    let vheight = info.videoHeight!
    if let aspect = Aspect(string: str) {
      let cropped = NSMakeSize(CGFloat(vwidth), CGFloat(vheight)).crop(withAspect: aspect)
      let vf = MPVFilter.crop(w: Int(cropped.width), h: Int(cropped.height), x: nil, y: nil)
      vf.label = Constants.FilterName.crop
      setCrop(fromFilter: vf)
      // warning! may should not update it here
      info.unsureCrop = str
      info.cropFilter = vf
    } else {
      if let filter = info.cropFilter {
        removeVideoFilter(filter)
        info.unsureCrop = "None"
      }
    }
  }

  func setCrop(fromFilter filter: MPVFilter) {
    filter.label = Constants.FilterName.crop
    addVideoFilter(filter) { [self] added in
      if added {
        info.cropFilter = filter
      }
    }
  }

  /// Remove the crop filter managed by IINA.
  func removeCropFilter() {
    if let vf = info.cropFilter {
      removeVideoFilter(vf)
      info.unsureCrop = "None"
    }
  }

  func setAudioEq(fromGains gains: [Double]) {
    let freqList = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    let paramString = freqList.enumerated().map { (index, freq) in
      "equalizer=f=\(freq):t=h:width=\(Double(freq) / 1.224744871):g=\(gains[index])"
    }.joined(separator: ",")
    let filter = MPVFilter(name: "lavfi", label: Constants.FilterName.audioEq, paramString: "[\(paramString)]")
    addAudioFilter(filter)
    info.audioEqFilter = filter
  }

  /// Add a video filter given as a `MPVFilter` object without waiting for `mpv`, see `addVideoFilter(_:then:)`.
  func addVideoFilter(_ filter: MPVFilter, then completion: @escaping (Bool) -> Void) {
    addVideoFilter(filter.stringFormat, then: completion)
  }

  /// Add a video filter given as a string without waiting for `mpv`.
  ///
  /// This method will prompt the user to change IINA's video preferences if hardware decoding is set to `auto`.
  /// - Parameter filter: The filter to add.
  /// - Parameter completion: Called on the main thread with `true` if the filter was added, `false` otherwise.
  func addVideoFilter(_ filter: String, then completion: @escaping (Bool) -> Void) {
    log("Adding video filter \(filter)...")
    // Read after the requests made before, so that a change to hwdec requested before is seen.
    mpv.getNodeAsync(MPVProperty.hwdec) { [self] hwdec in
      DispatchQueue.main.async { [self] in
        if hwdec as? String == "auto" {
          guard askHwdecForFilter(setHwdec: { mpv.setStringAsync(MPVProperty.hwdec, $0) }) else {
            completion(false)
            return
          }
        }
        // Sent after the change to hwdec, which mpv makes first.
        mpv.asyncCommand(.vf, args: ["add", filter]) { [self] code in
          let added = code >= 0
          if !added {
            log("Failed to add video filter \(filter)", level: .warning)
          } else {
            log("Successfully added video filter \(filter)")
          }
          DispatchQueue.main.async { completion(added) }
        }
      }
    }
  }

  /// Ask the user, before a video filter is added while hardware decoding is set to `auto`, whether to turn hardware decoding off,
  /// to switch it to Auto(Copy) or to abort adding the filter. Must be called on the main thread.
  /// - Parameter setHwdec: Sets the `hwdec` property of `mpv` to the value the user chose.
  /// - Returns: `true` if the user changed hardware decoding, `false` if the user aborted adding the filter.
  private func askHwdecForFilter(setHwdec: (String) -> Void) -> Bool {
    let panel = NSAlert()
    panel.messageText = NSLocalizedString("alert.title_warning", comment: "Warning")
    panel.informativeText = NSLocalizedString("alert.filter_hwdec.message", comment: "")
    panel.addButton(withTitle: NSLocalizedString("alert.filter_hwdec.turn_off", comment: "Turn off hardware decoding"))
    panel.addButton(withTitle: NSLocalizedString("alert.filter_hwdec.use_copy", comment: "Switch to Auto(Copy)"))
    panel.addButton(withTitle: NSLocalizedString("alert.filter_hwdec.abort", comment: "Abort"))
    switch panel.runModal() {
    case .alertFirstButtonReturn:  // turn off
      setHwdec("no")
      Preference.set(Preference.HardwareDecoderOption.disabled.rawValue, for: .hardwareDecoder)
      return true
    case .alertSecondButtonReturn:
      setHwdec("auto-copy")
      Preference.set(Preference.HardwareDecoderOption.autoCopy.rawValue, for: .hardwareDecoder)
      return true
    default:
      return false
    }
  }

  private func logRemoveFilter(type: String, result: Bool, name: String) {
    if !result {
      log("Failed to remove \(type) filter \(name)", level: .warning)
    } else {
      log("Successfully removed \(type) filter \(name)")
    }
  }

  /// Remove a video filter based on its position in the list of filters without waiting for `mpv`.
  ///
  /// Removing a filter based on its position within the filter list is the preferred way to do it as per discussion with the mpv project.
  /// - Parameter filter: The filter to be removed, required only for logging.
  /// - Parameter index: The index of the filter to be removed.
  /// - Parameter completion: Called on the main thread with `true` if the filter was removed, `false` otherwise.
  func removeVideoFilter(_ filter: MPVFilter, _ index: Int, then completion: @escaping (Bool) -> Void = { _ in }) {
    removeVideoFilter(filter.stringFormat, index, then: completion)
  }

  /// Remove a video filter based on its position in the list of filters without waiting for `mpv`.
  ///
  /// Removing a filter based on its position within the filter list is the preferred way to do it as per discussion with the mpv project.
  /// - Parameter filter: The filter to be removed, required only for logging.
  /// - Parameter index: The index of the filter to be removed.
  /// - Parameter completion: Called on the main thread with `true` if the filter was removed, `false` otherwise.
  func removeVideoFilter(_ filter: String, _ index: Int, then completion: @escaping (Bool) -> Void = { _ in }) {
    log("Removing video filter \(filter)...")
    mpv.removeFilter(MPVProperty.vf, index) { [self] removed in
      logRemoveFilter(type: "video", result: removed, name: filter)
      DispatchQueue.main.async { completion(removed) }
    }
  }

  /// Remove a video filter given as a `MPVFilter` object without waiting for `mpv`.
  ///
  /// If the filter is not labeled then removing using a `MPVFilter` object can be problematic if the filter has multiple parameters.
  /// Filters that support multiple parameters have more than one valid string representation due to there being no requirement on the
  /// order in which those parameters are given in a filter. If the order of parameters in the string representation of the filter IINA uses in
  /// the command sent to mpv does not match the order mpv expects the remove command will not find the filter to be removed. For
  /// this reason the remove methods that identify the filter to be removed based on its position in the filter list are the preferred way to
  /// remove a filter.
  /// - Parameter filter: The filter to remove.
  /// - Parameter completion: Called on the main thread with `true` if the filter was removed, `false` otherwise.
  func removeVideoFilter(_ filter: MPVFilter, then completion: @escaping (Bool) -> Void = { _ in }) {
    if let label = filter.label {
      removeVideoFilter("@" + label, then: completion)
      return
    }
    removeVideoFilter(filter.stringFormat, then: completion)
  }

  /// Remove a video filter given as a string without waiting for `mpv`.
  ///
  /// If the filter is not labeled then removing using a string can be problematic if the filter has multiple parameters. Filters that support
  /// multiple parameters have more than one valid string representation due to there being no requirement on the order in which those
  /// parameters are given in a filter. If the order of parameters in the string representation of the filter IINA uses in the command sent to
  /// mpv does not match the order mpv expects the remove command will not find the filter to be removed. For this reason the remove
  /// methods that identify the filter to be removed based on its position in the filter list are the preferred way to remove a filter.
  /// - Parameter filter: The filter to remove.
  /// - Parameter completion: Called on the main thread with `true` if the filter was removed, `false` otherwise.
  func removeVideoFilter(_ filter: String, then completion: @escaping (Bool) -> Void = { _ in }) {
    log("Removing video filter \(filter)...")
    mpv.asyncCommand(.vf, args: ["remove", filter]) { [self] code in
      let removed = code >= 0
      logRemoveFilter(type: "video", result: removed, name: filter)
      DispatchQueue.main.async { completion(removed) }
    }
  }

  /// Add an audio filter given as a `MPVFilter` object without waiting for `mpv`.
  /// - Parameter filter: The filter to add.
  /// - Parameter completion: Called on the main thread with `true` if the filter was added, `false` otherwise.
  func addAudioFilter(_ filter: MPVFilter, then completion: @escaping (Bool) -> Void = { _ in }) {
    addAudioFilter(filter.stringFormat, then: completion)
  }

  /// Add an audio filter given as a string without waiting for `mpv`.
  /// - Parameter filter: The filter to add.
  /// - Parameter completion: Called on the main thread with `true` if the filter was added, `false` otherwise.
  func addAudioFilter(_ filter: String, then completion: @escaping (Bool) -> Void = { _ in }) {
    log("Adding audio filter \(filter)...")
    mpv.asyncCommand(.af, args: ["add", filter]) { [self] code in
      let added = code >= 0
      if !added {
        log("Failed to add audio filter \(filter)", level: .warning)
      } else {
        log("Successfully added audio filter \(filter)")
      }
      DispatchQueue.main.async { completion(added) }
    }
  }

  /// Remove an audio filter based on its position in the list of filters without waiting for `mpv`.
  ///
  /// Removing a filter based on its position within the filter list is the preferred way to do it as per discussion with the mpv project.
  /// - Parameter filter: The filter to be removed, required only for logging.
  /// - Parameter index: The index of the filter to be removed.
  /// - Parameter completion: Called on the main thread with `true` if the filter was removed, `false` otherwise.
  func removeAudioFilter(_ filter: MPVFilter, _ index: Int, then completion: @escaping (Bool) -> Void = { _ in }) {
    removeAudioFilter(filter.stringFormat, index, then: completion)
  }

  /// Remove an audio filter based on its position in the list of filters without waiting for `mpv`.
  ///
  /// Removing a filter based on its position within the filter list is the preferred way to do it as per discussion with the mpv project.
  /// - Parameter filter: The filter to be removed, required only for logging.
  /// - Parameter index: The index of the filter to be removed.
  /// - Parameter completion: Called on the main thread with `true` if the filter was removed, `false` otherwise.
  func removeAudioFilter(_ filter: String, _ index: Int, then completion: @escaping (Bool) -> Void = { _ in }) {
    log("Removing audio filter \(filter)...")
    mpv.removeFilter(MPVProperty.af, index) { [self] removed in
      logRemoveFilter(type: "audio", result: removed, name: filter)
      DispatchQueue.main.async { completion(removed) }
    }
  }

  /// Remove an audio filter given as a `MPVFilter` object without waiting for `mpv`.
  ///
  /// If the filter is not labeled then removing using a `MPVFilter` object can be problematic if the filter has multiple parameters.
  /// Filters that support multiple parameters have more than one valid string representation due to there being no requirement on the
  /// order in which those parameters are given in a filter. If the order of parameters in the string representation of the filter IINA uses in
  /// the command sent to mpv does not match the order mpv expects the remove command will not find the filter to be removed. For
  /// this reason the remove methods that identify the filter to be removed based on its position in the filter list are the preferred way to
  /// remove a filter.
  /// - Parameter filter: The filter to remove.
  /// - Parameter completion: Called on the main thread with `true` if the filter was removed, `false` otherwise.
  func removeAudioFilter(_ filter: MPVFilter, then completion: @escaping (Bool) -> Void = { _ in }) {
    removeAudioFilter(filter.stringFormat, then: completion)
  }

  /// Remove an audio filter given as a string without waiting for `mpv`.
  ///
  /// If the filter is not labeled then removing using a string can be problematic if the filter has multiple parameters. Filters that support
  /// multiple parameters have more than one valid string representation due to there being no requirement on the order in which those
  /// parameters are given in a filter. If the order of parameters in the string representation of the filter IINA uses in the command sent to
  /// mpv does not match the order mpv expects the remove command will not find the filter to be removed. For this reason the remove
  /// methods that identify the filter to be removed based on its position in the filter list are the preferred way to remove a filter.
  /// - Parameter filter: The filter to remove.
  /// - Parameter completion: Called on the main thread with `true` if the filter was removed, `false` otherwise.
  func removeAudioFilter(_ filter: String, then completion: @escaping (Bool) -> Void = { _ in }) {
    log("Removing audio filter \(filter)...")
    mpv.asyncCommand(.af, args: ["remove", filter]) { [self] code in
      let removed = code >= 0
      logRemoveFilter(type: "audio", result: removed, name: filter)
      DispatchQueue.main.async { completion(removed) }
    }
  }

  /// Return the list of audio devices.
  ///
  /// This function takes the list of audio devices from the
  /// [audio-device-list](https://mpv.io/manual/stable/#command-interface-audio-device-list) property, as mpv last reported it. It then
  /// filters out audio devices that are not applicable based on the current IINA audio output driver setting
  /// (`audioDriverEnableAVFoundation`) and returns the results as a list of `MPVAudioDevice` objects.
  ///
  /// A mpv audio device is tied to a specific audio output driver (with the exception of the `auto` pseudo device). Thus an individual
  /// audio device appears twice in the list, once for the `coreaudio` driver and once for the `avfoundation` driver. This allows
  /// you to select both an audio device and a driver at the same time when setting the
  /// [--audio-device](https://mpv.io/manual/stable/#options-audio-device) mpv option. The documentation for
  /// [--audio-device](https://mpv.io/manual/stable/#options-audio-device) contains this caution:
  /// ```
  /// However, the --ao option will strictly force a specific AO. To avoid confusion, don't use --ao
  /// and --audio-device together.
  /// ```
  /// What the manual means by confusion is that if [--ao](https://mpv.io/manual/stable/#audio-output-drivers-ao)
  /// has been set to a specific audio output driver and
  /// [--audio-device](https://mpv.io/manual/stable/#options-audio-device) is then set to an audio device for a
  /// driver that is not contained in the list of drivers specified by
  /// [--ao](https://mpv.io/manual/stable/#audio-output-drivers-ao) then mpv will not be able to use that audio
  /// device and will fall back to the default audio device.
  ///
  /// IINA sets [--ao](https://mpv.io/manual/stable/#audio-output-drivers-ao) to either `coreaudio` or
  /// `avfoundation` based on the IINA `audioDriverEnableAVFoundation` setting. This is intentional as the
  /// `avfoundation` driver is experimental and has some problems that still need to be resolved. We want the user to explicitly
  /// choose to use the `avfoundation` driver, not accidentally choose it when selecting an audio output device.
  ///
  /// The [audio-device-list](https://mpv.io/manual/stable/#command-interface-audio-device-list) property
  /// returns the full list of audio devices regardless of the
  /// [--ao](https://mpv.io/manual/stable/#audio-output-drivers-ao) setting. Thus IINA must filter the list and
  /// remove audio devices tied to an audio output device that is not configured in
  /// [--ao](https://mpv.io/manual/stable/#audio-output-drivers-ao).
  /// - Returns: An array of `MPVAudioDevice` objects  that identify the available audio devices.
  func getAudioDevices() -> [MPVAudioDevice] {
    audioDevices(in: info.audioDeviceList)
  }

  /// The audio devices of `list`, a value of the `audio-device-list` property, that the audio output driver setting allows.
  private func audioDevices(in list: [[String: String]]) -> [MPVAudioDevice] {
    let ignore = Preference.bool(for: .audioDriverEnableAVFoundation) ? "coreaudio" : "avfoundation"
    var result: [MPVAudioDevice] = []
    for dict in list {
      let device = MPVAudioDevice(dict)
      guard device.driver != ignore else {
        log("Ignored audio device due to audio driver setting:\n \(device)", level: .verbose)
        continue
      }
      result.append(device)
    }
    return result
  }

  func setAudioDevice(_ name: String) {
    mpv.setStringAsync(MPVProperty.audioDevice, name)
  }

  /** Scale is a double value in [-100, -1] + [1, 100] */
  func setSubScale(_ scale: Double) {
    if scale > 0 {
      mpv.setDoubleAsync(MPVOption.Subtitles.subScale, scale, level: .verbose)
    } else {
      mpv.setDoubleAsync(MPVOption.Subtitles.subScale, -scale, level: .verbose)
    }
  }

  func setSubPos(_ pos: Int, forPrimary: Bool = true) {
    let option = forPrimary ? MPVOption.Subtitles.subPos : MPVOption.Subtitles.secondarySubPos
    mpv.setIntAsync(option, pos, level: .verbose)
  }

  func setSubTextColor(_ colorString: String) {
    mpv.setStringAsync("options/" + MPVOption.Subtitles.subColor, colorString)
  }

  func setSubTextSize(_ size: Double) {
    mpv.setDoubleAsync("options/" + MPVOption.Subtitles.subFontSize, size)
  }

  func setSubTextBold(_ bold: Bool) {
    mpv.setFlagAsync("options/" + MPVOption.Subtitles.subBold, bold)
  }

  func setSubTextBorderColor(_ colorString: String) {
    mpv.setStringAsync("options/" + MPVOption.Subtitles.subOutlineColor, colorString)
  }

  func setSubTextBorderSize(_ size: Double) {
    mpv.setDoubleAsync("options/" + MPVOption.Subtitles.subOutlineSize, size)
  }

  func setSubTextBgColor(_ colorString: String) {
    mpv.setStringAsync("options/" + MPVOption.Subtitles.subBackColor, colorString)
  }

  func setSubEncoding(_ encoding: String) {
    mpv.setStringAsync(MPVOption.Subtitles.subCodepage, encoding)
    info.subEncoding = encoding
  }

  func setSubFont(_ font: String) {
    mpv.setStringAsync(MPVOption.Subtitles.subFont, font)
  }

  /// Store the file played and its position as the last played, if `mpv` saves the playback position on quit, without waiting for
  /// `mpv`.
  ///
  /// Whether `mpv` saves the position is asked without waiting, so `mpv` answers after every change asked of it before. The file, its
  /// length and the position stored are those the player has when this is called. Writing the watch later configuration of the file
  /// is left to the caller, which `stop` asks for in `completion`, before its other requests.
  /// - Parameter completion: Called on the main thread once `mpv` has answered and the position is stored, with whether `mpv`
  ///     saves the position on quit.
  func savePlaybackPosition(completion: ((_ savesPosition: Bool) -> Void)? = nil) {
    let url = info.currentURL
    let duration = info.videoDuration?.second
    let position = info.videoPosition?.second
    mpv.getFlagAsync(MPVOption.WatchLater.savePositionOnQuit) { [self] savesPosition in
      // On main because PlaybackInfo is confined to the main thread, see MPVController.queue.
      DispatchQueue.main.async { [self] in
        if savesPosition == true {
          if let url {
            Preference.set(url, for: .iinaLastPlayedFilePath)
            // Write to cache directly (rather than calling `refreshCachedVideoProgress`).
            // If user only closed the window but didn't quit the app, this can make sure playlist displays the correct progress.
            info.setCachedVideoDurationAndProgress(url.path, (duration: duration, progress: position))
          }
          if let position {
            Preference.set(position, for: .iinaLastPlayedFilePosition)
          }
        }
        completion?(savesPosition == true)
      }
    }
  }

  func getGeometry() -> GeometryDef? {
    configuredGeometry
  }

  /// Uses an mpv `on_before_start_file` hook to honor mpv's `shuffle` command via IINA CLI.
  ///
  /// There is currently no way to remove an mpv hook once it has been added, so to minimize potential impact and/or side effects
  /// when not in use:
  /// 1. Only add the mpv hook if `--mpv-shuffle` (or equivalent) is specified. Because this decision only happens at launch,
  /// there is no risk of adding the hook more than once per player.
  /// 2. Use `shufflePending` to decide if it needs to run again. Set to `false` after use, and check its value as early as possible.
  func addShufflePlaylistHook() {
    $shufflePending.withLock{ $0 = true }

    func callback(next: @escaping () -> Void) {
      var mustShuffle = false
      $shufflePending.withLock{ shufflePending in
        if shufflePending {
          mustShuffle = true
          shufflePending = false
        }
      }

      guard mustShuffle else {
        log("Triggered on_before_start_file hook, but no shuffle needed", level: .verbose)
        next()
        return
      }

      DispatchQueue.main.async { [self] in
        shuffleForStartFile(then: next)
      }
    }

    mpv.addHook(MPVHook.onBeforeStartFile, hook: MPVHookValue(withBlock: callback))
  }

  /// Shuffle the playlist and play its first entry for the hook `addShufflePlaylistHook` adds, without waiting for `mpv`.
  /// - Parameter next: Lets `mpv` go on from the hook. It is called on the queue `mpv` answers on once `mpv` has started playing the
  ///     first entry, so `mpv` shuffles and starts the first entry before it goes on, and the main thread never waits for it.
  func shuffleForStartFile(then next: @escaping () -> Void) {
    log("Running on_before_start_file hook: shuffling playlist")
    mpv.asyncCommand(.playlistShuffle, replyUserdata: 0)
    info.isShuffled = true
    /// will cancel this file load sequence (so `fileLoaded` will not be called), then will start loading item at index 0
    mpv.asyncCommand(.playlistPlayIndex, args: ["0"]) { _ in next() }
  }

  // MARK: - Listeners

  // IMPORTANT!
  // The listener methods expect to be called from MPVController on the main thread. Much of the
  // data used by these methods is read by the UI using the main thread. Standardizing on using the
  // main thread avoids thread data races without the need for locks. Also a few of the methods call
  // AppKit methods that require use of the main thread.

  /// A [MPV_EVENT_START_FILE](https://mpv.io/manual/stable/#command-interface-mpv-event-start-file)
  /// was received.
  /// - Important: The event may be received after IINA has started to stop and shutdown the core. The event must be ignored if
  ///         the player is no longer active.
  func fileStarted(path: String) {
    guard info.state.active else { return }
    log("File started")

    Task { @MainActor in
      mainWindow.liveText.clearAnalysis()
    }

    MemoryUsage.shared.logUsage("after file started")
    info.justStartedFile = true
    info.disableOSDForFileLoading = true

    // mpv starts files, not folders, so a local path is made a URL without the file system being asked whether it is a folder.
    info.currentURL = path.contains("://") ?
      URL(string: path.addingPercentEncoding(withAllowedCharacters: .urlAllowed) ?? path) :
      URL(fileURLWithPath: path, isDirectory: false)
    if let url = info.currentURL {
      info.mpvMd5 = Utility.mpvWatchLaterMd5(url, ignorePathInWatchLaterConfig)
    }
    info.isNetworkResource = !info.currentURL!.isFileURL

    // set "date last opened" attribute, off the main thread since it writes to the file
    if let url = info.currentURL, url.isFileURL {
      let time = Date().timeIntervalSince1970
      backgroundQueue.async {
        // Data mimics timespec struct
        let ts = [UInt64(time), UInt64(time.truncatingRemainder(dividingBy: 1) * 1_000_000_000)]
        let data = Data(bytesOf: ts)
        // set the attribute; the key is undocumented
        let name = "com.apple.lastuseddate#PS"
        url.withUnsafeFileSystemRepresentation { fileSystemPath in
          let _ = data.withUnsafeBytes {
            setxattr(fileSystemPath, name, $0.baseAddress, data.count, 0, 0)
          }
        }
      }
    }

    NowPlayingInfoManager.shared.updateInfo(withTitle: true)

    // Auto load
    $backgroundQueueTicket.withLock { $0 += 1 }
    let shouldAutoLoadFiles = FolderPlaylistTicket.takeRequest(&info.shouldAutoLoadFiles)
    let currentTicket = backgroundQueueTicket
    let currentPlaylistTicket = folderPlaylistTicket.value
    backgroundTaskInUse = true
    backgroundQueue.async(qos: .userInitiated, flags: .enforceQoS) { [self] in
      do {
        // add files in same folder
        if shouldAutoLoadFiles {
          log("Started auto load")
          try autoLoadFilesInCurrentFolder(ticket: currentPlaylistTicket)
        }
        // auto load matched subtitles
        if let matchedSubs = self.info.getMatchedSubs(path) {
          log("Found \(matchedSubs.count) subs for current file")
          var loadedSubs = Set<URL>()
          for sub in matchedSubs {
            // filter duplicated matched subtitles, see https://github.com/iina/iina/issues/5399
            guard !loadedSubs.contains(sub) else { continue }
            loadedSubs.insert(sub)
            try checkTicket(currentTicket)
            // Waiting, off the main thread, so that the track set below is set once the files are loaded.
            loadExternalSubFileWaiting(sub, suppressError: true)
          }
          // set sub to the first one
          try checkTicket(currentTicket)
          setTrack(1, forType: .sub)
        }
        autoSearchOnlineSub()
      } catch TicketExpiredError.ticketExpired {
        log("Background task stopping due to ticket expiration")
      } catch let err {
        log("Background task stopping due to error \(err.localizedDescription)", level: .error)
      }
      // This code must be queued to the main thread to avoid thread data races.
      DispatchQueue.main.async { [self] in
        backgroundTaskInUse = false
        log("Background task has stopped")
        // If the player is stopping then that process has been waiting for this background task to
        // finish. Call stop again to continue with the process of stopping this player. Stop must
        // also be called if mpv itself stopped the core (idle state). If IINA is quitting then the
        // shutdown process has been waiting for the task to end and shutdown must be called to
        // continue the process.
        if info.state == .stopping || info.state == .idle {
          stop()
        } else if info.state == .shuttingDown {
          shutdown()
        }
      }
    }
    events.emit(.fileStarted)
  }

  /// The properties of a file `mpv` has just loaded, read when `mpv` reports it loaded, see `readLoadedFile`.
  struct LoadedFile {
    let width: Int
    let height: Int
    let duration: Double
    let position: Double
    let remaining: Double
    let path: String?
    let mediaTitle: String?
    let trackList: TrackList
    let selectedTracks: SelectedTracks
    let chapters: [MPVChapter]
    let abLoopA: Double
    let abLoopB: Double
    let fullscreen: Bool
    let ontop: Bool
  }

  /// Read the properties of the file `mpv` has just loaded.
  ///
  /// This waits for `mpv`, so it is called on the queue for reading `mpv` events when `mpv` reports the file loaded, never on the
  /// main thread.
  func readLoadedFile() -> LoadedFile {
    LoadedFile(width: mpv.getInt(MPVProperty.width),
               height: mpv.getInt(MPVProperty.height),
               duration: mpv.getDouble(MPVProperty.duration),
               position: mpv.getDouble(MPVProperty.timePos),
               remaining: Preference.bool(for: .scaleRemainingTime) ?
                 mpv.getDouble(MPVProperty.playtimeRemainingFull) :
                 mpv.getDouble(MPVProperty.timeRemainingFull),
               path: mpv.getString(MPVProperty.path),
               mediaTitle: mpv.getString(MPVProperty.mediaTitle),
               trackList: readTrackList(),
               selectedTracks: readSelectedTracks(),
               chapters: readChapters(),
               abLoopA: abLoopA,
               abLoopB: abLoopB,
               fullscreen: mpv.getFlag(MPVOption.Window.fullscreen),
               ontop: mpv.getFlag(MPVOption.Window.ontop))
  }

  /// A [MPV_EVENT_FILE_LOADED](https://mpv.io/manual/stable/#command-interface-mpv-event-file-loaded)
  /// was received.
  ///
  /// This function is called right after the file is loaded. Should load all meta info here.
  /// - Parameter loadedFile: The properties of the file, read when `mpv` reported it loaded.
  /// - Important: The event may be received after IINA has started to stop and shutdown the core. The event must be ignored if
  ///         the player is no longer active.
  func fileLoaded(_ loadedFile: LoadedFile) {
    guard info.state.active else { return }
    log("File loaded")

    info.state = .loaded

    // Must force drawing to cover the case where this player was previously used to play a video
    // and is now playing an audio file without an album cover and without using music mode.
    // See issue #5403.
    mainWindow.forceDraw("file loaded", always: true)

    // Store the video size, which sets the initial window size
    info.videoHeight = loadedFile.height
    info.videoWidth = loadedFile.width
    info.displayWidth = 0
    info.displayHeight = 0
    info.videoDuration = VideoTime(loadedFile.duration)
    info.fullLength = nil
    if let filename = loadedFile.path {
      info.setCachedVideoDuration(filename, loadedFile.duration)
    }
    info.videoPosition = VideoTime(loadedFile.position)
    info.videoRemaining = VideoTime(loadedFile.remaining)
    triedUsingExactSeekForCurrentFile = false
    checkUnsyncedWindowOptions(fullscreen: loadedFile.fullscreen, ontop: loadedFile.ontop)
    // The thumbnails of the previous file must not be shown for this file. Thumbnails for this file
    // are generated once its video is ready, see notifyWindowVideoSizeChanged.
    info.thumbnailsReady = false
    // call `trackListChanged` to store the tracks and check whether need to switch to music mode
    trackListChanged(loadedFile.trackList, loadedFile.selectedTracks)
    getPlaylist()
    storeChapters(loadedFile.chapters)
    storeAbLoop(a: loadedFile.abLoopA, b: loadedFile.abLoopB)
    refreshSyncUITimer()
    touchBarSupport.setupTouchBarUI()

    if info.aid == 0 {
      mainWindow.muteButton.isHidden = true
      mainWindow.volumeSlider.isHidden = true
    }

    if info.vid == 0 {
      notifyWindowVideoSizeChanged()
    }

    if self.isInMiniPlayer {
      miniPlayer.refreshArtworkVisibility()
      miniPlayer.handleVideoSizeChange()
    }

    // add to history
    if let url = info.currentURL {
      let duration = info.videoDuration ?? .zero
      let mediaTitle = loadedFile.mediaTitle
      // Unfortunately the mpv media-title property returns the filename when there isn't a title.
      // Don't store a title unless the media actually has one.
      let titleToUse: String? = {
        guard let mediaTitle else { return nil }
        guard mediaTitle != url.lastPathComponent else { return nil }
        return mediaTitle
      }()
      HistoryController.shared.add(url, duration: duration.second, title: titleToUse,
                                   ignorePathInWatchLaterConfig)
      if Preference.bool(for: .recordRecentFiles) && Preference.bool(for: .trackAllFilesInRecentOpenMenu) {
        AppDelegate.shared.noteNewRecentDocumentURL(url)
      }
    }
    postNotification(.iinaFileLoaded)
    events.emit(.fileLoaded, data: info.currentURL?.absoluteString ?? "")

    Task { @MainActor in
      mainWindow.liveText.requestAnalysis()
    }
  }

  func fileEnded(_ dueToStopCommand: Bool) {
    // if receive end-file when loading file, might be error
    // wait for idle
    if info.state == .loading || info.state == .starting {
      if !dueToStopCommand {
        receivedEndFileWhileLoading = true
      }
    } else {
      info.shouldAutoLoadFiles = false
    }
    MemoryUsage.shared.logUsage("after file ended")
  }

  func afChanged() {
    guard info.state.active else { return }
    postNotification(.iinaAFChanged)
  }

  /// The mpv `aid` property changed to the given track id, as mpv reported it in the change.
  func aidChanged(_ aid: Int) {
    guard info.state.active else { return }
    info.aid = aid
    guard mainWindow.loaded else { return }
    mainWindow?.muteButton.isHidden = (info.aid == 0)
    mainWindow?.volumeSlider.isHidden = (info.aid == 0)
    postNotification(.iinaAIDChanged)
    sendOSD(.track(info.currentTrack(.audio) ?? .noneAudioTrack))
  }

  /// The mpv [audio-device-list](https://mpv.io/manual/stable/#command-interface-audio-device-list)
  /// property changed.
  /// - Important: The mpv [audio-device](https://mpv.io/manual/stable/#command-interface-audio-device)
  ///     property value is not guaranteed to reflect the audio device that is actually in use. When a selected device is removed the
  ///     value of this property continues to reflect the device that is no longer present even though `libmpv` has switched to
  ///     another audio device. This will cause the IINA `Audio Device` menu to malfunction. To handle the problematic behavior
  ///     of the `audio-device` property, whenever the device list changes this method checks if the device returned by
  ///     `audio-device` is present in the new list of audio devices. If the audio device cannot be found the `audio-device`
  ///     property is set to `auto` so that both IINA and mpv are in agreement on the selected audio device. For more information
  ///     see issue [#6034](https://github.com/iina/iina/issues/6034).
  func audioDeviceListChanged(_ list: [[String: String]]) {
    info.audioDeviceList = list
    // Until mpv reports the audio device there is none to look for. The device configured in settings is looked for when mpv
    // starts.
    guard info.state.active, let device = info.audioDevice else { return }
    let devices = getAudioDevices()
    guard !devices.contains(where: {$0.name == device}) else { return }
    log("Selected audio device is no longer present, setting selected device to auto")
    setAudioDevice("auto")
  }

  /// The mpv `chapter` property changed to the given chapter, as mpv reported it in the change.
  func chapterChanged(_ chapter: Int) {
    guard info.state.active else { return }
    info.chapter = chapter
    syncUI(.time)
    postNotification(.iinaChapterListChanged)
    postNotification(.iinaMediaTitleChanged)
  }

  /// The mpv [current-ao](https://mpv.io/manual/stable/#command-interface-current-ao) property changed.
  ///
  /// When the audio output driver changes it may cause the currently selected audio device to be invalid because a mpv audio device
  /// is tied to a specific audio output driver. Attempt to find and configure the same audio device with the current audio output driver.
  /// - Parameter currentAo: The audio output driver `mpv` reports, `nil` when no audio output is open.
  func currentAoChanged(_ currentAo: String?) {
    guard let currentAo, let audioDevice = info.audioDevice else { return }
    let device = MPVAudioDevice(desc: "", name: audioDevice)
    let invalid = currentAo == "coreaudio" ? "avfoundation" : "coreaudio"
    guard device.driver == invalid else { return }
    let replacement = MPVAudioDevice(device, currentAo)
    let audioDevices = getAudioDevices()
    // Make certain the replacement device is in the list of audio devices.
    let found = audioDevices.contains { $0.name == replacement.name }
    guard found else {
      // Should not occur.
      log("Failed to find replacement audio device \(replacement.name) in:\n  \(audioDevices)",
          level: .error)
      return
    }
    log("""
        Audio output driver changed to \(currentAo), changing audio device
          from \(audioDevice)
          to \(replacement.name)
        """)
    setAudioDevice(replacement.name)
  }

  /// The mpv `fullscreen` option changed to the given flag, as mpv reported it in the change.
  func fullscreenChanged(_ fs: Bool) {
    guard mainWindow.loaded, info.state.active else { return }
    if fs != mainWindow.fsState.isFullscreen {
      mainWindow.toggleWindowFullScreen()
    }
  }

  func idleActiveChanged() {
    if receivedEndFileWhileLoading && info.state == .starting {
      DispatchQueue.main.async { [unowned self] in
        currentController.close()
        if AppDelegate.shared.openURLWindow.window?.isVisible == true {
          AppDelegate.shared.openURLWindow.failedToLoadURL()
        } else {
          Utility.showAlert("error_open")
        }
      }
      info.currentURL = nil
      info.isNetworkResource = false
    }
    receivedEndFileWhileLoading = false
    // close the window if stopped
    if info.state.loaded ||  // stopped by mpv
        (info.state == .stopping && (currentWindow?.isVisible ?? false)) {  // user sent stop command
      DispatchQueue.main.async {
        self.currentController.close()
      }
    }
    if info.state != .loading {
      log("Playback has stopped")
      info.state = .idle
      postNotification(.iinaPlayerStopped)
      if let pendingUrl {
        self.pendingUrl = nil
        log("Processing pending open")
        open(pendingUrl, shouldAutoLoad: pendingAutoLoad)
      }
    }
  }

  /// The mpv `media-title` property changed to the given title, as mpv reported it in the change.
  func mediaTitleChanged(_ title: String?) {
    info.mediaTitle = title
    titleChanged()
  }

  /// The mpv `metadata` or `chapter-metadata` property changed to the given tags, as mpv reported them in the change.
  func metadataChanged(_ metadata: [String: String], ofChapter: Bool) {
    if ofChapter {
      info.chapterMetadata = metadata
    } else {
      info.metadata = metadata
    }
    titleChanged()
  }

  /// Show the title `mpv` reported in the windows and, for the player Now Playing shows, in Now Playing.
  private func titleChanged() {
    guard info.state.active else { return }
    postNotification(.iinaMediaTitleChanged)
    if self === PlayerCore.lastActive {
      NowPlayingInfoManager.shared.updateInfo(withTitle: true)
    }
  }

  /// The mpv `ontop` property changed to the given flag, as mpv reported it in the change.
  func ontopChanged(_ ontop: Bool) {
    guard mainWindow.loaded, info.state.active else { return }
    if ontop != mainWindow.isOntop {
      mainWindow.setWindowFloatingOnTop(ontop)
    }
  }

  func pauseChanged(_ paused: Bool) {
    guard mainWindow.loaded, info.state.loaded, EntryStart.pauseChangeUpdatesState(info.state) else { return }
    if (info.state == .paused) != paused {
      sendOSD(paused ? .pause : .resume)
      // The NowPlayingInfoManager is notified when playback is paused or resumed. The video
      // position must be updated before notifying the manager.
      syncUITime()
      info.state = paused ? .paused : .playing
      refreshSyncUITimer()
      // Follow energy efficiency best practices and ensure IINA is absolutely idle when the video
      // is paused to avoid wasting energy with needless processing. If paused shutdown the timer
      // that synchronizes the UI and the high priority display link thread.
      if paused {
        mainWindow.videoView.displayIdle()
      } else {
        mainWindow.videoView.displayActive()
      }
    }
    if Preference.bool(for: .alwaysFloatOnTop) {
      mainWindow.setWindowFloatingOnTop(!paused)
    }
    syncUI(.playButton)

    Task { @MainActor in
      if paused {
        mainWindow.liveText.requestAnalysis()
      } else {
        mainWindow.liveText.clearAnalysis()
      }
    }
  }

  func playbackRestarted() {
    log("Playback restarted")

    // Important to synchronize the time as mpv may slightly alter the playback position during a
    // restart even while paused. See issue #5337.
    syncUI(.time)
    reloadSavedIINAfilters()

    // The new video's size is guaranteed to be available. Reset the flags used for window resizing.
    // We can't put this in MPV_EVENT_VIDEO_RECONFIG because it can be emitted with the old video's size
    // after switching to a new video.
    // We should keep these flags until a MPV_EVENT_VIDEO_RECONFIG with the new video's size.
    info.justOpenedFile = false
    info.justStartedFile = false

    NowPlayingInfoManager.shared.updateInfo()

    Task { @MainActor in
      mainWindow.liveText.clearAnalysis()
      mainWindow.liveText.requestAnalysis()
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.info.disableOSDForFileLoading = false }
  }

  func refreshEdrMode() {
    guard mainWindow.loaded else { return }
    // No need to refresh if playback is being stopped. Must not attempt to refresh if mpv is
    // terminating as accessing mpv once shutdown has been initiated can trigger a crash.
    guard info.state.active else { return }
    mainWindow.videoView.refreshEdrMode()
  }

  func secondarySubDelayChanged(_ delay: Double) {
    info.secondSubDelay = delay
    sendOSD(.secondSubDelay(delay))
    postNotification(.iinaSubDelayChanged)
  }

  func secondarySubPosChanged(_ position: Double) {
    info.secondSubPos = position
    sendOSD(.secondSubPos(position))
    postNotification(.iinaSubPositionChanged)
  }

  func secondarySidChanged(_ secondSid: Int) {
    guard info.state.active else { return }
    info.secondSid = secondSid
    postNotification(.iinaSIDChanged)
    sendOSD(.track(info.currentTrack(.secondSub) ?? .noneSubTrack))
    if isInMiniPlayer {
      miniPlayer.refreshArtworkVisibility()
    }
  }

  func secondSubVisibilityChanged(_ visible: Bool) {
    guard info.isSecondSubVisible != visible else { return }
    info.isSecondSubVisible = visible
    sendOSD(visible ? .secondSubVisible : .secondSubHidden)
    postNotification(.iinaSubVisibilityChanged)
    if isInMiniPlayer {
      miniPlayer.refreshArtworkVisibility()
    }
  }

  /// The mpv `sid` property changed to the given track id, as mpv reported it in the change.
  func sidChanged(_ sid: Int) {
    guard info.state.active else { return }
    info.sid = sid
    postNotification(.iinaSIDChanged)
    sendOSD(.track(info.currentTrack(.sub) ?? .noneSubTrack))
    if isInMiniPlayer {
      miniPlayer.refreshArtworkVisibility()
    }
    Task { @MainActor in
      mainWindow.liveText.clearAnalysis()
      mainWindow.liveText.requestAnalysis()
    }
  }

  func subScaleChanged(_ scale: Double) {
    guard scale != 0 else { return }
    info.subScale = scale
    let displayValue = scale >= 1 ? scale : -1 / scale
    let truncated = round(displayValue * 100) / 100
    sendOSD(.subScale(truncated))
    postNotification(.iinaSubScaleChanged)
  }

  func speedChanged(_ speed: Double) {
    guard info.state.active else { return }
    info.playSpeed = speed
    sendOSD(.speed(speed))
    mainWindow.updateSpeedLabel(speed: speed)
    postNotification(.iinaSpeedChanged)
    NowPlayingInfoManager.shared.updateInfo()
  }

  func subDelayChanged(_ delay: Double) {
    info.subDelay = delay
    sendOSD(.subDelay(delay))
    postNotification(.iinaSubDelayChanged)
  }

  func subPosChanged(_ position: Double) {
    info.subPos = position
    sendOSD(.subPos(position))
    postNotification(.iinaSubPositionChanged)
  }

  func subVisibilityChanged(_ visible: Bool) {
    guard info.isSubVisible != visible else { return }
    info.isSubVisible = visible
    sendOSD(visible ? .subVisible : .subHidden)
    postNotification(.iinaSubVisibilityChanged)
    if isInMiniPlayer {
      miniPlayer.refreshArtworkVisibility()
    }
  }

  /// The track list changed. The tracks and the tracks selected have been read on the queue for reading `mpv` events, so that the
  /// main thread does not wait for `mpv`.
  func trackListChanged(_ trackList: TrackList, _ selectedTracks: SelectedTracks) {
    // No need to process track list changes if playback is being stopped.
    guard info.state.active else { return }
    log("Track list changed")
    storeTrackList(trackList)
    storeSelectedTracks(selectedTracks)
    let audioStatus = info.isAudio

    // Now Playing is first updated when the file starts, before the track list is known, so the
    // media is treated as video and the artist and album are omitted. Update it again now.
    if self == PlayerCore.lastActive {
      NowPlayingInfoManager.shared.updateInfo(withTitle: true)
    }

    // if need to switch to music mode
    if Preference.bool(for: .autoSwitchToMusicMode) {
      if overrideAutoSwitchToMusicMode {
        log("Skipping music mode auto-switch because overrideAutoSwitchToMusicMode is true", level: .verbose)
      } else if audioStatus == .isAudio && !isInMiniPlayer && !mainWindow.fsState.isFullscreen {
        log("Current media is audio: auto-switching to mini player")
        switchToMiniPlayer(automatically: true, showMiniPlayer: false)
      } else if audioStatus == .notAudio && isInMiniPlayer {
        log("Current media is not audio: auto-switching to normal window")
        switchBackFromMiniPlayer(automatically: true, showMainWindow: false)
      }
    }

    if isInMiniPlayer {
      miniPlayer.refreshArtworkVisibility()
      miniPlayer.handleVideoSizeChange()
    }

    postNotification(.iinaTracklistChanged)
  }

  /// The display size and rotations `mpv` reports when the video is reconfigured, and whether its core is idle, see
  /// `readVideoReconfig`.
  struct VideoReconfig {
    let dwidth: Int
    let dheight: Int
    let videoParamsRotation: Int
    let rotation: Int
    let coreIdle: Bool
  }

  /// Read the display size, the rotations and the idle state of the core when `mpv` reports the video reconfigured.
  ///
  /// This waits for `mpv`, so it is called on the queue for reading `mpv` events, never on the main thread.
  func readVideoReconfig() -> VideoReconfig {
    VideoReconfig(dwidth: mpv.getInt(MPVProperty.dwidth),
                  dheight: mpv.getInt(MPVProperty.dheight),
                  videoParamsRotation: mpv.getInt(MPVProperty.videoParamsRotate),
                  rotation: mpv.getInt(MPVOption.Video.videoRotate),
                  coreIdle: mpv.getFlag(MPVProperty.coreIdle))
  }

  func onVideoReconfig(_ reconfig: VideoReconfig) {
    // If loading file, video reconfig can return 0 width and height
    guard info.state.loaded else { return }
    // The rotations read with the display size, from which the window works out the size of the video.
    info.videoParamsRotation = reconfig.videoParamsRotation
    info.rotation = reconfig.rotation
    var dwidth = reconfig.dwidth
    var dheight = reconfig.dheight
    if info.rotation == 90 || info.rotation == 270 {
      swap(&dwidth, &dheight)
    }
    if dwidth != info.displayWidth! || dheight != info.displayHeight! {
      // filter the last video-reconfig event before quit
      if dwidth == 0 && dheight == 0 && reconfig.coreIdle { return }
      // video size changed
      info.displayWidth = dwidth
      info.displayHeight = dheight
      notifyWindowVideoSizeChanged()
    }
  }

  func vfChanged() {
    guard info.state.active else { return }
    postNotification(.iinaVFChanged)
  }

  func vidChanged(_ vid: Int) {
    guard info.state.active else { return }
    info.vid = vid
    postNotification(.iinaVIDChanged)
    sendOSD(.track(info.currentTrack(.video) ?? .noneVideoTrack))
    if isInMiniPlayer {
      miniPlayer.refreshArtworkVisibility()
      miniPlayer.handleVideoSizeChange()
    }

  }

  /// The mpv `window-scale` option changed to the given scale, as mpv reported it in the change.
  func windowScaleChanged(_ windowScale: Double) {
    guard mainWindow.loaded, info.state.active else { return }
    if fabs(windowScale - info.cachedWindowScale) > 10e-10 {
      mainWindow.setWindowScale(windowScale)
    }
  }

  private func autoSearchOnlineSub() {
    Thread.sleep(forTimeInterval: 0.5)
    if Preference.bool(for: .autoSearchOnlineSub) && !info.isNetworkResource &&
      (info.videoDuration?.second ?? 0.0) >= Preference.double(for: .autoSearchThreshold) * 60 {
      info.$subTracks.withLock {
        if $0.isEmpty {
          DispatchQueue.main.async {
            self.mainWindow.menuActionHandler.menuFindOnlineSub(.dummy)
          }
        }
      }
    }
  }
  /**
   Add files in the same folder to playlist.
   It basically follows the following steps:
   - Get all files in current folder. Group and sort videos and audios, and add them to playlist.
   - Scan subtitles from search paths, combined with subs got in previous step.
   - Try match videos and subs by series and filename.
   - For unmatched videos and subs, perform fuzzy (but slow, O(n^2)) match for them.

   **Remark**:

   This method is expected to be executed in `backgroundQueue` (see `backgroundQueueTicket`).
   Therefore accesses to `self.info` and mpv playlist must be guarded.
   */
  private func autoLoadFilesInCurrentFolder(ticket: Int) throws {
    try AutoFileMatcher(player: self, ticket: ticket).startMatching()
  }

  /**
   Checks unsynchronized window options, such as those set via mpv before window loaded.

   These options currently include fullscreen and ontop. Their values are those mpv held when it reported the file loaded, read
   with the rest of the loaded file on the queue for reading mpv events.
   */
  private func checkUnsyncedWindowOptions(fullscreen fs: Bool, ontop: Bool) {
    guard mainWindow.loaded else { return }

    if fs != mainWindow.fsState.isFullscreen {
      DispatchQueue.main.async {
        self.mainWindow.toggleWindowFullScreen()
      }
    }

    if ontop != mainWindow.isOntop {
      DispatchQueue.main.async {
        self.mainWindow.setWindowFloatingOnTop(ontop, updateOnTopStatus: false)
      }
    }
  }

  // MARK: - Sync with UI in MainWindow

  /// Assess the need for the timer that synchronizes the UI and start or stop it as needed.
  ///
  /// Call this when `syncUITimer` may need to be started, stopped, or needs its interval changed. It will figure out the correct action.
  ///
  /// This method is required to adhere to the best practices in the [Energy Efficiency Guide for Mac Apps](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/UsingEfficientGraphics.html#//apple_ref/doc/uid/TP40013929-CH27-SW1)
  /// that call for an app to avoid needless energy use. [Minimizing Timer Usage](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html#//apple_ref/doc/uid/TP40013929-CH5-SW1) is one of the recommended best practices.
  /// - Important: Make sure that any state variables (e.g., `info.isPaused`, `isInMiniPlayer`,  etc.) are set *before*
  ///     calling this method, not after, so that it makes the correct decisions.
  func refreshSyncUITimer() {
    // Check if timer should start/restart

    let useTimer: Bool
    if !info.state.active {
      useTimer = false
    } else if info.state == .paused {
      // Ensure IINA is absolutely idle when the video is paused.
      useTimer = false
    } else if needsTouchBar && TouchBarSettings.shared.showAppControls || isInMiniPlayer {
      // The timer can't be stopped if the mini player is being used as it always displays the OSC
      // or if the timer is updating the information being displayed in the Touch Bar.
      useTimer = true
    } else if info.isNetworkResource {
      // May need to show, hide, or update buffering indicator at any time.
      useTimer = true
    } else {
      // Need if fadeable views or OSD are visible.
      useTimer = mainWindow.isUITimerNeeded()
    }

    let timeInterval = TimeInterval(DurationDisplayTextField.precision >= 2 ? AppData.syncTimePreciseInterval : AppData.syncTimeInterval)

    /// Invalidate existing timer:
    /// - if no longer needed
    /// - if still needed but need to change the `timeInterval`
    var wasTimerRunning = false
    if let existingTimer = self.syncUITimer, existingTimer.isValid {
      if useTimer && timeInterval == existingTimer.timeInterval {
        /// Don't restart the existing timer if not needed, because restarting will ignore any time it has
        /// already spent waiting, and could in theory result in a small visual jump (more so for long intervals).

        // Uncomment for debugging (too many calls)
//        Logger.log("SyncUITimer already running, no change needed", level: .verbose, subsystem: subsystem)
        return
      } else {
        wasTimerRunning = true
        existingTimer.invalidate()
        self.syncUITimer = nil
      }
    }

    if Logger.isEmitting(.verbose) {
      var summary = wasTimerRunning ? (useTimer ? "restarting" : "didStop") : (useTimer ? "starting" : "notNeeded")
      if summary != "notNeeded" {  // too many calls; try not to flood the log
        if useTimer {
          summary += ", timeInterval \(timeInterval)"
        }
        Logger.log("SyncUITimer \(summary). Player={state:\(info.state) network:\(info.isNetworkResource) mini:\(isInMiniPlayer) touchBar:\(needsTouchBar)}",
                   level: .verbose, subsystem: subsystem)
      }
    }

    // When fadeable views are hidden the time can get out of sync. This method will be called when
    // the view becomes visible to sync the time. If the timer was not running the view must be
    // updated now. Playback may be paused. If that is the case then the timer will not be started.
    if !wasTimerRunning {
      syncUITime()
    }

    guard useTimer else { return }

    // Timer will start
    syncUITimer = Timer.scheduledTimerInCommonMode(
      timeInterval: timeInterval,
      target: self,
      selector: #selector(self.syncUITime),
    )
  }

  func notifyWindowVideoSizeChanged() {
    currentController.handleVideoSizeChange()
    if currentController.pendingShow {
      currentController.pendingShow = false
      currentController.showWindow(self)
      AppDelegate.shared.openURLWindow.close()
    }
    // If the media was loaded manually then playback was paused to avoid audio starting to play
    // before video is ready to be displayed. Now that the video is ready the play state is decided.
    EntryStart.decidePlayState(self) { [self] in
      syncUI(.playButton)
      if Preference.bool(for: .fullScreenWhenOpen) && !mainWindow.fsState.isFullscreen && !isInMiniPlayer {
        mainWindow.toggleWindowFullScreen()
      }
      EntryStart.startThumbnails(self)
      findFullLength()
    }
  }

  /// Work out the full length of the file being played when `mpv` opened it from its index, and show it
  /// in place of the shorter duration `mpv` reports, see `FullLength`.
  ///
  /// This starts once the play state of the file has been decided and runs off the main thread, so neither the
  /// start of playback nor a step away waits for it. A result for a file that is no longer current is dropped.
  private func findFullLength() {
    guard let url = info.currentURL, url.isFileURL else { return }
    let path = url.path
    let shown = info.videoDuration?.second
    DispatchQueue.global(qos: .utility).async { [self] in
      let length = FFmpegController.fullLength(ofFragmentedFile: path)
      guard let duration = FullLength.duration(shown: shown, fullLength: length) else { return }
      // On main because PlaybackInfo is confined to the main thread, see MPVController.queue, and the time
      // display is AppKit.
      DispatchQueue.main.async { [self] in showFullLength(duration, shown: shown, ofFileAt: path) }
    }
  }

  /// Show the full length worked out for the file at the given path, unless another file has become current or playback
  /// has stopped since.
  ///
  /// Nothing here waits for `mpv`: the remaining time comes from the position the display already holds.
  /// - Important: This must be called on the main thread, to which `PlaybackInfo` is confined, see `MPVController.queue`.
  func showFullLength(_ duration: Double, shown: Double?, ofFileAt path: String) {
    guard info.state.active, info.currentURL?.path == path else { return }
    log("Full length of the file is \(duration)s, mpv reports \(shown ?? 0)s")
    info.fullLength = duration
    info.videoDuration = VideoTime(duration)
    info.setCachedVideoDuration(path, duration)
    if let position = info.videoPosition?.second {
      // mpv's remaining time is based on the shorter duration it reports, see FullLength.
      info.videoRemaining?.second = FullLength.remaining(
        fullLength: duration, position: position,
        speed: Preference.bool(for: .scaleRemainingTime) ? info.playSpeed : nil)
    }
    guard mainWindow.loaded else { return }
    currentController.updatePlayTime(withDuration: true, andProgressBar: true)
  }

  /// Synchronize the video position cached in the `info.videoPosition` property.
  ///
  /// This method updates the `PlaybackInfo.videoPosition` property.  If the video is being streamed `videoDuration` will
  /// also be updated.
  /// - Important: When the end of a video file is reached mpv does not update the value of the property
  ///     [time-pos](https://mpv.io/manual/stable/#command-interface-time-pos), leaving it reflecting the position
  ///     of the last frame of the video. This is especially noticeable if the onscreen controller time labels are configured to show
  ///     milliseconds. Due to this behavior of the `time-pos` property, this method checks to see of the end of the video has been
  ///     reached and if so, sets `videoPosition` to match `videoDuration`.
  ///
  /// The values are asked of `mpv` in one asynchronous request, so the main thread does not wait for it, and stored on the main
  /// thread once it answers; `completion` is then called there.
  private func syncPosition(then completion: @escaping () -> Void) {
    let isNetworkStream = info.isNetworkResource
    var names = [MPVProperty.eofReached, MPVProperty.timePos]
    if isNetworkStream {
      names.append(MPVProperty.duration)
    }
    mpv.getNodesAsync(names) { values in
      // On main because PlaybackInfo is confined to the main thread, see MPVController.queue.
      DispatchQueue.main.async { [self] in
        if info.state.active {
          // A value mpv could not read counts as zero or false, as it did when the values were read waiting for mpv.
          func number(_ value: Any?) -> Double { value as? Double ?? (value as? Int64).map(Double.init) ?? 0 }
          if isNetworkStream {
            info.videoDuration?.second = number(values[2])
          }
          storePosition(eofReached: values[0] as? Bool ?? false, timePos: number(values[1]))
        }
        completion()
      }
    }
  }

  /// Store the video position given by `eof-reached` and `time-pos`, see `syncPosition`.
  private func storePosition(eofReached: Bool, timePos: Double) {
    if eofReached, let duration = info.videoDuration?.second {
      info.videoPosition?.second = duration
    } else {
      info.videoPosition?.second = timePos
    }
    info.constrainVideoPosition()
  }

  /// Whether a `syncTime` request awaits `mpv`'s answer. Read and written on the main thread.
  private var isTimeSyncPending = false

  /// Synchronize the time values of `info` with `mpv` and update the time shown, without waiting for `mpv`.
  ///
  /// The values are asked of `mpv` in one asynchronous request and stored on the main thread once it answers, then `completion` is
  /// called there. A sync without a completion is skipped while an earlier one awaits `mpv`, so that a stalled `mpv` is not asked
  /// again at every tick.
  func syncTime(then completion: (() -> Void)? = nil) {
    // If window is not loaded or stopping or shutting down, ignore.
    guard mainWindow.loaded, info.state.active else { return }
    guard completion != nil || !isTimeSyncPending else { return }
    isTimeSyncPending = true
    let isNetworkStream = info.isNetworkResource
    // mpv's remaining time is based on the shorter duration it reports, so it is not read once the full length is known, see
    // FullLength.
    let remainingName: String? = info.fullLength != nil ? nil : Preference.bool(for: .scaleRemainingTime) ?
      MPVProperty.playtimeRemainingFull : MPVProperty.timeRemainingFull
    var names = [MPVProperty.eofReached, MPVProperty.timePos]
    if let remainingName {
      names.append(remainingName)
    }
    if isNetworkStream {
      names += [MPVProperty.duration, MPVProperty.pausedForCache, MPVProperty.demuxerCacheState, MPVProperty.demuxerCacheTime,
                MPVProperty.cacheBufferingState]
    }
    mpv.getNodesAsync(names) { values in
      let answers = Dictionary(uniqueKeysWithValues: zip(names, values))
      // On main because PlaybackInfo is confined to the main thread, see MPVController.queue, and the time display is AppKit.
      DispatchQueue.main.async { [self] in
        isTimeSyncPending = false
        guard info.state.active else { return }
        // A value mpv could not read counts as zero or false, as it did when the values were read waiting for mpv.
        func number(_ name: String) -> Double {
          let value = answers[name] ?? nil
          return value as? Double ?? (value as? Int64).map(Double.init) ?? 0
        }
        if isNetworkStream {
          info.videoDuration?.second = number(MPVProperty.duration)
        }
        storePosition(eofReached: (answers[MPVProperty.eofReached] ?? nil) as? Bool ?? false,
                      timePos: number(MPVProperty.timePos))
        if let fullLength = info.fullLength, let position = info.videoPosition?.second {
          info.videoRemaining?.second = FullLength.remaining(
            fullLength: fullLength, position: position,
            speed: Preference.bool(for: .scaleRemainingTime) ? info.playSpeed : nil)
        } else if let remainingName {
          info.videoRemaining?.second = number(remainingName)
        }
        if isNetworkStream {
          info.pausedForCache = (answers[MPVProperty.pausedForCache] ?? nil) as? Bool ?? false
          let cacheState = (answers[MPVProperty.demuxerCacheState] ?? nil) as? [String: Any?] ?? [:]
          info.cacheUsed = Int((cacheState["fw-bytes"] ?? nil) as? Int64 ?? 0)
          info.cacheSpeed = Int((cacheState["raw-input-rate"] ?? nil) as? Int64 ?? 0)
          info.cacheTime = Int(number(MPVProperty.demuxerCacheTime))
          info.bufferingState = Int(number(MPVProperty.cacheBufferingState))
        }
        currentController.updatePlayTime(withDuration: isNetworkStream, andProgressBar: true)
        if !isInMiniPlayer && mainWindow.fsState.isFullscreen && mainWindow.displayTimeAndBatteryInFullScreen
            && !mainWindow.additionalInfoView.isHidden {
          mainWindow.additionalInfoView.update()
        }
        if isNetworkStream {
          mainWindow.bufferIndicatorView.updateNetworkState()
        }
        completion?()
      }
    }
  }

  /// Synchronize the cached video position if the timer that updates the cache is not running, without waiting for `mpv`.
  ///
  /// When portions of the UI that need the video position are visible (OSC, OSD), `syncUITimer` keeps the
  /// `info.videoPosition` property synchronized with mpv. Code outside of the UI needs to call this method before accessing
  /// the position to ensure the cache is up to date when the timer is not running.
  /// - Parameter completion: Called on the main thread once the cached position is up to date: at once when the timer is running
  ///     or the player is not active, otherwise once `mpv` has answered and the position is stored.
  func syncPositionIfNeeded(then completion: @escaping () -> Void) {
    if let syncUITimer, syncUITimer.isValid {
      completion()
      return
    }
    guard info.state.active else {
      completion()
      return
    }
    syncPosition(then: completion)
  }

  /// Synchronize the cached video position if the timer that updates the cache is not running, waiting for `mpv`.
  ///
  /// - Important: This waits for `mpv`. It serves only the JavaScript status API, whose getters run on the main thread and must
  ///     answer a plugin at once; every other caller uses `syncPositionIfNeeded(then:)`.
  func syncPositionIfNeededWaiting() {
    if let syncUITimer, syncUITimer.isValid { return }
    guard info.state.active else { return }
    if info.isNetworkResource {
      info.videoDuration?.second = mpv.getDouble(MPVProperty.duration)
    }
    storePosition(eofReached: mpv.getFlag(MPVProperty.eofReached), timePos: mpv.getDouble(MPVProperty.timePos))
  }

  // difficult to use option set
  enum SyncUIOption {
    case time
    case playButton
    case volume
  }

  @objc func syncUITime() {
    syncUI(.time)
  }

  func syncUI(_ options: [SyncUIOption]) {
    for option in options {
      syncUI(option)
    }
  }

  func syncUI(_ option: SyncUIOption) {
    // If window is not loaded or stopping or shutting down, ignore.
    guard mainWindow.loaded, info.state.active else { return }
    // This is too noisy and making verbose logs unreadable. Please uncomment when debugging syncing related issues.
    // log("Syncing UI \(option)", level: .verbose)

    switch option {

    case .time:
      syncTime()

    case .playButton:
      DispatchQueue.main.async { [self] in
        currentController.updatePlayButtonState(paused: info.state == .paused)
        touchBarSupport.updateTouchBarPlayBtn()
      }

    case .volume:
      DispatchQueue.main.async {
        self.currentController.updateVolume()
      }
    }
  }

  func sendOSD(_ osd: OSDMessage, autoHide: Bool = true, forcedTimeout: Float? = nil, accessoryView: NSView? = nil, context: Any? = nil, external: Bool = false) {
    // querying `mainWindow.isWindowLoaded` will initialize mainWindow unexpectedly
    guard !isInMiniPlayer, mainWindow.loaded, info.state.active,
          Preference.bool(for: .enableOSD) || osd.alwaysEnabled, !osd.isDisabled else { return }
    if info.disableOSDForFileLoading && !external {
      guard case .fileStart = osd else {
        return
      }
    }
    DispatchQueue.main.async {
      self.mainWindow.displayOSD(osd,
                                 autoHide: autoHide,
                                 forcedTimeout: forcedTimeout,
                                 accessoryView: accessoryView,
                                 context: context)
    }
  }

  func hideOSD() {
    DispatchQueue.main.async {
      self.mainWindow.hideOSD()
    }
  }

  func generateThumbnails() {
    log("Getting thumbnails")
    info.thumbnailsReady = false
    info.$thumbnails.withLock { $0.removeAll(keepingCapacity: true) }
    info.thumbnailsProgress = 0
    DispatchQueue.main.async {
      self.touchBarSupport.touchBarPlaySlider?.resetCachedThumbnails()
    }
    guard !info.isNetworkResource, let url = info.currentURL else {
      log("...stopped because cannot get file path", level: .warning)
      return
    }
    let cacheName = info.mpvMd5
    // Whether the file is on a remote volume and whether its thumbnails are cached are read from the file system off the main thread.
    // The thumbnail queue is serial, so files are checked, and their thumbnails read or asked for, in the order they are asked.
    thumbnailQueue.async { [self] in
      if !Preference.bool(for: .enableThumbnailForRemoteFiles) {
        if let attrs = try? url.resourceValues(forKeys: Set([.volumeIsLocalKey])), !attrs.volumeIsLocal! {
          log("...stopped because file is on a mounted remote drive", level: .warning)
          return
        }
      }
      if Preference.bool(for: .enableThumbnailPreview) {
        if let cacheName, ThumbnailCache.fileIsCached(forName: cacheName, forVideo: url) {
          log("Found thumbnail cache")
          if let thumbnails = ThumbnailCache.read(forName: cacheName) {
            info.thumbnails = thumbnails
            info.thumbnailsReady = true
            info.thumbnailsProgress = 1
            refreshTouchBarSlider()
            // OSC thumbnails may be used in Now Playing. Notify the manager thumbnails are now
            // available.
            DispatchQueue.main.async { NowPlayingInfoManager.shared.updateInfo() }
          } else {
            log("Cannot read thumbnail from cache", level: .error)
          }
        } else {
          log("Request new thumbnails")
          ffmpegController.generateThumbnail(
            forFile: url.path,
            thumbWidth:Int32(Preference.integer(for: .thumbnailWidth)) * 2
          )
        }
      }
    }
  }

  func makeTouchBar() -> NSTouchBar {
    log("Activating Touch Bar")
    needsTouchBar = true
    // The timer that synchronizes the UI is shutdown to conserve energy when the OSC is hidden.
    // However the timer can't be stopped if it is needed to update the information being displayed
    // in the touch bar. If currently playing make sure the timer is running.
    refreshSyncUITimer()
    return touchBarSupport.touchBar
  }

  func refreshTouchBarSlider() {
    DispatchQueue.main.async {
      self.touchBarSupport.touchBarPlaySlider?.needsDisplay = true
    }
  }

  // MARK: - Getting info

  /// The tracks of a file, by type, see `readTrackList`.
  struct TrackList {
    var audio: [MPVTrack] = []
    var video: [MPVTrack] = []
    var sub: [MPVTrack] = []
  }

  /// The tracks selected, see `readSelectedTracks`.
  struct SelectedTracks {
    let aid: Int
    let vid: Int
    let sid: Int
    let secondSid: Int
  }

  /// Read the track list of `mpv`. This waits for `mpv`.
  func readTrackList() -> TrackList {
    trackList(from: mpv.getNode(MPVProperty.trackList))
  }

  /// The track list held by the given value of `mpv`'s `track-list`, read as a node.
  private func trackList(from raw: Any?) -> TrackList {
    var tracks = TrackList()
    guard let list = raw as? [[String: Any]] else {
      // Internal error, should not occur.
      log("Cast of mpv node failed while getting track list: \(String(describing: raw))",
          level: .error)
      return tracks
    }
    for dict in list {
      guard let track = MPVTrack(dict) else {
        // Internal error, should not occur.
        log("Unable to construct MPVTrack from mpv node map: \(dict)", level: .error)
        continue
      }
      // add to lists
      switch track.type {
      case .audio:
        tracks.audio.append(track)
      case .video:
        tracks.video.append(track)
      case .sub:
        tracks.sub.append(track)
      default:
        break
      }
    }
    return tracks
  }

  /// Store the track list read from `mpv`.
  private func storeTrackList(_ tracks: TrackList) {
    info.audioTracks = tracks.audio
    info.videoTracks = tracks.video
    info.$subTracks.withLock { $0 = tracks.sub }
  }

  /// Read the tracks `mpv` has selected. This waits for `mpv`.
  func readSelectedTracks() -> SelectedTracks {
    SelectedTracks(aid: mpv.getInt(MPVOption.TrackSelection.aid),
                   vid: mpv.getInt(MPVOption.TrackSelection.vid),
                   sid: mpv.getInt(MPVOption.TrackSelection.sid),
                   secondSid: mpv.getInt(MPVOption.Subtitles.secondarySid))
  }

  /// Store the tracks selected, read from `mpv`.
  private func storeSelectedTracks(_ selected: SelectedTracks) {
    info.aid = selected.aid
    info.vid = selected.vid
    info.sid = selected.sid
    info.secondSid = selected.secondSid
  }

  /// Rebuild the playlist from `mpv`'s, read in one request without waiting for `mpv`.
  ///
  /// `mpv` handles requests in the order they are made, so the playlist read includes every change requested before this call. It
  /// is stored on the thread of the queue for reading `mpv` events, then `completion` is called on the main thread. When `mpv` could
  /// not read its playlist the stored playlist is left as it was.
  /// - Parameter completion: Called on the main thread once the playlist read has been stored.
  func getPlaylist(then completion: (() -> Void)? = nil) {
    mpv.getNodeAsync(MPVProperty.playlist) { [self] node in
      if let entries = node as? [Any?] {
        // The current and playing fields of an entry are present only when they are true.
        let playlist: [MPVPlaylistItem] = entries.compactMap { entry in
          guard let fields = entry as? [String: Any?],
                let filename = (fields["filename"] ?? nil) as? String else { return nil }
          return MPVPlaylistItem(filename: filename,
                                 isCurrent: (fields["current"] ?? nil) as? Bool ?? false,
                                 isPlaying: (fields["playing"] ?? nil) as? Bool ?? false,
                                 title: (fields["title"] ?? nil) as? String)
        }
        info.$playlist.withLock { $0 = playlist }
      } else {
        log("Cannot read the playlist from mpv", level: .error)
      }
      if let completion {
        DispatchQueue.main.async(execute: completion)
      }
    }
  }

  /// Rebuild the chapter list from `mpv`'s, read in one request without waiting for `mpv`, and store it on the main thread.
  func reloadChapters() {
    log("Reloading chapter list", level: .verbose)
    mpv.getNodeAsync(MPVProperty.chapterList) { [self] node in
      // A chapter's title is present only when it has one.
      let chapters = (node as? [Any?] ?? []).enumerated().compactMap { index, entry -> MPVChapter? in
        guard let fields = entry as? [String: Any?], let time = (fields["time"] ?? nil) as? Double else { return nil }
        return MPVChapter(title: (fields["title"] ?? nil) as? String, startTime: time, index: index)
      }
      DispatchQueue.main.async { [self] in storeChapters(chapters) }
    }
  }

  /// Read the chapter list of `mpv`. This waits for `mpv`.
  func readChapters() -> [MPVChapter] {
    log("Reloading chapter list", level: .verbose)
    let chapterCount = mpv.getInt(MPVProperty.chapterListCount)
    return (0..<chapterCount).map { index in
      MPVChapter(title:     mpv.getString(MPVProperty.chapterListNTitle(index)),
                 startTime: mpv.getDouble(MPVProperty.chapterListNTime(index)),
                 index:     index)
    }
  }

  /// Store the chapter list read from `mpv`.
  private func storeChapters(_ chapters: [MPVChapter]) {
    // Instead of modifying existing list, overwrite reference to prev list.
    // This will avoid concurrent modification crashes
    info.chapters = chapters

    postNotification(.iinaChapterListChanged)
  }

  // MARK: - Notifications

  func postNotification(_ name: Notification.Name) {
    NotificationCenter.default.post(Notification(name: name, object: self))
  }

  /// Observer for changes to the macOS Touch Bar settings.
  /// - Parameters:
  ///   - keyPath: The key path, relative to `object`, to the value that has changed.
  ///   - object: The source object of the key path `keyPath`.
  ///   - change: A dictionary that describes the changes that have been made to the value of the property at the key path
  ///             `keyPath` relative to object. Entries are described in `Change Dictionary Keys`.
  ///   - context: The value that was provided when the observer was registered to receive key-value observation notifications.
  override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                             change: [NSKeyValueChangeKey: Any]?,
                             context: UnsafeMutableRawPointer?) {
    // The following guards are sanity checks and should never report an error.
    guard let keyPath else {
      log("Observed key path is missing", level: .error)
      return
    }
    guard let key = TouchBarSettings.Key(rawValue: keyPath) else {
      log("Observed key path is not a touch bar setting: \(keyPath)", level: .error)
      return
    }
    guard key == .PresentationModeFnModes || key == .PresentationModeGlobal ||
          key == .PresentationModePerApp else {
      log("Observed key path is unrecognized: \(keyPath)", level: .error)
      return
    }
    log("Touch Bar \(key) setting has changed")
    // The macOS settings that control what the Touch Bar displays has changed. May need to start or
    // stop the timer that refreshes the UI.
    refreshSyncUITimer()
  }

  // MARK: - Utils

  func checkTicket(_ ticket: Int) throws {
    if backgroundQueueTicket != ticket {
      throw TicketExpiredError.ticketExpired
    }
  }

  /**
   Non-nil and non-zero width/height value calculated for video window, from current `dwidth`
   and `dheight` while taking pure audio files and video rotations into consideration.
   */
  var videoSizeForDisplay: (Int, Int) {
    get {
      var width: Int
      var height: Int

      if let w = info.displayWidth, let h = info.displayHeight {
        // when width and height == 0 there's no video track
        width = w == 0 ? AppData.widthWhenNoVideo : w
        height = h == 0 ? AppData.heightWhenNoVideo : h
      } else {
        // we cannot get dwidth and dheight, which is unexpected. This block should never be executed
        // but just in case, let's log the error.
        Logger.log("videoSizeForDisplay: Cannot get dwidth and dheight", level: .warning, subsystem: subsystem)
        width = AppData.widthWhenNoVideo
        height = AppData.heightWhenNoVideo
      }

      // if video has rotation, as mpv reported it, so that the main thread does not wait for mpv
      let netRotate = info.videoParamsRotation - info.rotation
      let rotate = netRotate >= 0 ? netRotate : netRotate + 360
      if rotate == 90 || rotate == 270 {
        swap(&width, &height)
      }
      return (width, height)
    }
  }

  var originalVideoSize: (Int, Int) {
    get {
      if let w = info.videoWidth, let h = info.videoHeight {
        // The rotations mpv reported, so that the main thread does not wait for mpv.
        let netRotate = info.videoParamsRotation - info.rotation
        let rotate = netRotate >= 0 ? netRotate : netRotate + 360
        if rotate == 90 || rotate == 270 {
          return (h, w)
        } else {
          return (w, h)
        }
      } else {
        return (0, 0)
      }
    }
  }

  /// The title `mpv` last reported for the media, or else its path.
  func getMediaTitle(withExtension: Bool = true) -> String {
    let mediaTitle = info.mediaTitle
    let mediaPath = withExtension ? info.currentURL?.path : info.currentURL?.deletingPathExtension().path
    return mediaTitle ?? mediaPath ?? ""
  }

  /// The title, album and artist of the media or of its current chapter, from the chapters, title and tags `mpv` last reported.
  func getMusicMetadata() -> (title: String, album: String, artist: String) {
    // Like mpv's by-key lookup of a tag, the key is matched ignoring case.
    func tag(_ key: String, of tags: [String: String]) -> String? {
      tags.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }
    if !info.chapters.isEmpty {
      let chapterTitle = info.chapters.indices.contains(info.chapter) ? info.chapters[info.chapter].privTitle : nil
      return (
        chapterTitle ?? info.mediaTitle ?? "",
        tag("album", of: info.metadata) ?? "",
        tag("performer", of: info.chapterMetadata) ?? tag("artist", of: info.metadata) ?? ""
      )
    } else {
      return (
        info.mediaTitle ?? "",
        tag("album", of: info.metadata) ?? "",
        tag("artist", of: info.metadata) ?? ""
      )
    }
  }

  /** Check if there are IINA filters saved in watch_later file. */
  /// The video and audio filters are read without waiting for `mpv`, IINA's own filters among them being stored on the main thread
  /// once `mpv` has answered.
  /// - Parameter completion: Called on the main thread once the filters are stored.
  func reloadSavedIINAfilters(then completion: (() -> Void)? = nil) {
    mpv.getFiltersAsync(MPVProperty.vf) { [self] videoFilters in
      mpv.getFiltersAsync(MPVProperty.af) { [self] audioFilters in
        DispatchQueue.main.async { [self] in
          // vf
          for filter in videoFilters {
            guard let label = filter.label else { continue }
            switch label {
            case Constants.FilterName.crop:
              info.cropFilter = filter
              info.unsureCrop = ""
            case Constants.FilterName.flip:
              info.flipFilter = filter
            case Constants.FilterName.mirror:
              info.mirrorFilter = filter
            case Constants.FilterName.delogo:
              info.delogoFilter = filter
            default:
              break
            }
          }
          // af
          for filter in audioFilters {
            guard let label = filter.label else { continue }
            if label.hasPrefix(Constants.FilterName.audioEq) {
              info.audioEqFilter = filter
            }
          }
          completion?()
        }
      }
    }
  }

  /**
   Get video duration, playback progress, and metadata, then save it to info.
   It may take some time to run this method, so it should be used in background.
   */
  func refreshCachedVideoInfo(forVideoPath path: String) {
    guard let dict = FFmpegController.probeVideoInfo(forFile: path) else { return }
    let progress: VideoTime? = {
      let url = URL(fileURLWithPath: path)
      let mpvMd5 = Utility.mpvWatchLaterMd5(url, ignorePathInWatchLaterConfig)
      return Utility.playbackProgressFromWatchLater(mpvMd5)
    }()
    self.info.setCachedVideoDurationAndProgress(path, (
      duration: dict["@iina_duration"] as? Double,
      progress: progress?.second
    ))
    var result: (title: String?, album: String?, artist: String?)
    dict.forEach { (k, v) in
      guard let key = k as? String else { return }
      switch key.lowercased() {
      case "title":
        result.title = v as? String
      case "album":
        result.album = v as? String
      case "artist":
        result.artist = v as? String
      default:
        break
      }
    }
    self.info.setCachedMetadata(path, result)
  }
}

// MARK: - Moving between playlist entries

extension PlayerCore: PlaylistSteppingPlayer, EntryStartPlayer {

  var playerState: PlayerState {
    get { info.state }
    set { info.state = newValue }
  }

  var pausedForLoading: Bool {
    get { info.pausedForLoading }
    set { info.pausedForLoading = newValue }
  }

  var userPauseCount: Int {
    get { info.userPauseCount }
    set { info.userPauseCount = newValue }
  }

  var isInteractiveModeActive: Bool { mainWindow.interactiveMode.isActive }

  var isFirstEntryPlaying: Bool { info.playlist.first?.isPlaying ?? false }

  var pausesWhenOpened: Bool { Preference.bool(for: .pauseWhenOpen) }

  var isVideoLoaded: Bool { mainWindow.isVideoLoaded }

  /// Seek to the start of the file, sending the command asynchronously so that the main thread does not wait for mpv.
  func seekToStart() {
    mpv.asyncCommand(.seek, args: ["0", "absolute+exact"], replyUserdata: 0)
  }

  func fetchMpvPaused(_ reply: @escaping (Bool) -> Void) {
    mpv.getFlagAsync(MPVOption.PlaybackControl.pause) { paused in
      guard let paused else { return }
      DispatchQueue.main.async { reply(paused) }
    }
  }

  func movePlaylistPosition(forward: Bool, whenAccepted: @escaping () -> Void, reply: @escaping (Bool) -> Void) {
    mpv.asyncCommand(forward ? .playlistNext : .playlistPrev) { returnValue in
      let accepted = returnValue >= 0
      if accepted {
        whenAccepted()
      }
      DispatchQueue.main.async { reply(accepted) }
    }
  }

  func playPlaylistEntry(at index: Int) {
    mpv.asyncCommand(.playlistPlayIndex, args: [String(index)], level: .verbose) { [self] returnValue in
      if returnValue < 0 {
        log("Cannot play entry at index \(index) in the playlist, mpv error \(returnValue)", level: .error)
      }
    }
  }

  func refreshPlaylist() {
    getPlaylist()
  }

  func pauseMpv() {
    mpv.setFlagAsync(MPVOption.PlaybackControl.pause, true, level: .verbose)
  }

  func resumeMpv() {
    mpv.setFlagAsync(MPVOption.PlaybackControl.pause, false, level: .verbose)
  }

  func cancelThumbnailGeneration() {
    ffmpegController.cancelThumbnailGeneration()
  }

  func displayActive() {
    mainWindow.videoView.displayActive()
  }
}

extension PlayerCore: FFmpegControllerDelegate {

  func didUpdate(_ thumbnails: [FFThumbnail]?, forFile filename: String, withProgress progress: Int) {
    guard let currentFilePath = info.currentURL?.path, currentFilePath == filename else { return }
    log("Got new thumbnails, progress \(progress)")
    if let thumbnails {
      info.$thumbnails.withLock { $0.append(contentsOf: thumbnails) }
    }
    info.thumbnailsProgress = Double(progress) / Double(ffmpegController.thumbnailCount)
    refreshTouchBarSlider()
  }

  func didGenerate(_ thumbnails: [FFThumbnail], forFile filename: String, succeeded: Bool) {
    guard let currentFilePath = info.currentURL?.path, currentFilePath == filename else { return }
    log("Got all thumbnails, succeeded=\(succeeded)")
    if succeeded {
      info.thumbnails = thumbnails
      info.thumbnailsReady = true
      info.thumbnailsProgress = 1
      refreshTouchBarSlider()
      // OSC thumbnails may be used in Now Playing. Notify the manager thumbnails are now available.
      DispatchQueue.main.async { NowPlayingInfoManager.shared.updateInfo() }
      if let cacheName = info.mpvMd5 {
        backgroundQueue.async {
          ThumbnailCache.write(self.info.thumbnails, forName: cacheName, forVideo: self.info.currentURL)
        }
      }
      events.emit(.thumbnailsReady)
    }
  }
}
