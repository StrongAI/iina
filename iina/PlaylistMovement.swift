//
//  PlaylistMovement.swift
//  iina
//
//  The decisions IINA makes while playback moves from one playlist entry to another. Each is kept
//  apart from the player and reaches the player through a small protocol, so that it can be tested
//  without an mpv core.
//

import Foundation

// MARK: - Stepping between entries

/// The player as stepping between playlist entries and pausing during a step use it.
protocol PlaylistSteppingPlayer: AnyObject {
  /// The state of the player.
  var playerState: PlayerState { get }
  /// Whether playback is paused for the loading of an entry the user chose to play, see `PlaybackInfo.pausedForLoading`.
  var pausedForLoading: Bool { get set }
  /// The number of pauses the user has given, see `PlaybackInfo.userPauseCount`.
  var userPauseCount: Int { get set }
  /// Whether the window is in interactive mode, during which the playlist position must not change.
  var isInteractiveModeActive: Bool { get }
  /// Whether the first entry of the playlist is the entry playing.
  var isFirstEntryPlaying: Bool { get }
  /// Seek to the start of the entry playing.
  func seekToStart()
  /// Ask `mpv` to move to the next or the previous entry, without waiting for it.
  ///
  /// `mpv` replies on the thread of the queue for reading `mpv` events. When it accepted the move `whenAccepted` is called on that
  /// thread, so that what must happen before the entry moved to loads happens as soon as possible. Then `reply` is called on the
  /// main thread with whether `mpv` accepted the move.
  func movePlaylistPosition(forward: Bool, whenAccepted: @escaping () -> Void, reply: @escaping (Bool) -> Void)
  /// Ask `mpv` to play the entry at the given index, without waiting for it.
  func playPlaylistEntry(at index: Int)
  /// Fetch the playlist from `mpv` off the main thread, once `mpv` has handled the requests made before.
  func refreshPlaylist()
  /// Ask `mpv` to pause playback, without waiting for it. This may be called from any thread.
  func pauseMpv()
  /// Resume playback at the user's command.
  func resume()
  /// Stop generating thumbnails for the entry playing. This may be called from any thread.
  func cancelThumbnailGeneration()
  /// Keep the video display running while the entry changes.
  func displayActive()
  /// Log the given message. This may be called from any thread.
  func log(_ message: @autoclosure () -> String, level: Logger.Level)
}

/// Moving playback to another playlist entry at the user's command, and pausing playback while it moves.
enum PlaylistStepping {

  /// Step to the next or the previous entry of the playlist.
  ///
  /// A step back while the first entry is playing restarts that entry. Any other step asks `mpv` to move, without waiting for it.
  /// `mpv` refuses when there is no entry to move to, as when the last entry is playing and the playlist does not loop, and playback
  /// is then left as it is. As soon as `mpv` has accepted the move playback leaves the entry, see `leaveEntry`, and playback is
  /// paused for the loading of the entry moved to unless the user paused playback after asking for the step.
  static func step(_ player: PlaylistSteppingPlayer, forward: Bool) {
    guard !player.isInteractiveModeActive else { return }
    if !forward && player.isFirstEntryPlaying {
      player.seekToStart()
      return
    }
    let destination = "\(forward ? "next" : "previous") entry in playlist"
    let userPausesBeforeStep = player.userPauseCount
    player.movePlaylistPosition(forward: forward, whenAccepted: {
      leaveEntry(player, for: destination)
    }, reply: { accepted in
      guard accepted else {
        player.log("Not playing \(destination), there is no entry to move to", level: .debug)
        return
      }
      // A pause the user gave after asking for the step must hold once the entry has loaded.
      if player.userPauseCount == userPausesBeforeStep {
        player.pausedForLoading = true
      }
      player.displayActive()
    })
  }

