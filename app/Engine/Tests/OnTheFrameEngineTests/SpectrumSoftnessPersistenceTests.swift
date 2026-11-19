import XCTest
@testable import OnTheFrameEngine

final class SpectrumSoftnessPersistenceTests: XCTestCase {
    private typealias Model = StillImageProjectModel.Project
    private let outer = SpectrumItemStyle.RGB(red: 17, green: 31, blue: 47)

    private func fixture(still: Bool) async throws -> Model {
        var model = try await StillImageProjectCodecTests().reactionProject(image: still)
        let item = try XCTUnwrap(model.spectra?.first)
        var style = item.style
        style.red = 12
        style.green = 34
        style.blue = 56
        style.outsideRGB = outer
        style.alpha = 173
        style.hueInterpolationDegrees = 217
        style.reactionPercent = 150
        style.windowMs = 300
        style.offsetMs = -500
        model.spectra = [item.with(start: 4, length: 91, style: style)]
        return model
    }

    private func directory() throws -> URL {
        let root = ProcessInfo.processInfo.environment["OTF_MODEL03_RUN"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let dir = root.appendingPathComponent("softness-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func fields(_ bytes: Data) throws -> [String: Any] {
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(raw["version"] as? Int, 11)
        let items = try XCTUnwrap(raw["spectra"] as? [[String: Any]])
        return try XCTUnwrap(items.first?["style"] as? [String: Any])
    }

    func testSoftnessFormat11DiskRoundTrips() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for still in [false, true] {
            let model = try await fixture(still: still)
            let seed = try OperationalProjectAdapter.restore(model)
            let original = try XCTUnwrap(seed.timeline.spectra.first)
            XCTAssertNotNil(original.sourceKey)
            let destination = dir.appendingPathComponent(still ? "still.ontheframe" : "temporal.ontheframe")
            let bookmarks = Dictionary(uniqueKeysWithValues: model.media.compactMap { entry in
                entry.bookmark.map { (entry.ref.id, $0) }
            })
            for value in [0, 1, 50, 100] {
                var style = original.style
                style.softnessPercent = value
                let timeline = try seed.timeline.settingSpectrumStyle(original.id, style)
                let project = try ProjectPersistence.make(timeline: timeline, projectID: model.projectID, bookmarks: bookmarks)
                let receipt = try ProjectPersistence.write(project, to: destination)
                XCTAssertNil(receipt.postCommitWarning)
                let bytes = try Data(contentsOf: destination)
                let opened = try ProjectPersistence.decode(bytes)
                XCTAssertEqual(opened.version, 11)
                XCTAssertEqual(opened.projectID, model.projectID)
                XCTAssertEqual(opened.timeline, timeline)
                XCTAssertEqual(opened.timeline.spectra.first, original.with(style: style))
                XCTAssertEqual(opened.timeline.audioClips, seed.timeline.audioClips)
                XCTAssertEqual(opened.timeline.spectra.first?.sourceKey, original.sourceKey)
                XCTAssertEqual(opened.timeline.spectra.first?.style.thicknessMilli, 3125)
                XCTAssertEqual(opened.timeline.spectra.first?.style.startXMilli, 320123)
                let reopenedBookmarks = Dictionary(uniqueKeysWithValues: opened.media.compactMap { entry in
                    entry.bookmark.map { (entry.id, $0) }
                })
                XCTAssertEqual(reopenedBookmarks, bookmarks)
                XCTAssertEqual(try StillImageProjectCodec.decode(bytes).spectra, timeline.spectra)
                if still {
                    XCTAssertThrowsError(try ProjectFile.decode(bytes))
                } else {
                    XCTAssertEqual(try ProjectFile.decode(bytes).timeline, timeline)
                }
                let wire = try fields(bytes)
                XCTAssertNil(wire["softnessPercent"])
                let appearance = try XCTUnwrap(wire["appearance"] as? [String: Any])
                let keys: Set<String> = ["contractVersion", "outsideRGB", "hueInterpolationDegrees"]
                XCTAssertEqual(Set(appearance.keys), value == 0 ? keys : keys.union(["softnessPercent"]))
                XCTAssertEqual(appearance["contractVersion"] as? Int, value == 0 ? 2 : 3)
                XCTAssertEqual(appearance["softnessPercent"] as? Int, value == 0 ? nil : value)
                XCTAssertEqual(appearance["hueInterpolationDegrees"] as? Int, 217)
                XCTAssertEqual(appearance["outsideRGB"] as? [String: Int], ["red": 17, "green": 31, "blue": 47])
                XCTAssertEqual(wire["red"] as? Int, 12)
                XCTAssertEqual(wire["green"] as? Int, 34)
                XCTAssertEqual(wire["blue"] as? Int, 56)
                XCTAssertEqual(wire["alpha"] as? Int, 173)
            }
        }
    }

    func testLegacyAndExplicitZeroOpenSaveReopen() async throws {
        let dir = try directory(), suite = StillImageProjectCodecTests()
        defer { try? FileManager.default.removeItem(at: dir) }
        for still in [false, true] {
            let model = try await fixture(still: still)
            let original = try XCTUnwrap(model.spectra?.first)
            let raw = try suite.json(model)
            let color = ["red": 17, "green": 31, "blue": 47]
            let cases: [(String, Int, [String: Any]?)] = [
                ("legacy", still ? 9 : 8, nil),
                ("reaction", 10, nil),
                ("v1", 11, ["contractVersion": 1, "outsideRGB": color]),
                ("v2", 11, ["contractVersion": 2, "outsideRGB": color, "hueInterpolationDegrees": 217]),
                ("v3zero", 11, ["contractVersion": 3, "outsideRGB": color, "hueInterpolationDegrees": 217, "softnessPercent": 0])
            ]
            for (name, version, appearance) in cases {
                var input = suite.changingAppearance(raw, appearance)
                input["version"] = version
                if version < 10 { input = suite.changingReaction(input, nil) }
                let source = dir.appendingPathComponent("\(still)-\(name).ontheframe")
                let saved = dir.appendingPathComponent("\(still)-\(name)-saved.ontheframe")
                let initial = try suite.data(input)
                try initial.write(to: source, options: .withoutOverwriting)
                let opened = try ProjectPersistence.decode(Data(contentsOf: source))
                var expected = original.style
                if version < 10 { expected.reactionPercent = 100 }
                if appearance == nil { expected.outsideRGB = nil }
                if appearance?["hueInterpolationDegrees"] == nil { expected.hueInterpolationDegrees = 0 }
                XCTAssertEqual(opened.version, version)
                XCTAssertEqual(opened.timeline.spectra.first, original.with(style: expected))
                XCTAssertEqual(opened.timeline.spectra.first?.style.softnessPercent, 0)
                let receipt = try ProjectPersistence.write(opened, to: saved)
                XCTAssertNil(receipt.postCommitWarning)
                let bytes = try Data(contentsOf: saved)
                let normalized = try XCTUnwrap(try fields(bytes)["appearance"] as? [String: Any])
                XCTAssertEqual(normalized["contractVersion"] as? Int, 2)
                XCTAssertNil(normalized["softnessPercent"])
                XCTAssertEqual(try ProjectPersistence.decode(bytes).timeline, opened.timeline)
                XCTAssertEqual(try Data(contentsOf: source), initial)
            }
        }
    }

    func testInvalidV3WireTokensAcrossReadersAndEncodings() async throws {
        let suite = StillImageProjectCodecTests()
        let version = #""contractVersion":3"#, hue = #""hueInterpolationDegrees":217"#
        let rgb = #""outsideRGB":{"red":17,"green":31,"blue":47}"#, soft = #""softnessPercent":50"#
        func field(_ members: [String]) -> String {
            #""appearance":{"# + members.joined(separator: ",") + "}"
        }
        let good = field([version, hue, rgb, soft])
        var invalid = [
            field([hue, rgb, soft]), field([version, rgb, soft]), field([version, hue, soft]),
            field([version, hue, rgb]), field([version, hue, rgb, soft, #""extra":1"#]),
            field([version, hue, rgb, soft, #" "softnessPerce\u006et":50"#]),
            field([version, version, hue, rgb, soft]), field([version, hue, hue, rgb, soft]),
            field([version, hue, rgb, rgb, soft]), good + "," + good,
            good.replacingOccurrences(of: version, with: #""contractVersion":4"#),
            good.replacingOccurrences(of: version, with: #""contractVersion":2"#),
            good.replacingOccurrences(of: version, with: #""contractVersion":1"#),
            good.replacingOccurrences(of: version, with: #""contractVersion":3.0"#),
            good.replacingOccurrences(of: hue, with: #""hueInterpolationDegrees":361"#),
            good.replacingOccurrences(of: hue, with: #""hueInterpolationDegrees":-1"#),
            good.replacingOccurrences(of: hue, with: #""hueInterpolationDegrees":180.5"#),
            good.replacingOccurrences(of: hue, with: #""hueInterpolationDegrees":true"#),
            good.replacingOccurrences(of: rgb, with: #""outsideRGB":null"#),
            good.replacingOccurrences(of: rgb, with: #""outsideRGB":{"red":17,"green":31}"#),
            good.replacingOccurrences(of: #""red":17"#, with: #""red":17,"\u0072ed":17"#),
            good.replacingOccurrences(of: #""red":17"#, with: #""red":17,"alpha":255"#),
            good.replacingOccurrences(of: #""red":17"#, with: #""red":256"#),
            good.replacingOccurrences(of: #""red":17"#, with: #""red":17.5"#),
            good.replacingOccurrences(of: #""red":17"#, with: #""red":true"#)
        ]
        for token in ["-1", "-0", "101", "50.0", "50.5", "5e1", "true", #""50""#, "null", "{}", "[]"] {
            invalid.append(good.replacingOccurrences(of: soft, with: #""softnessPercent":"# + token))
        }
        for still in [false, true] {
            let model = try await fixture(still: still)
            let base = suite.changingAppearance(try suite.json(model), "__APPEARANCE_TOKEN__")
            let data = try JSONSerialization.data(withJSONObject: base, options: [.sortedKeys])
            let template = String(decoding: data, as: UTF8.self)
            let marker = #""appearance":"__APPEARANCE_TOKEN__""#
            XCTAssertEqual(template.components(separatedBy: marker).count, 2)
            let valid = template.replacingOccurrences(of: marker, with: good)
            let items = try XCTUnwrap(base["spectra"] as? [[String: Any]])
            let style = try XCTUnwrap(items.first?["style"] as? [String: Any])
            func member(_ name: String, _ object: Any) throws -> String {
                let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                return "\"\(name)\":" + String(decoding: data, as: UTF8.self).replacingOccurrences(of: marker, with: good)
            }
            var bad = invalid.map { template.replacingOccurrences(of: marker, with: $0) } + [
                valid.replacingOccurrences(of: #""red":12"#, with: #""red":12,"\u0072ed":100"#),
                valid.replacingOccurrences(of: #""red":12"#, with: #""red":12.0"#),
                valid.replacingOccurrences(of: #""red":12"#, with: #""red":12.5"#),
                valid.replacingOccurrences(of: #""blue":56"#, with: #""blue":256"#),
                valid.replacingOccurrences(of: #""alpha":173"#, with: #""alpha":173,"alpha":1"#),
                valid.replacingOccurrences(of: #""alpha":173"#, with: #""alpha":173.0"#)
            ]
            for parent in [try member("style", style), try member("spectra", items)] {
                XCTAssertEqual(valid.components(separatedBy: parent).count, 2)
                let other = parent.replacingOccurrences(of: soft, with: #""softnessPercent":100"#)
                bad.append(valid.replacingOccurrences(of: parent, with: parent + "," + other))
            }
            for version in [still ? 9 : 8, 10, 11] {
                var raw = try suite.json(model)
                if version < 11 { raw = suite.changingAppearance(raw, nil) }
                if version < 10 { raw = suite.changingReaction(raw, nil) }
                raw["version"] = version
                var spectra = try XCTUnwrap(raw["spectra"] as? [[String: Any]])
                var misplaced = try XCTUnwrap(spectra[0]["style"] as? [String: Any])
                misplaced["softnessPercent"] = 50
                spectra[0]["style"] = misplaced
                raw["spectra"] = spectra
                bad.append(String(decoding: try suite.data(raw), as: UTF8.self))
            }
            let encodings: [(String.Encoding, [UInt8])] = [(.utf8, []), (.utf16LittleEndian, [255, 254]), (.utf32BigEndian, [0, 0, 254, 255])]
            for (encoding, bom) in encodings {
                let goodBytes = Data(bom) + (try XCTUnwrap(valid.data(using: encoding)))
                XCTAssertEqual(try ProjectPersistence.decode(goodBytes).timeline.spectra[0].style.softnessPercent, 50)
                for (index, text) in bad.enumerated() {
                    let bytes = Data(bom) + (try XCTUnwrap(text.data(using: encoding)))
                    let description = "mutation \(index), still \(still), encoding \(encoding)"
                    XCTAssertThrowsError(try StillImageProjectCodec.decode(bytes), description)
                    XCTAssertThrowsError(try ProjectPersistence.decode(bytes), description)
                    if !still { XCTAssertThrowsError(try ProjectFile.decode(bytes), description) }
                }
            }
        }
    }
}
