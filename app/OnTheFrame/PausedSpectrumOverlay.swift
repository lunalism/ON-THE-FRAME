import AppKit
import AVFoundation
import OnTheFrameEngine

/// NotificationCenter removal is thread-safe; automatic destruction avoids accessing
/// a non-Sendable AppKit observer token from NSView's nonisolated deinit.
final class SpectrumWindowObservation {
    private let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}

/// One confirmed paused seek, never a playback clock. All presentation is main-actor only.
@MainActor
final class PausedSpectrumOverlay {
    weak var view: PlayerNSView?
    weak var store: ProjectStore?
    private(set) var confirmedFrame: Int?
    private var confirmedToken: Int?
    private weak var confirmedItem: AVPlayerItem?
    private var serial = 0 // view/request lifetime, not another project session
    private var tickets: [SpectrumFrameTicket] = []
    private(set) var layers: [UUID: CALayer] = [:]
    #if DEBUG
    private(set) var assignments = 0
    private(set) var latencies: [Double] = []
    private(set) var updateCosts: [Double] = []
    #endif

    init(view: PlayerNSView) { self.view = view }
    func attach(_ store: ProjectStore) { self.store = store }
    func detach() { invalidate(forgetFrame: true); store = nil }

    func invalidate(forgetFrame: Bool = false) {
        serial &+= 1
        if let store { tickets.forEach { store.spectrumPreview.cancel($0) } }
        tickets = []
        CATransaction.begin(); CATransaction.setDisableActions(true)
        view?.spectrumCanvas.sublayers = nil
        layers = [:]
        CATransaction.commit()
        if forgetFrame { confirmedFrame = nil; confirmedToken = nil; confirmedItem = nil }
    }

    func seekFinished(token: Int, frame: Int, finished: Bool) {
        guard let store, token == store.seekToken, finished, !store.isPlaying,
              store.appliedGeneration == store.generation, let item = store.player.currentItem else { return }
        confirmedFrame = frame; confirmedToken = token; confirmedItem = item
        refresh()
    }

    func refresh() {
        invalidate()
        guard let store, let view, view.window != nil, store.previewHost === view,
              !store.isPlaying, store.gestureBase == nil, !view.isShowingStill, store.appliedGeneration == store.generation,
              let frame = confirmedFrame, let token = confirmedToken, token == store.seekToken,
              let item = confirmedItem, store.player.currentItem === item else { return }
        let generation = serial
        let epoch = store.spectrumPreview.epoch, revision = store.spectrumPreview.revision
        // Timeline stores top lanes first; CA paints bottom lanes first, as subtitles do.
        let entries = store.timeline.spectra.reversed().filter { $0.visible(atFrame: frame) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for entry in entries {
            let layer = CALayer(); layer.actions = PlayerNSView.noActions
            layer.magnificationFilter = .linear; layer.minificationFilter = .linear
            layers[entry.id] = layer
            view.spectrumCanvas.addSublayer(layer)
        }
        CATransaction.commit()
        for entry in entries {
            let start = ProcessInfo.processInfo.systemUptime
            let ticket = store.spectrumPreview.request(spectrum: entry.id, frame: frame) { [weak self, weak item] outcome in
                Task { @MainActor [weak self, weak item] in
                    guard let self, self.serial == generation, let currentStore = self.store,
                          currentStore.spectrumPreview.epoch == epoch, currentStore.spectrumPreview.revision == revision else { return }
                    var accepted = outcome
                    if case .ready(_, .some) = outcome {
                        if let mediaID = currentStore.timeline.spectrumMediaID(entry), let asset = currentStore.mediaByID[mediaID] {
                            // Cached analysis does not prove the file is still present/unchanged.
                            // Metadata checks stay off the main actor; scope ownership stays in ProjectStore.
                            let available = await Task.detached(priority: .userInitiated) {
                                FileIdentity.of(asset.url) == asset.identity && FileManager.default.isReadableFile(atPath: asset.url.path)
                            }.value
                            if !available {
                                accepted = .mediaUnavailable(mediaID)
                                #if DEBUG
                                ProjectStore.log.debug("paused spectrum media no longer matches inspected identity")
                                #endif
                            }
                        } else { accepted = .missingSource }
                    }
                    guard let store = self.store, let view = self.view,
                          view.window != nil, store.previewHost === view, self.serial == generation,
                          self.confirmedFrame == frame, self.confirmedToken == token, store.seekToken == token,
                          store.spectrumPreview.epoch == epoch, store.spectrumPreview.revision == revision,
                          !store.isPlaying, store.gestureBase == nil, !view.isShowingStill, store.appliedGeneration == store.generation,
                          let item, store.player.currentItem === item, let layer = self.layers[entry.id] else { return }
                    let updateStart = ProcessInfo.processInfo.systemUptime
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    switch accepted {
                    case let .ready(_, rendered):
                        layer.contents = rendered?.image
                        layer.frame = rendered.map { Self.layerRect($0.drawRect) } ?? .zero
                    case .notVisible, .itemMissing, .unsetSource, .missingSource, .overlap, .mediaUnavailable,
                         .cancelled, .superseded, .dropped:
                        layer.contents = nil; layer.frame = .zero
                    case let .failed(error):
                        layer.contents = nil; layer.frame = .zero
                        #if DEBUG
                        ProjectStore.log.debug("paused spectrum failed: \(String(describing: error), privacy: .public)")
                        #endif
                    }
                    CATransaction.commit()
                    #if DEBUG
                    self.assignments += 1
                    self.latencies.append(updateStart - start)
                    self.updateCosts.append(ProcessInfo.processInfo.systemUptime - updateStart)
                    if self.latencies.count > 256 { self.latencies.removeFirst(); self.updateCosts.removeFirst() }
                    #endif
                }
            }
            tickets.append(ticket)
        }
    }

    /// Cropped image remains cropped. The image's top row is CA contents' top row.
    static func layerRect(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: 1080 - rect.maxY, width: rect.width, height: rect.height)
    }
}

extension ProjectStore {
    /// Narrow preview comparison: retain all video/audio inputs and FULL duration, omit overlay-only values.
    static func previewVideoInputs(_ timeline: Timeline) -> Timeline {
        Timeline(clips: timeline.clips, audioClips: timeline.audioClips,
                 lanes: timeline.lanes.filter { $0.kind != .spectrum }, media: timeline.media,
                 mediaFrames: timeline.mediaFrames, mediaHasAudio: timeline.mediaHasAudio,
                 mediaHasVideo: timeline.mediaHasVideo, durationFrames: timeline.durationFrames)
    }
}