  /// Play the entry at the given index of the playlist.
  static func play(_ player: PlaylistSteppingPlayer, at index: Int) {
    leaveEntry(player, for: "entry at index \(index) in the playlist")
    player.pausedForLoading = true
    player.displayActive()
    player.playPlaylistEntry(at: index)
    player.refreshPlaylist()
  }

  /// Leave the entry playing for another one.
  ///
  /// Scanning the entry left for thumbnails stops. Playback is paused until the entry moved to has loaded, otherwise audio can start
  /// playing before video is shown. This is most noticeable with high resolution videos encoded with newer high compression codecs
  /// (such as AV1), when running on older Macs that lack support for hardware decoding of the codec used. Pausing playback that is
  /// already paused changes nothing, so the pause is asked for without reading whether playback is paused.
  ///
  /// This may be called from any thread.
  private static func leaveEntry(_ player: PlaylistSteppingPlayer, for destination: String) {
    player.cancelThumbnailGeneration()
    player.log("Pausing playback before playing \(destination)", level: .debug)
    player.pauseMpv()
  }

  /// Pause or resume playback at the user's command.
  ///
  /// While playback is paused for the loading of an entry the entry is about to play, so the command asks for a pause.
  static func togglePause(_ player: PlaylistSteppingPlayer) {
    if player.playerState == .paused && !player.pausedForLoading {
      player.resume()
    } else {
      pause(player)
    }
  }

  /// Pause playback.
  ///
  /// A pause given while an entry is loading must not be undone once the entry has loaded, so the pause for loading ends.
  static func pause(_ player: PlaylistSteppingPlayer) {
    guard player.playerState.active else { return }
    player.log("Pausing playback", level: .debug)
    player.userPauseCount += 1
    player.pausedForLoading = false
    player.pauseMpv()
  }
}

// MARK: - Start of an entry

/// The player as the start of playback of an entry uses it.
protocol EntryStartPlayer: AnyObject {
  /// The state of the player.
  var playerState: PlayerState { get set }
  /// Whether playback is paused for the loading of an entry the user chose to play, see `PlaybackInfo.pausedForLoading`.
  var pausedForLoading: Bool { get set }
  /// Whether the "Pause" setting under "When media is opened" is enabled.
  var pausesWhenOpened: Bool { get }
  /// Ask `mpv` whether playback is paused, without waiting for it. `reply` is called on the main thread once `mpv` has handled the
  /// requests made before, and is not called if `mpv` cannot answer.
  func fetchMpvPaused(_ reply: @escaping (Bool) -> Void)
  /// Ask `mpv` to resume playback, without waiting for it.
  func resumeMpv()
  /// Keep the video display running.
  func displayActive()
  /// Whether the window has loaded video.
  var isVideoLoaded: Bool { get }
  /// Start generating thumbnails for the entry playing.
  func generateThumbnails()
  func log(_ message: @autoclosure () -> String, level: Logger.Level)
}

/// Starting playback of an entry once its first frame is ready.
enum EntryStart {

  /// Decide the play state of an entry whose first frame is ready, without waiting for `mpv`.
  ///
  /// When the player is in the `loaded` state `mpv` is asked whether playback is paused, and the play state is decided once it
  /// answers, see `decidePlayState(_:paused:)`. `mpv` answers after handling every request made before, so the answer includes the
  /// pause asked for before the entry loaded and any pause or resume the user gave until the question was asked.
  /// - Parameter decided: Called on the main thread once the play state has been decided.
  static func decidePlayState(_ player: EntryStartPlayer, then decided: @escaping () -> Void) {
    guard player.playerState == .loaded else { return }
    player.fetchMpvPaused { paused in
      if decidePlayState(player, paused: paused) {
        decided()
      }
    }
  }

