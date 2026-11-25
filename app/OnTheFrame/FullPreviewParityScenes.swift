#if DEBUG
import AppKit
@testable import OnTheFrameEngine

/// SP-EXPORT-E4D-G1 (DEBUG only): the approved phase-1 scenarios. One scenario per application process.
/// Timelines use fixed IDs so the overlay-free reference timeline has exactly the same video clips.
///
/// Fixture roles (owner decision 1, G1 correction): otf-TA is preserved unchanged for source-frame identification, frame-number
/// decoding and timeline timing (scenario G, and otf-TB as the M6 upper layer). otf-PAR is an additional fixture: uniform,
/// frame-coded background for overlay validation and Spectrum/subtitle visibility (C–F), used with the 440 Hz WAV as Spectrum
/// source. otf-CAL / otf-RES / otf-SDU / otf-SD601 / otf-HD709 / otf-HDU serve calibration, resampling and colour (M1–M6).
struct ParityScene {
    let name: String
    let timeline: Timeline
    let reference: Timeline?                       // same video without Spectrum/subtitles (mask reference); nil = no overlays
    let frames: [Int]
    let target: (Int) -> PlacedSource?             // visible source (sourceID < 0: uncoded); nil: empty gap (black)
    let sourceFrame: (Int) -> Int?                 // source frame index of the target (nil: uncoded or gap)
    let sourceFile: (Int) -> String?               // file of the target (source decode)
    let layout: (Int) -> [[Double]]?               // expected overlay boxes in output pixels; [] none
    let colourTagged: Bool?                        // M2/M3 true, M1/M4/M5/M6 false, others nil
    let roi: CGRect?                               // target ROI for the cross-run conformance (M1–M6)
    let upperLayer: CGRect?                        // M6 upper active layer rectangle
    let edgeFrames: [Int]                          // frames whose target is a uniform plate reaching the output edge
    let anchorFrame: Int?                          // plate-red frame (scenario G) for the C3 anchor
    let files: [String]
}

