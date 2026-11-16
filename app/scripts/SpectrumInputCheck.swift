import AppKit
import AVFoundation
import CryptoKit
import SwiftUI
@testable import OnTheFrame
@testable import OnTheFrameEngine

struct InputCheckFailure: Error { let message: String }
@MainActor final class InputChecks {
    var checks = [String: Bool](), evidence = [String: Any]()
    func require(_ name: String, _ condition: Bool) throws {
        checks[name] = condition; print("\(condition ? "PASS" : "FAIL") \(name)")
        if !condition { throw InputCheckFailure(message: name) }
    }
    func wait(_ name: String, _ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while !predicate() && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try require(name, predicate())
    }
    func save(_ root: URL, error: Error?) throws {
        let payload: [String: Any] = ["checks": checks, "evidence": evidence,
            "pass": error == nil && !checks.isEmpty && checks.values.allSatisfy { $0 },
            "error": error.map { String(describing: $0) as Any } ?? NSNull(),
            "physicalInputClaimed": false, "ownerSmoothnessClaimed": false,
            "method": "Draft parsing and existing Store transaction semantics; no responder, raster, FFT or export execution"]
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("result.json"), options: .withoutOverwriting)
    }
}
func inputFileSHA(_ url: URL) throws -> String {
    let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
    var hash = SHA256()
    while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}