  /// Decide the play state of an entry whose first frame is ready, given whether `mpv` has playback paused.
  ///
  /// Playback paused for the loading of the entry resumes, unless the "Pause" setting under "When media is opened" is enabled. A
  /// pause the user gave while the entry loaded ended the pause for loading, so playback then stays paused. The state becomes
  /// paused or playing to match `mpv`.
  /// - Returns: `true` when the player was in the `loaded` state and its play state has been decided, otherwise `false`.
  @discardableResult
  static func decidePlayState(_ player: EntryStartPlayer, paused: Bool) -> Bool {
    guard player.playerState == .loaded else { return false }
    var paused = paused
    if paused, player.pausedForLoading, !player.pausesWhenOpened {
      player.log("Resuming playback now that file has been loaded", level: .debug)
      player.displayActive()
      player.resumeMpv()
      paused = false
    }
    player.pausedForLoading = false
    player.playerState = paused ? .paused : .playing
    return true
  }

  /// Whether a change of `mpv`'s pause flag changes the state of a player in the given state.
  ///
  /// `mpv` delivers property changes only once its event queue is empty, so the change caused by pausing playback before loading a
  /// file can arrive after `MPV_EVENT_FILE_LOADED`. Until the first frame is ready the state must remain `loaded`, otherwise
  /// `decidePlayState` would not resume playback.
  static func pauseChangeUpdatesState(_ state: PlayerState) -> Bool {
    return state != .loaded
  }

  /// Start generating thumbnails for an entry whose play state has been decided.
  ///
  /// Thumbnails are generated only once playback has started so that scanning the file does not delay it.
  static func startThumbnails(_ player: EntryStartPlayer) {
    if player.isVideoLoaded {
      player.generateThumbnails()
    }
  }

  /// Whether the window generates thumbnails when it first loads video, for a player in the given state.
  ///
  /// When the entry has just been loaded the player generates thumbnails itself once the play state is decided, see
  /// `startThumbnails`.
  static func windowGeneratesThumbnails(_ state: PlayerState) -> Bool {
    return state != .loaded
  }
}

// MARK: - Folder playlist

/// The playlist the files in the folder of the opened file are added to.
protocol FolderPlaylist: AnyObject {
  /// Throws `PlayerCore.TicketExpiredError.ticketExpired` once the playlist of the opened file has been abandoned.
  func checkFolderTicket() throws
  /// Add the file with the given path to the end of the playlist.
  func append(_ path: String)
  /// Insert the file with the given path into the playlist at the given index.
  func insert(_ path: String, at index: Int)
}

/// Adding the playable files in the folder of the opened file to its playlist.
enum FolderPlaylistAssembly {

  /// Add the files with the given paths, in folder order, around the opened file.
  ///
  /// The files after the opened file are appended first, in order, so that the next entry is available as soon as possible. Then the
  /// files before it are inserted ahead of it, each at its index in the folder. If the opened file is not among the files then all of
  /// them are inserted. The ticket is checked before each file is added, and adding stops once the playlist has been abandoned.
  static func add(_ paths: [String], openedPath: String?, to playlist: FolderPlaylist) throws {
    let openedIndex = paths.firstIndex { $0 == openedPath }
    if let openedIndex {
      for path in paths[(openedIndex + 1)...] {
        try playlist.checkFolderTicket()
        playlist.append(path)
      }
    }
    for (index, path) in paths[..<(openedIndex ?? paths.count)].enumerated() {
      try playlist.checkFolderTicket()
      playlist.insert(path, at: index)
    }
  }
}

/// Identifies the playlist of the opened file, into which the files in its folder are added.
///
/// The ticket changes when the playlist is abandoned: when another file is opened with a load command and when the background task
/// is told to stop. Unlike `PlayerCore.backgroundQueueTicket` it does not change when playback moves to another entry, so that
/// the task matching the folder continues until every file in the folder has been added and matched.
final class FolderPlaylistTicket {

  @Atomic private var current = 0

  /// The current value of the ticket, held by the task matching the folder.
  var value: Int { current }

  /// Abandon the playlist of the opened file.
  func abandon() {
    $current.withLock { $0 += 1 }
  }