@MainActor
enum FullPreviewParityScenes {
    static let all = ["CAL", "RES", "C", "D", "E", "F", "G", "M1", "M2", "M3", "M4", "M5", "M6"]
    nonisolated static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "0F7EF0A0-0000-4000-8000-%012x", 0x100 + n))! }
    nonisolated static let full = PlacedSource(sourceID: -1, x: 0, y: 0, w: 1920, h: 1080)
    nonisolated static func fullCoded(_ id: Int) -> PlacedSource { PlacedSource(sourceID: id, x: 0, y: 0, w: 1920, h: 1080) }
    nonisolated static func pillar(_ id: Int) -> PlacedSource { PlacedSource(sourceID: id, x: 240, y: 0, w: 1440, h: 1080) }
    /// ROI of the SD target: its rectangle minus the M6 upper layer (x < 240) and 4 px.
    nonisolated static let sdROI = CGRect(x: 244, y: 0, width: 1436, height: 1080)
    nonisolated static let m6Upper = CGRect(x: 0, y: 72.5, width: 240, height: 135)

    static func spectrumStyle(_ mode: SpectrumItemStyle.Mode, y: Int, red: Int, green: Int, blue: Int) -> SpectrumItemStyle {
        var s = SpectrumItemStyle.provisionalDefault
        s.mode = mode; s.maxHeightMilli = 120_000; s.thicknessMilli = 12_000; s.softnessPercent = 0
        s.startYMilli = y * 1000; s.endYMilli = y * 1000; s.red = red; s.green = green; s.blue = blue
        return s
    }
    /// Spectrum box (mirrored sides): x between the end points ± thickness, y ± (max height + thickness).
    nonisolated static func spectrumBox(_ s: SpectrumItemStyle) -> [Double] {
        let t = Double(s.thicknessMilli) / 1000, hgt = Double(s.maxHeightMilli) / 1000
        let x0 = Double(min(s.startXMilli, s.endXMilli)) / 1000 - t, x1 = Double(max(s.startXMilli, s.endXMilli)) / 1000 + t
        let y0 = Double(min(s.startYMilli, s.endYMilli)) / 1000 - hgt - t, y1 = Double(max(s.startYMilli, s.endYMilli)) / 1000 + hgt + t
        return [x0, y0, x1, y1]
    }
    static func subtitleBox(_ text: String, _ style: SubtitleStyle) -> [Double] {
        let r = SubtitleRenderer.render(text: text, style: style).rect
        return [r.minX, r.minY, r.maxX, r.maxY]
    }
    static func subtitleStyle(y: Int, effects: Bool) -> SubtitleStyle {
        var s = SubtitleStyle.default
        s.sizeTenths = 640; s.xMilli = 960_000; s.yMilli = y * 1000
        if effects { s.outline = .default; s.shadow = .default; s.background = .default }
        return s
    }

    static func make(_ name: String, assets a: [String: MediaAsset]) throws -> ParityScene {
        func asset(_ f: String) throws -> MediaAsset { guard let x = a[f] else { throw SceneError.missing(f) }; return x }
        let none: (Int) -> [[Double]]? = { _ in [] }
        switch name {
        case "CAL", "RES":
            let file = name == "CAL" ? "otf-CAL.mp4" : "otf-RES.mp4", src = try asset(file)
            let t = try Timeline().registering(src).placing(media: src.id, at: 0, videoLane: Lane.videoID, audioLane: nil, clipID: id(1))
            let pid = name == "CAL" ? ParityLayout.calibrationID : ParityLayout.resamplingID
            return ParityScene(name: name, timeline: t, reference: nil, frames: name == "CAL" ? [5, 15] : [5], target: { _ in fullCoded(pid) }, sourceFrame: { $0 },
                               sourceFile: { _ in file }, layout: none, colourTagged: nil, roi: nil, upperLayer: nil, edgeFrames: [], anchorFrame: nil, files: [file])
        case "C", "D", "E", "F":
            let par = try asset("otf-PAR.mp4"), tone = try asset("otf-tone-5s.wav")
            func build(_ overlays: Bool) throws -> (Timeline, [Int: [[Double]]]) {
                var t = try Timeline().registering(par).registering(tone).addingLane(.audio, name: "Tone", id: id(10))
                    .placing(media: par.id, at: 0, videoLane: Lane.videoID, audioLane: nil, clipID: id(1))
                    .placing(media: tone.id, at: 0, videoLane: nil, audioLane: id(10), clipID: id(2))
                var boxes: [Int: [[Double]]] = [:]
                guard overlays else { return (t, boxes) }
                guard let key = t.clip(id(2))?.lineageKey else { throw SceneError.missing("tone clip") }
                func spectrum(_ lane: Int, _ item: Int, _ style: SpectrumItemStyle, _ range: Range<Int>) throws {
                    t = try t.addingLane(.spectrum, name: "SP\(lane)", id: id(lane), outward: true)
                        .addingSpectrum(lane: id(lane), at: range.lowerBound, length: range.count, sourceKey: key, style: style, id: id(item))
                    for k in range { boxes[k, default: []].append(spectrumBox(style)) }
                }
                func subtitle(_ item: Int, _ text: String, _ style: SubtitleStyle, _ range: Range<Int>) throws {
                    if t.lanes.first(where: { $0.id == id(40) }) == nil { t = try t.addingLane(.subtitle, name: "S", id: id(40), outward: true) }
                    t = try t.addingSubtitle(lane: id(40), at: range.lowerBound, length: range.count, text: text, style: style, id: id(item))
                    for k in range { boxes[k, default: []].append(subtitleBox(text, style)) }
                }
                switch name {
                case "C": try spectrum(20, 21, spectrumStyle(.digital, y: 600, red: 255, green: 220, blue: 0), 20..<100)
                          try spectrum(22, 23, spectrumStyle(.digital, y: 820, red: 255, green: 255, blue: 255), 20..<100)
                case "D": try spectrum(20, 21, spectrumStyle(.analog, y: 600, red: 255, green: 220, blue: 0), 20..<100)
                          try spectrum(22, 23, spectrumStyle(.analog, y: 820, red: 255, green: 255, blue: 255), 20..<100)
                case "E": try subtitle(41, "ON THE FRAME", subtitleStyle(y: 700, effects: false), 20..<50)
                          try subtitle(42, "ON THE FRAME", subtitleStyle(y: 700, effects: true), 60..<90)
                default:  try spectrum(20, 21, spectrumStyle(.digital, y: 640, red: 255, green: 220, blue: 0), 20..<100)
                          try spectrum(22, 23, spectrumStyle(.analog, y: 680, red: 0, green: 200, blue: 255), 20..<100)
                          try subtitle(41, "ON THE FRAME", subtitleStyle(y: 700, effects: true), 40..<80)
                }
                return (t, boxes)
            }
            let (t, boxes) = try build(true), (r, _) = try build(false)
            let frames: [Int] = name == "E" ? [10, 20, 35, 49, 50, 60, 75, 89, 90] : [10, 19, 20, 50, 99, 100]
            return ParityScene(name: name, timeline: t, reference: r, frames: frames, target: { _ in fullCoded(ParityLayout.sceneID) }, sourceFrame: { $0 },
                               sourceFile: { _ in "otf-PAR.mp4" }, layout: { boxes[$0] ?? [] }, colourTagged: nil, roi: nil, upperLayer: nil,
                               edgeFrames: [], anchorFrame: nil, files: ["otf-PAR.mp4", "otf-tone-5s.wav"])
        case "G":
            let ta = try asset("otf-TA.mp4"), tb = try asset("otf-TB.mp4"), gray = try asset("gray.mov"), red = try asset("plate-red-640x480.mp4")
            var t = try Timeline().registering(ta).registering(tb).registering(gray).registering(red)
                .addingLane(.video, name: "V2", id: id(11), outward: true).addingLane(.audio, name: "A2", id: id(12))
            t = try t.placing(media: ta.id, at: 10, videoLane: Lane.videoID, audioLane: Lane.audioID, clipID: id(1))
                .placing(media: tb.id, at: 10, videoLane: id(11), audioLane: id(12), clipID: id(2))
            t = try t.settingTransform(clip: id(2), ClipTransform(scale: 0.5, x: 300, y: 150))
            t = try t.trimmingForParity(clip: id(1), length: 60).trimmingForParity(clip: id(2), length: 60)
            t = try t.placing(media: gray.id, at: 70, videoLane: Lane.videoID, audioLane: gray.hasAudio ? Lane.audioID : nil, clipID: id(3))
            t = try t.trimmingForParity(clip: id(3), length: 30)
            t = try t.placing(media: red.id, at: 100, videoLane: Lane.videoID, audioLane: nil, clipID: id(4)).trimmingForParity(clip: id(4), length: 30)
            return ParityScene(name: name, timeline: t, reference: nil, frames: [5, 15, 40, 69, 70, 85, 99, 100, 115],
                               target: { k in k < 10 ? nil : (k < 70 ? fullCoded(ParityLayout.otfTA) : (k < 100 ? full : PlacedSource(sourceID: -1, x: 240, y: 0, w: 1440, h: 1080))) },
                               sourceFrame: { k in (10..<70).contains(k) ? k - 10 : nil },
                               sourceFile: { k in k < 10 ? nil : (k < 70 ? "otf-TA.mp4" : (k < 100 ? "gray.mov" : "plate-red-640x480.mp4")) },
                               layout: none, colourTagged: nil, roi: nil, upperLayer: nil, edgeFrames: [70, 85, 99], anchorFrame: 115,
                               files: ["otf-TA.mp4", "otf-TB.mp4", "gray.mov", "plate-red-640x480.mp4"])
        case "M1", "M2", "M3", "M4", "M5", "M6":
            let file = ["M2": "otf-SD601.mp4", "M3": "otf-HD709.mp4", "M4": "otf-HDU.mp4"][name] ?? "otf-SDU.mp4"
            let sid = ["M2": ParityLayout.sd601ID, "M3": ParityLayout.hd709ID, "M4": ParityLayout.hdUntaggedID][name] ?? ParityLayout.sdUntaggedID
            let src = try asset(file)
            var t = try Timeline().registering(src).placing(media: src.id, at: 0, videoLane: Lane.videoID, audioLane: nil, clipID: id(1))
            var files = [file]
            if name == "M5" { t = try t.addingLane(.video, name: "V2 (empty)", id: id(11), outward: true) }
            if name == "M6" {
                let tb = try asset("otf-TB.mp4")
                t = try t.registering(tb).addingLane(.video, name: "V2", id: id(11), outward: true).addingLane(.audio, name: "A2", id: id(12))
                    .placing(media: tb.id, at: 0, videoLane: id(11), audioLane: id(12), clipID: id(2))
                t = try t.settingTransform(clip: id(2), ClipTransform(scale: 0.125, x: -840, y: -400)).trimmingForParity(clip: id(2), length: 30)
                files.append("otf-TB.mp4")
            }
            let hd = name == "M3" || name == "M4"
            let placed = hd ? fullCoded(sid) : pillar(sid)
            return ParityScene(name: name, timeline: t, reference: nil, frames: [5, 15, 25], target: { _ in placed }, sourceFrame: { $0 },
                               sourceFile: { _ in file }, layout: none, colourTagged: name == "M2" || name == "M3",
                               roi: hd ? CGRect(x: 0, y: 0, width: 1920, height: 1080) : sdROI, upperLayer: name == "M6" ? m6Upper : nil,
                               edgeFrames: [], anchorFrame: nil, files: files)
        default:
            throw SceneError.unknown(name)
        }
    }

    enum SceneError: Error, CustomStringConvertible {
        case missing(String), unknown(String)
        var description: String { switch self { case .missing(let s): "missing \(s)"; case .unknown(let s): "unknown scenario \(s)" } }
    }
}

extension Timeline {
    /// Shortens a placed clip (and its linked audio) to `length` frames from its start, using the existing trim edit.
    func trimmingForParity(clip id: UUID, length: Int) throws -> Timeline {
        guard let c = clip(id), c.length > length else { return self }
        return try trimmingEnd(clip: id, by: length - c.length)   // linked audio follows (existing group trim)
    }
}
#endif