struct PixelField {
    let name: String, draft: WritableKeyPath<SpectrumStyleDraft, String>
    let model: WritableKeyPath<SpectrumItemStyle, Int>, edit: String, minimum: Int, maximum: Int
}
let pixelFields: [PixelField] = [
    .init(name: "startX", draft: \.startX, model: \.startXMilli, edit: "193", minimum: -10_000, maximum: 10_000),
    .init(name: "startY", draft: \.startY, model: \.startYMilli, edit: "541", minimum: -10_000, maximum: 10_000),
    .init(name: "endX", draft: \.endX, model: \.endXMilli, edit: "1721", minimum: -10_000, maximum: 10_000),
    .init(name: "endY", draft: \.endY, model: \.endYMilli, edit: "542", minimum: -10_000, maximum: 10_000),
    .init(name: "height", draft: \.height, model: \.maxHeightMilli, edit: "481", minimum: 0, maximum: 1080),
    .init(name: "thickness", draft: \.thickness, model: \.thicknessMilli, edit: "4", minimum: 1, maximum: 64)
]
func legacyInputStyle() -> SpectrumItemStyle {
    var style = SpectrumItemStyle.provisionalDefault
    style.startXMilli = 192_125; style.startYMilli = 540_125
    style.endXMilli = 1_720_125; style.endYMilli = 541_125
    style.maxHeightMilli = 480_125; style.thicknessMilli = 3125
    style.reactionPercent = 150; style.alpha = 192; return style
}
func roundedDecimalOracle(_ value: Int) -> Int {
    var scaled = Decimal(string: String(value))! / Decimal(1000), rounded = Decimal()
    NSDecimalRound(&rounded, &scaled, 0, .plain)
    return NSDecimalNumber(decimal: rounded).intValue
}
func rejects(_ draft: SpectrumStyleDraft, from style: SpectrumItemStyle) -> Bool {
    do { _ = try draft.style(from: style); return false } catch { return true }
}
@MainActor func draftChecks(_ c: InputChecks) throws {
    let style = legacyInputStyle(), initial = SpectrumStyleDraft(style)
    let edges = [Int.min, Int.min + 1, -10_000_000, -9_999_875, -1500, -1499, -1000,
                 -501, -500, -499, -1, 0, 1, 499, 500, 501, 1000, 1499, 1500, 9_999_875, 10_000_000, Int.max]
    try c.require("signed rounding matches independent Decimal oracle including Int extremes", edges.allSatisfy {
        SpectrumStyleDraft.wholePixels($0) == roundedDecimalOracle($0)
            && SpectrumStyleDraft.pixels($0) == String(roundedDecimalOracle($0))
    })
    try c.require("negative and positive exact halves round away from zero",
        [-1500, -500, 500, 1500].map(SpectrumStyleDraft.wholePixels) == [-2, -1, 1, 2])
    try c.require("opening integer display preserves every original milli", try initial.style(from: style) == style)
    for field in pixelFields {
        let label = field.name, displayed = initial[keyPath: field.draft]
        try c.require(label + " display is rounded integer", displayed == String(roundedDecimalOracle(style[keyPath: field.model]))
            && displayed.range(of: #"^-?[0-9]+$"#, options: .regularExpression) != nil)
        var same = initial
        for _ in 0..<3 { same[keyPath: field.draft] = displayed }
        try c.require(label + " identical Tab-style writebacks preserve exact model", try same.style(from: style) == style)
        let oldFraction = NSDecimalNumber(value: style[keyPath: field.model]).dividing(by: NSDecimalNumber(value: 1000)).stringValue
        for invalid in [oldFraction, displayed + ".0", ".5", "1e3", "NaN", "9223372036854775808", String(Int.max),
                        String(field.minimum - 1), String(field.maximum + 1)] {
            var draft = initial; draft[keyPath: field.draft] = invalid
            try c.require(label + " rejects " + invalid, rejects(draft, from: style))
            draft[keyPath: field.draft] = displayed
            try c.require(label + " restores unchanged display after " + invalid, try draft.style(from: style) == style)
        }
        var edited = initial; edited[keyPath: field.draft] = field.edit
        var expected = style; expected[keyPath: field.model] = Int(field.edit)! * 1000
        try c.require(label + " integer edit changes only selected milli field", try edited.style(from: style) == expected)
        edited[keyPath: field.draft] = displayed
        try c.require(label + " changing then restoring before commit preserves source", try edited.style(from: style) == style)
        for integer in [field.minimum, field.maximum] {
            var boundary = initial; boundary[keyPath: field.draft] = String(integer)
            var expected = style; expected[keyPath: field.model] = integer * 1000
            try c.require(label + " accepts integer boundary " + String(integer), try boundary.style(from: style) == expected)
        }
    }
    var half = style; half.thicknessMilli = 500
    let halfDraft = SpectrumStyleDraft(half)
    try c.require("legacy half-pixel thickness displays one and remains 500", halfDraft.thickness == "1" && (try halfDraft.style(from: half)) == half)
    var close = style; close.startXMilli = 510; close.startYMilli = 510; close.endXMilli = 1218; close.endYMilli = 1218
    let closeDraft = SpectrumStyleDraft(close)
    try c.require("rounded coincident display retains valid exact subpixel geometry", close.isValid
        && closeDraft.startX == closeDraft.endX && closeDraft.startY == closeDraft.endY && (try closeDraft.style(from: close)) == close)
    var reaction = initial; reaction.reaction = "39"
    var expected = style; expected.reactionPercent = 39
    try c.require("reaction integer edit preserves all pixel precision", try reaction.style(from: style) == expected)
    for value in ["150.0", "150.125", "-1", "201", "1e2", "NaN"] {
        var draft = initial; draft.reaction = value
        try c.require("reaction rejects " + value, rejects(draft, from: style))
    }
    var color = initial; color.red = "255"; color.green = "0"; color.blue = "0"
    expected = style; expected.red = 255; expected.green = 0; expected.blue = 0
    try c.require("color draft preserves hidden alpha and every fractional pixel", try color.style(from: style) == expected)
}
@MainActor func saveAndReopen(_ s: ProjectStore, expected: Timeline, url: URL, source: URL, c: InputChecks) async throws {
    try c.require(url.lastPathComponent + " isolated save", s.writeProject(to: url))
    let document = try ProjectPersistence.decode(Data(contentsOf: url))
    try c.require(url.lastPathComponent + " Format10 unchanged", document.version == 10)
    let reopened = ProjectStore(); defer { reopened.stopAllScopes() }
    let opened = await reopened.openProject(at: url)
    try c.require(url.lastPathComponent + " reopen exact styles IDs timing and audio", opened
        && reopened.timeline.spectra == expected.spectra && reopened.timeline.audioClips == expected.audioClips
        && reopened.timeline.clips == expected.clips && reopened.timeline.subtitles == expected.subtitles
        && reopened.timeline.lanes == expected.lanes && reopened.missingMedia.isEmpty && !reopened.isDirty
        && reopened.assets.count == 1 && reopened.assets[0].url.standardizedFileURL == source.standardizedFileURL)
}
@MainActor func storeChecks(_ root: URL, source: URL, c: InputChecks) async throws {
    let media = try await MediaProbe.inspect(source), s = ProjectStore()
    defer { s.stopAllScopes() }
    s.assetCache[media.url.standardizedFileURL.path] = media
    let lane = UUID(), baseStyle = legacyInputStyle()
    let audio = try Timeline().registering(media).placing(media: media.id, at: 0, videoLane: nil, audioLane: Lane.audioID)
    guard let clip = audio.audioClips.first else { throw InputCheckFailure(message: "audio fixture placement") }
    let base = try audio.addingLane(.spectrum, name: "Integer input", id: lane)
        .addingSpectrum(lane: lane, at: 0, length: clip.length, sourceKey: clip.lineageKey, style: baseStyle)
    let id = base.spectra[0].id
    s.loadTimelineForTest(base); s.savedTimeline = base; s.select(id)
    try await c.wait("actual Gate17 fixture Preview item installed") { s.appliedGeneration == s.generation && s.player.currentItem?.status == .readyToPlay }
    try c.require("Gate17 expected 30fps duration and exact Spectrum source", clip.start == 0 && clip.end == 7316
        && s.settings.fps == 30 && s.timeline.spectrum(id)?.sourceKey == clip.lineageKey)
    let exportReason = s.exportBlockReason
    try c.require("audio-only fixture public export remains blocked", !s.canExport && exportReason?.contains("영상 원본") == true)
    try await saveAndReopen(s, expected: base, url: root.appendingPathComponent("untouched.ontheframe"), source: source, c: c)
    for field in pixelFields {
        var draft = SpectrumStyleDraft(baseStyle)
        let unchanged = draft[keyPath: field.draft]; draft[keyPath: field.draft] = unchanged
        let depth = s.history.undoDepth, generation = s.generation
        let unchangedStyle = try draft.style(from: baseStyle)
        try c.require(field.name + " passive commit accepted without dirty Undo or generation", s.updateSpectrumLiveStyle(id, style: unchangedStyle,
            project: s.projectSession, revision: s.spectrumSelectionRevision, expectedGeneration: generation, kind: "numeric")
            && s.timeline == base && s.history.undoDepth == depth && s.generation == generation && !s.isDirty)
        draft[keyPath: field.draft] = field.edit
        let style = try draft.style(from: baseStyle)
        try c.require(field.name + " Return semantic draft is an actual change", style != baseStyle)
        try c.require(field.name + " Return semantic commits one numeric Undo", s.updateSpectrumLiveStyle(id, style: style,
            project: s.projectSession, revision: s.spectrumSelectionRevision, expectedGeneration: s.generation, kind: "numeric")
            && s.timeline.spectrum(id)?.style == style && s.history.undoDepth == depth + 1 && s.isDirty && s.spectrumLiveSession == nil)
        let final = s.timeline
        try c.require(field.name + " duplicate blur semantic adds no Undo", s.updateSpectrumLiveStyle(id, style: style,
            project: s.projectSession, revision: s.spectrumSelectionRevision, expectedGeneration: s.generation, kind: "numeric")
            && s.timeline == final && s.history.undoDepth == depth + 1)
        s.undo(); try c.require(field.name + " numeric Undo restores exact fractional source", s.timeline == base && !s.isDirty && s.history.canRedo)
        s.redo(); try c.require(field.name + " numeric Redo restores actual committed result", s.timeline == final && s.history.undoDepth == depth + 1)
        s.undo(); try c.require(field.name + " reset after observed change", s.timeline == base && s.history.undoDepth == depth)
    }
    for (kind, values) in [("thickness-slider", [4, 3]), ("reaction-slider", [151, 39])] {
        let before = s.timeline, depth = s.history.undoDepth
        for value in values {
            var draft = SpectrumStyleDraft(s.timeline.spectrum(id)!.style)
            if kind == "thickness-slider" { draft.thickness = String(value) } else { draft.reaction = String(value) }
            let style = try draft.style(from: s.timeline.spectrum(id)!.style)
            try c.require(kind + " changed value " + String(value), s.updateSpectrumLiveStyle(id, style: style,
                project: s.projectSession, revision: s.spectrumSelectionRevision, expectedGeneration: s.generation, kind: kind))
        }
        s.finishSpectrumLiveSession(); let final = s.timeline
        let exact = kind == "thickness-slider" ? final.spectrum(id)?.style.thicknessMilli == 3000 : final.spectrum(id)?.style.reactionPercent == 39
        try c.require(kind + " actual final value one grouped Undo", exact && final != before && s.history.undoDepth == depth + 1)
        s.undo(); try c.require(kind + " Undo restores original source exactly", s.timeline == before && s.history.canRedo)
        s.redo(); try c.require(kind + " Redo exact", s.timeline == final)
        s.undo()
    }
    var edited = SpectrumStyleDraft(baseStyle); edited.startX = "193"
    let editedStyle = try edited.style(from: baseStyle)
    try c.require("explicit integer persistence change committed", s.updateSpectrumLiveStyle(id, style: editedStyle, project: s.projectSession,
        revision: s.spectrumSelectionRevision, expectedGeneration: s.generation, kind: "numeric") && s.timeline != base)
    try await saveAndReopen(s, expected: s.timeline, url: root.appendingPathComponent("edited.ontheframe"), source: source, c: c)
    try c.require("export gate unchanged after edit and persistence", !s.canExport && s.exportBlockReason == exportReason)
    c.evidence["exportScope"] = "Existing audio-only public gate checked; no export invoked or gate enabled"
    c.evidence["nativeScope"] = "Store numeric/gesture transaction APIs; physical Return/Tab, layout and ColorPanel checked separately"
}
@main struct SpectrumInputCheck {
    @MainActor static func main() async {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        guard CommandLine.arguments.count >= 4 else { print("usage: SpectrumInputCheck OUTPUT WAV SHA256 -OTFLayoutSuite SUITE"); exit(2) }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), source = URL(fileURLWithPath: CommandLine.arguments[2])
        let expectedHash = CommandLine.arguments[3], c = InputChecks()
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            try c.require("isolated regression preferences", EditorLayout.shared.suiteName == "dev.ontheframe.spectruminput01.regression")
            try c.require("approved Gate17 original hash before", try inputFileSHA(source) == expectedHash)
            try draftChecks(c); try await storeChecks(root, source: source, c: c)
            try c.require("approved Gate17 original hash after", try inputFileSHA(source) == expectedHash)
            c.evidence["roundingPolicy"] = "Nearest whole pixel, exact half away from zero; unchanged displayed integer retains original milli"
            c.evidence["sourceSHA256"] = expectedHash
            try c.save(root, error: nil); exit(0)
        } catch {
            do { try c.save(root, error: error) } catch { print("FAIL result writer \(error)") }
            print("FAIL \(error)"); exit(1)
        }
    }
}