  /// Throws `PlayerCore.TicketExpiredError.ticketExpired` when the playlist identified by the given ticket value has been
  /// abandoned.
  func check(_ ticket: Int) throws {
    if current != ticket {
      throw PlayerCore.TicketExpiredError.ticketExpired
    }
  }

  /// Take the request, made when a file is opened, to add the files in its folder to the playlist.
  ///
  /// The folder is matched once, for the file that was opened. Moving to another entry must not match it again.
  /// - Returns: Whether the folder is to be matched now.
  static func takeRequest(_ request: inout Bool) -> Bool {
    defer { request = false }
    return request
  }
}

// MARK: - Seeking by scrolling

/// Tracks, in the order of `mpv`'s events, whether the seek `mpv` is performing was issued by a scroll.
/// - Important: This must only be used by the thread of the queue for reading `mpv` events.
struct ScrollSeekAttribution {

  /// The longest time in seconds from `mpv` restarting playback after a seek to the file ending for the seek to have ended the
  /// file by running past its end.
  static let maxSeekEndToFileEndInterval: CFTimeInterval = 0.5

  /// Whether `mpv` has accepted a seek issued by a scroll and has not started it.
  private var isPending = false

  /// Whether the seek `mpv` is performing was issued by a scroll.
  private var isSeeking = false

  /// The time at which `mpv` restarted playback after its most recent seek, if that seek was issued by a scroll.
  private var endTime: CFTimeInterval?

  /// `mpv` replied to a command sent with the given user data.
  mutating func commandReplied(userdata: UInt64, error: Int32) {
    // mpv has accepted a seek issued by a scroll. The next seek mpv starts performs it.
    if userdata == MPVController.UserData.scrollSeek, error >= 0 {
      isPending = true
    }
  }

  /// `mpv` started a seek. The seek performs every seek `mpv` has accepted since it last started one.
  mutating func seekStarted() {
    isSeeking = isPending
    isPending = false
  }

  /// `mpv` restarted playback at the given time.
  mutating func playbackRestarted(at time: CFTimeInterval) {
    endTime = isSeeking ? time : nil
    isSeeking = false
  }

  /// `mpv` ended a file at the given time.
  ///
  /// When a seek runs past the end of a file during playback `mpv` restarts playback and then ends the file at once. A seek `mpv`
  /// has not started by now is discarded by `mpv`.
  /// - Returns: Whether a seek issued by a scroll ended the file.
  mutating func fileEnded(at time: CFTimeInterval) -> Bool {
    let endedByScrollSeek = isSeeking || endTime.map { time - $0 < Self.maxSeekEndToFileEndInterval } ?? false
    isPending = false
    isSeeking = false
    endTime = nil
    return endedByScrollSeek
  }
}

/// The player as the end of a file uses it, in the thread of the queue for reading `mpv` events.
protocol FileEndPlayer: AnyObject {
  /// Whether the "Pause" setting under "When media is opened" is enabled.
  var pausesWhenOpened: Bool { get }
  /// Set `mpv`'s pause flag.
  func pauseMpv()
  /// Stop generating thumbnails for the file that ended.
  func cancelThumbnailGeneration()
  func log(_ message: @autoclosure () -> String, level: Logger.Level)
}

/// The end of a file, handled in the thread of the queue for reading `mpv` events.
enum FileEnd {

  /// Handle the end of a file.
  ///
  /// Scanning the file for thumbnails stops here rather than in the main thread, so that the scan does not continue until the main
  /// thread is free. When the "Pause" setting under "When media is opened" is enabled playback is paused as soon as possible, as
  /// `mpv` may already be loading the next entry, unless the file ended because it was stopped or because a seek issued by a scroll
  /// ran past its end. After such a seek playback is left as the scroll has it, so that the next entry plays exactly when playback
  /// was playing before the scroll.
  /// - Returns: Whether a seek issued by a scroll ended the file.
  static func fileEnded(_ player: FileEndPlayer, dueToStopCommand: Bool, attribution: inout ScrollSeekAttribution,
                        at time: CFTimeInterval) -> Bool {
    player.cancelThumbnailGeneration()
    let endedByScrollSeek = attribution.fileEnded(at: time)
    if !dueToStopCommand, player.pausesWhenOpened, !endedByScrollSeek {
      player.pauseMpv()
      // Normally a log message is emitted before calling mpv, but in this case, due to the race
      // condition, playback must be paused as soon as possible, so logging is done afterward.
      player.log("Pausing playback because \"pause when media is opened\" is enabled", level: .debug)
    }
    return endedByScrollSeek
  }
}

