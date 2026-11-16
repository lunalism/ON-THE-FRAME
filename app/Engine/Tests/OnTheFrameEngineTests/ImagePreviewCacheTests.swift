import XCTest
import ImageIO
import CoreGraphics
@testable import OnTheFrameEngine

final class ImagePreviewCacheTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["OTF_HIGHRES_CACHE_RUN"] ??
                ProcessInfo.processInfo.environment["OTF_STILL_PROBE_RUN"] else {
            throw XCTSkip("explicit disposable image cache fixtures")
        }
        root = URL(fileURLWithPath: path).appendingPathComponent("preview-cache-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    private func write(_ url: URL, width: Int = 64, height: Int = 32,
                       orientation: Int = 1, alpha: CGFloat = 1,
                       p3: Bool = false, red: CGFloat = 0.6) throws {
        try autoreleasepool {
            let space = try XCTUnwrap(CGColorSpace(name: p3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB))
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(try XCTUnwrap(CGColor(colorSpace: space, components: [red, 0.2, 0.4, alpha])))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,
                (url.pathExtension == "png" ? "public.png" : "public.jpeg") as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()),
                [kCGImagePropertyOrientation: orientation] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
    }
    private func fixture(_ name: String = "generated.png", width: Int = 64, height: Int = 32,
                         orientation: Int = 1, alpha: CGFloat = 1,
                         p3: Bool = false) async throws -> StillImageProjectModel.ValidatedImage {
        let url = root.appendingPathComponent(name)
        try write(url, width: width, height: height, orientation: orientation, alpha: alpha, p3: p3)
        return try await StillImageProjectModel.ValidatedImage.inspect(url)
    }
    private func image(_ proof: StillImageProjectModel.ValidatedImage,
                       cache: InternalImagePreview.Cache) async throws -> CGImage {
        try await cache.image(at: proof.url, descriptor: proof.descriptor, encodedSHA256: proof.encodedSHA256).image
    }
    func testHighResolutionProxyIsBoundedAndReused() async throws {
        let proof = try await fixture(width: 4096, height: 2048), cache = InternalImagePreview.Cache()
        let original = try Data(contentsOf: proof.url)
        let first = try await image(proof, cache: cache), second = try await image(proof, cache: cache)
        XCTAssertTrue(first === second)
        XCTAssertEqual(first.width, 2048); XCTAssertEqual(first.height, 1024)
        XCTAssertEqual(first.bitsPerComponent, 8)
        XCTAssertEqual(first.colorSpace?.name as String?, CGColorSpace.sRGB as String)
        let stats = await cache.statistics
        XCTAssertEqual(stats.decodes, 1); XCTAssertEqual(stats.hits, 1); XCTAssertEqual(stats.misses, 1)
        XCTAssertEqual(stats.entries, 1); XCTAssertEqual(stats.retainedBytes, first.bytesPerRow * first.height)
        XCTAssertLessThanOrEqual(stats.retainedBytes, 2048 * 2048 * 4)
        XCTAssertEqual(proof.descriptor.width, 4096); XCTAssertEqual(proof.descriptor.height, 2048)
        XCTAssertEqual(try Data(contentsOf: proof.url), original)
    }
    func testConcurrentRequestsDecodeOnce() async throws {
        let proof = try await fixture(), cache = InternalImagePreview.Cache()
        let values = try await withThrowingTaskGroup(of: InternalImagePreview.Cache.Representation.self) { group in
            for _ in 0..<8 {
                group.addTask { try await cache.image(at: proof.url, descriptor: proof.descriptor, encodedSHA256: proof.encodedSHA256) }
            }
            var values: [InternalImagePreview.Cache.Representation] = []
            for try await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(values.count, 8)
        XCTAssertTrue(values.allSatisfy { $0.image === values[0].image })
        let stats = await cache.statistics
        XCTAssertEqual(stats.decodes, 1); XCTAssertEqual(stats.hits, 7); XCTAssertEqual(stats.entries, 1)
    }
    func testRevisionChangeInvalidatesOldRepresentationAndMissingHitFails() async throws {
        let proof = try await fixture(), cache = InternalImagePreview.Cache()
        let first = try await image(proof, cache: cache)
        try write(proof.url, width: 96, height: 48, red: 0.1)
        let replacement = try await StillImageProjectModel.ValidatedImage.inspect(proof.url)
        XCTAssertNotEqual(replacement.encodedSHA256, proof.encodedSHA256)
        let second = try await image(replacement, cache: cache)
        XCTAssertFalse(first === second); XCTAssertEqual(second.width, 96)
        let stats = await cache.statistics
        XCTAssertEqual(stats.decodes, 2); XCTAssertEqual(stats.invalidations, 1); XCTAssertEqual(stats.entries, 1)
        let moved = proof.url.appendingPathExtension("missing")
        try FileManager.default.moveItem(at: proof.url, to: moved)
        do { _ = try await image(replacement, cache: cache); XCTFail("cached pixels authorized a missing source") }
        catch let failure as InternalImagePreview.SecondReadFailure { XCTAssertEqual(failure, .missing) }
        let after = await cache.statistics
        XCTAssertEqual(after.hits, stats.hits); XCTAssertEqual(after.decodes, stats.decodes)
    }
    func testByteAndEntryBudgetsEvictAndOversizedEntryIsNotRetained() async throws {
        var proofs: [StillImageProjectModel.ValidatedImage] = []
        for name in ["one.png", "two.png", "three.png"] { proofs.append(try await fixture(name)) }
        let cost = 64 * 32 * 4
        for cache in [InternalImagePreview.Cache(byteLimit: cost * 2, entryLimit: 8),
                      InternalImagePreview.Cache(byteLimit: cost * 8, entryLimit: 2)] {
            for proof in proofs { _ = try await image(proof, cache: cache) }
            let stats = await cache.statistics
            XCTAssertEqual(stats.entries, 2); XCTAssertEqual(stats.evictions, 1)
            XCTAssertLessThanOrEqual(stats.retainedBytes, stats.maxBytes)
            _ = try await image(proofs[0], cache: cache)
            let reloaded = await cache.statistics
            XCTAssertEqual(reloaded.decodes, 4); XCTAssertEqual(reloaded.evictions, 2)
        }
        let tooSmall = InternalImagePreview.Cache(byteLimit: cost - 1, entryLimit: 1)
        do { _ = try await image(proofs[0], cache: tooSmall); XCTFail("oversized entry retained") }
        catch let failure as InternalImagePreview.SecondReadFailure { XCTAssertEqual(failure, .resources) }
        let stats = await tooSmall.statistics
        XCTAssertEqual(stats.entries, 0); XCTAssertEqual(stats.retainedBytes, 0)
    }
    func testCancelledRequestDoesNotDecodeOrPublishIntoAnotherProjectCache() async throws {
        let proof = try await fixture(), old = InternalImagePreview.Cache(), current = InternalImagePreview.Cache()
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await old.image(at: proof.url, descriptor: proof.descriptor, encodedSHA256: proof.encodedSHA256)
        }
        do { _ = try await task.value; XCTFail("cancelled request published") }
        catch is CancellationError {}
        let oldStats = await old.statistics, currentStats = await current.statistics
        XCTAssertEqual(oldStats.entries, 0); XCTAssertEqual(oldStats.decodes, 0)
        XCTAssertEqual(currentStats.entries, 0); XCTAssertEqual(currentStats.decodes, 0)
        _ = try await image(proof, cache: current)
        let fresh = await current.statistics
        XCTAssertEqual(fresh.entries, 1); XCTAssertEqual(fresh.decodes, 1)
    }
    func testP3OrientationAndAlphaUseOrientedSRGBProxy() async throws {
        let jpeg = try await fixture("p3-orientation.jpg", width: 3072, height: 1536, orientation: 6, p3: true)
        let oriented = try await image(jpeg, cache: InternalImagePreview.Cache())
        XCTAssertEqual(oriented.width, 1024); XCTAssertEqual(oriented.height, 2048)
        XCTAssertEqual(oriented.colorSpace?.name as String?, CGColorSpace.sRGB as String)
        let png = try await fixture("alpha.png", width: 3072, height: 1536, alpha: 0.5)
        let transparent = try await image(png, cache: InternalImagePreview.Cache())
        let data = try XCTUnwrap(transparent.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        XCTAssertLessThanOrEqual(abs(Int(bytes[3]) - 128), 1)
        XCTAssertLessThanOrEqual(bytes[0], bytes[3]); XCTAssertLessThanOrEqual(bytes[1], bytes[3])
        XCTAssertLessThanOrEqual(bytes[2], bytes[3])
    }
    func testProxyTextureCoordinatesPreserveOriginalPlacement() async throws {
        let proof = try await fixture(width: 4096, height: 2048), id = UUID()
        let base = try Timeline().registeringImage(proof, id: id)
            .placingImage(media: id, at: 0, lane: Lane.videoID, length: 150)
        let edit = ClipTransform(scaleMicro: 1_250_000, offsetXMilli: 42_000, offsetYMilli: -13_000)
        let t = try base.settingTransform(clip: base.clips[0].id, edit)
        let cache = InternalImagePreview.Cache()
        let plan = try await InternalImagePreview.plan(t, media: [:], enabled: true, cache: cache)
        let instruction = try XCTUnwrap(plan.videoComposition.instructions.first as? ImagePreviewInstruction)
        let layer = try XCTUnwrap(instruction.layers.first), texture = try XCTUnwrap(layer.image)
        XCTAssertEqual(texture.width, 2048); XCTAssertEqual(texture.height, 1024)
        let original = CGSize(width: proof.descriptor.displayWidth, height: proof.descriptor.displayHeight)
        let center = CGPoint(x: 960, y: 540)
        let fit = CompositionPlanner.fitTransform(natural: original, preferred: .identity, render: RenderSettings.m1.renderSize)
            .concatenating(CGAffineTransform(translationX: -center.x, y: -center.y))
            .concatenating(CGAffineTransform(scaleX: edit.scale, y: edit.scale))
            .concatenating(CGAffineTransform(translationX: center.x + edit.x, y: center.y + edit.y))
        for point in [CGPoint.zero, CGPoint(x: CGFloat(texture.width), y: CGFloat(texture.height))] {
            let actual = point.applying(layer.inverse.inverted())
            let expected = CGPoint(x: point.x * original.width / CGFloat(texture.width),
                                   y: point.y * original.height / CGFloat(texture.height)).applying(fit)
            XCTAssertEqual(actual.x, expected.x, accuracy: 0.000001)
            XCTAssertEqual(actual.y, expected.y, accuracy: 0.000001)
        }
        XCTAssertEqual(t.mediaCatalog.first?.still?.reference.image.width, 4096)
        XCTAssertEqual(t.clips.first?.length, 150)
        // Default nil-cache original path is retained for existing internal export.
        let full = try await InternalImagePreview.plan(t, media: [:], enabled: true)
        let fullInstruction = try XCTUnwrap(full.videoComposition.instructions.first as? ImagePreviewInstruction)
        XCTAssertEqual(fullInstruction.layers.first?.image?.width, 4096)
    }
}