/// Whether the current file is loading because a seek issued by a scroll ran past the end of the previous file.
/// - Important: This must only be accessed by the main thread.
struct ScrollSeekLoading {

  /// Whether the current file is loading because a seek issued by a scroll ran past the end of the previous file. This is `true`
  /// from the end of the previous file until playback of the current file has started.
  private(set) var isLoading = false

  /// The time at which `isLoading` last became `false`, as system uptime, the time base of `NSEvent.timestamp`.
  private(set) var endTime: TimeInterval = 0

  /// A file ended, by a seek issued by a scroll or otherwise.
  mutating func fileEnded(byScrollSeek: Bool) {
    isLoading = byScrollSeek
  }

  /// `mpv` restarted playback at the given time.
  mutating func playbackRestarted(at time: TimeInterval) {
    guard isLoading else { return }
    isLoading = false
    endTime = time
  }
}

/// Decides, for each scroll event, which scroll the event belongs to and what the scroll may do.
struct ScrollGesture {

  /// A scroll event.
  struct Event {
    /// Whether fingers started moving on a trackpad.
    var isTrackpadBegan: Bool
    /// Whether fingers were lifted from a trackpad.
    var isTrackpadEnded: Bool
    /// Whether the event comes from a mouse wheel. The momentum events that follow scrolling on a trackpad do not.
    var isMouseWheel: Bool
    /// The time of the event, as system uptime.
    var timestamp: TimeInterval
  }

  /// What a scroll event does.
  struct Outcome: Equatable {
    /// Whether the event pauses playback.
    var pausesPlayback = false
    /// Whether the event resumes playback.
    var resumesPlayback = false
    /// Whether the event may seek.
    var maySeek = true
  }

  /// The longest time in seconds between two events from a mouse wheel that are one scroll.
  static let maxMouseWheelEventInterval: TimeInterval = 0.5

  /// The value of `PlaybackInfo.fileStartCount` when the current scroll began.
  private var fileStartCountAtBegin = 0

  /// The time of the most recent scroll event from a mouse wheel.
  private var lastMouseWheelEventTime: TimeInterval = 0

  /// Whether playback was playing when the current trackpad scroll began seeking.
  private var wasPlayingBeforeSeeking = false

  /// Decide what the given scroll event does.
  ///
  /// A scroll begins when fingers start moving on a trackpad and lasts through the momentum that follows. A mouse wheel does not
  /// report when a scroll begins, its events are one scroll while they follow each other closely. The events of a scroll that has
  /// carried playback into another file can arrive late while that file loads, so the scroll lasts through the loading. Once the
  /// scroll has carried playback into another file the rest of the scroll, including its momentum, must not seek in that file. A
  /// trackpad scroll that seeks pauses playback while the fingers are down if playback was playing when it began.
  /// - Parameters:
  ///   - event: The scroll event.
  ///   - seeks: Whether the scroll seeks.
  ///   - isPlaying: Whether the player is playing.
  ///   - fileStartCount: The value of `PlaybackInfo.fileStartCount`.
  ///   - loading: Whether the current file is loading after a seek issued by a scroll.
  mutating func handle(_ event: Event, seeks: Bool, isPlaying: Bool, fileStartCount: Int,
                       loading: ScrollSeekLoading) -> Outcome {
    let lastScrollTime = max(lastMouseWheelEventTime, loading.endTime)
    let isMouseWheelBegan = event.isMouseWheel && !loading.isLoading
      && event.timestamp - lastScrollTime > Self.maxMouseWheelEventInterval
    if event.isMouseWheel {
      lastMouseWheelEventTime = event.timestamp
    }
    if event.isTrackpadBegan || isMouseWheelBegan {
      fileStartCountAtBegin = fileStartCount
    }
    var outcome = Outcome()
    outcome.maySeek = fileStartCount == fileStartCountAtBegin
    if seeks && event.isTrackpadBegan && isPlaying {
      outcome.pausesPlayback = true
      wasPlayingBeforeSeeking = true
    }
    if event.isTrackpadEnded && wasPlayingBeforeSeeking {
      outcome.resumesPlayback = true
      wasPlayingBeforeSeeking = false
    }
    return outcome
  }
}

// MARK: - Cache configuration

/// The values IINA's cache settings give `mpv`'s cache options.
///
/// These are set when the `mpv` core is initialized and again when a setting changes. Nothing that runs when playback moves to
/// another entry sets them.
enum CacheConfiguration {

  /// The value of `mpv`'s `cache` option for the "Enable cache" setting.
  static func cache(enabled: Bool) -> String {
    return enabled ? "yes" : "no"
  }

  /// The value of `mpv`'s `demuxer-max-bytes` option for the cache size setting, which is in KiB.
  static func demuxerMaxBytes(kibibytes: Int) -> String {
    return "\(kibibytes)KiB"
  }
}

// MARK: - Full length

/// A fragmented MP4 that ends in an index is opened from that index, so that opening it does not take
/// longer the longer the file is. The duration `mpv` reports for such a file covers only the fragments
/// `mpv` has read, so once playback has started the full length is worked out off the main thread and
/// replaces it.
enum FullLength {
  /// The value of `mpv`'s `demuxer-lavf-o` option that opens such a file from its index.
  static let demuxerOption = "use_mfra_for=pts"

  /// The duration to show once the full length of a file has been worked out.
  /// - Parameters:
  ///   - shown: The duration shown for the file.
  ///   - fullLength: The full length worked out, negative when the file was not opened from an index.
  /// - Returns: The full length when it is longer than the duration shown, otherwise `nil`.
  static func duration(shown: Double?, fullLength: Double) -> Double? {
    guard fullLength > 0 else { return nil }
    if let shown, shown >= fullLength { return nil }
    return fullLength
  }

  /// The time a seek to the given percentage of a file's full length lands at, kept short of the end so
  /// that the seek does not end the file.
  static func seekTime(percent: Double, fullLength: Double) -> Double {
    fullLength * percent.clamped(to: 0..<100) / 100
  }

  /// The arguments of the seek command for a seek to the given percentage of a file.
  /// - Parameters:
  ///   - percent: The percentage of the file to seek to.
  ///   - fullLength: The full length of the file when it was opened from its index, otherwise `nil`.
  ///   - exact: Whether the seek is exact rather than to a key frame.
  /// - Returns: While the full length is known, an absolute seek to `seekTime(percent:fullLength:)`, because `mpv` takes a
  ///     percentage of the shorter duration it reports; otherwise `mpv`'s own seek to the percentage.
  static func seekArguments(percent: Double, fullLength: Double?, exact: Bool) -> [String] {
    guard let fullLength else { return ["\(percent)", exact ? "absolute-percent+exact" : "absolute-percent"] }
    return ["\(seekTime(percent: percent, fullLength: fullLength))", exact ? "absolute+exact" : "absolute"]
  }

  /// The time remaining in a file of the given full length.
  /// - Parameters:
  ///   - fullLength: The full length of the file.
  ///   - position: The playback position.
  ///   - speed: The playback speed, by which the remaining time is divided when it is scaled.
  static func remaining(fullLength: Double, position: Double, speed: Double?) -> Double {
    let remaining = max(fullLength - position, 0)
    guard let speed, speed > 0 else { return remaining }
    return remaining / speed
  }
}
