import XCTest
import AVFoundation
import CoreGraphics
import CryptoKit
import QuartzCore
@testable import OnTheFrameEngine

final class ImageAware420GateTests: XCTestCase {
    var root: URL!,base: URL!,diagnostics: IBDiagnostics!
    let w = IBContract.w,h = IBContract.h
    struct Plan { let asset: AVComposition;let custom: AVVideoComposition;let native: AVVideoComposition;let assets: [AVURLAsset];let log: IBLog }
    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["OTF_IMG_B_POC1_RUN"] else { throw XCTSkip("IMG-B-POC-1 explicit opt-in") }
        base = URL(fileURLWithPath:path).standardizedFileURL
        let permitted = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("selftest-work").path+"/"
        guard base.path.hasPrefix(permitted) else { throw IBContract.error("output root not experiment selftest-work",code:300) }
        root = base.appendingPathComponent(name.contains("testInterleavedReaderGate") ? "reader" : "player-export")
        guard !FileManager.default.fileExists(atPath:root.path) else { throw IBContract.error("fresh output root required",code:300) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        diagnostics = IBDiagnostics(root:root)
    }
    func note(_ name: String,_ fields: [String:Any]) throws { try diagnostics.note(name,fields) }
    func sourceFiles() -> [URL] {
        let dir = URL(fileURLWithPath:#filePath).deletingLastPathComponent()
        return ["ImageAware420Compositor.swift","ImageAwareReference.swift","ImageAware420GateTests.swift","ImageAwareAdmission.swift","ImageAwareAdmissionTests.swift"].map { dir.appendingPathComponent($0) }
    }
    func inputs(_ dir: URL) -> [URL] { ["bottom.mov","top.mov","middle.png"].map { dir.appendingPathComponent($0) } }
    func makePlan(_ directory: URL,png: IBImage) async throws -> Plan {
        let urls = inputs(directory),assets = [AVURLAsset(url:urls[0]),AVURLAsset(url:urls[1])]
        let comp = AVMutableComposition();var tracks: [AVMutableCompositionTrack] = []
        for (index,a) in assets.enumerated() {
            let originals = try await a.loadTracks(withMediaType:.video)
            guard let source = originals.first,let track = comp.addMutableTrack(withMediaType:.video,preferredTrackID:CMPersistentTrackID(11+index)) else { throw IBContract.error("test composition tracks",code:300) }
            try track.insertTimeRange(CMTimeRange(start:.zero,duration:CMTime(value:6,timescale:30)),of:source,at:.zero)
            tracks.append(track)
        }
        let vc = AVMutableVideoComposition(),native = AVMutableVideoComposition(),transfer = try IBTransfer(),log = IBLog()
        vc.renderSize = CGSize(width:w,height:h);vc.frameDuration = CMTime(value:1,timescale:30);vc.customVideoCompositorClass = IB420Compositor.self
        native.renderSize = vc.renderSize;native.frameDuration = vc.frameDuration
        var instructions: [IBInstruction] = [],nativeInstructions: [AVVideoCompositionInstruction] = []
        for f in 0..<6 {
            instructions.append(IBInstruction(frame:f,bottom:tracks[0].trackID,top:tracks[1].trackID,png:png,transfer:transfer,log:log))
            let ins = AVMutableVideoCompositionInstruction();ins.timeRange = instructions[f].timeRange;ins.backgroundColor = CGColor(gray:0,alpha:1)
            let lower = AVMutableVideoCompositionLayerInstruction(assetTrack:tracks[0]);lower.setTransform(.identity,at:.zero)
            if f>=2 && f<4 {
                let upper = AVMutableVideoCompositionLayerInstruction(assetTrack:tracks[1]);upper.setTransform(CGAffineTransform(translationX:960,y:540),at:.zero)
                ins.layerInstructions = [upper,lower]
            } else { ins.layerInstructions = [lower] }
            nativeInstructions.append(ins)
        }
        vc.instructions = instructions;native.instructions = nativeInstructions
        return Plan(asset:comp.copy() as! AVComposition,custom:vc.copy() as! AVVideoComposition,native:native.copy() as! AVVideoComposition,assets:assets,log:log)
    }
    func contract() throws {
        try note("premeasurement-contract",[
            "canvas":[w,h],"frames":6,"fps":30,"inputsAndOutput":"420v video-range8, 709 primaries/transfer/matrix",
            "sourceChroma":"Left; candidate nearest source chroma block, a declared experimental choice",
            "outputChroma":"Left: first column of each2x2, mean of two vertical float samples; independent reference uses the same intended sample location",
            "transfer":"ColorSync4097-point Float LUT from synthesized709 ICC to encoded sRGB and inverse; identical709/sRGB primaries assumed",
            "alpha":"PNG premultiplied RGBA8; Porter-Duff source-over in encoded sRGB",
            "geometry":"top-left integer pixels; bottom identity; top(+960,+540)1:1; clip canvas",
            "intervals":"bottom[0,6), PNG[1,5), top[2,4); both tracks sourceIn0 at timeline0 so visible top sourceIDs2/3",
            "reference":"original BGRA track reads + ICC normalization + independent CG source-over; CG reference and independently sampled420 reference both reported",
            "thresholds":"PSNR>=40dB AND flatMax<=3; no approved product sampler change",
            "scope":"test bundle only; no video-only product route replacement; no BGRA candidate frame intermediate",
            "limits":"two active plus pending FIFO4 with90s wait deadline;120s/test;1GiB RSS;512MiB new outputs;combined20GiB"])
        let bg = try IBReference.image([40,80,120,255],width:1,height:1)
        let fg = try IBReference.image([100,25,13,128],width:1,height:1)
        let c = try IBReference.context(1,1);c.draw(bg,in:CGRect(x:0,y:0,width:1,height:1));c.draw(fg,in:CGRect(x:0,y:0,width:1,height:1))
        let im = try XCTUnwrap(c.makeImage()),bytes = try IBReference.bytes(im)
        let hand = [120,65,73]
        for k in 0..<3 { XCTAssertLessThanOrEqual(abs(Int(bytes[k])-hand[k]),1) }
        XCTAssertEqual(200*1+40*0,200);XCTAssertEqual(200*0.5+40*0.5,120)
        try note("hand-controls",["CG50percentActual":bytes,"independentRoundedExpectation":hand,"opaque":200,"half":120])
    }
    func originalReferences(_ dir: URL,frame: Int,png: CGImage) async throws -> (CGImage,CGImage) {
        let urls = inputs(dir)
        let bottomBuffer = try await IBReference.read(AVURLAsset(url:urls[0]),frame:frame)
        let bottom = try IBReference.managed(bottomBuffer)
        var top: CGImage?
        if frame>=2 && frame<4 {
            let topBuffer = try await IBReference.read(AVURLAsset(url:urls[1]),frame:frame)
            top = try IBReference.managed(topBuffer)
        }
        let cg = try IBReference.composite(bottom:bottom,top:top,png:png,frame:frame)
        let sampled = try IBReference.sampled420(cg)
        return (cg,try IBReference.managed(sampled))
    }
    func geometry(_ pb: CVPixelBuffer,topURL: URL,frame: Int) async throws {
        guard frame>=2 && frame<4 else { return }
        let source = try await IBReference.read(AVURLAsset(url:topURL),frame:frame,format:IBContract.format)
        try IBContract.validate(source)
        CVPixelBufferLockBaseAddress(pb,.readOnly);CVPixelBufferLockBaseAddress(source,.readOnly)
        defer { CVPixelBufferUnlockBaseAddress(source,.readOnly);CVPixelBufferUnlockBaseAddress(pb,.readOnly) }
        let a = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pb,0)).assumingMemoryBound(to:UInt8.self)
        let b = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(source,0)).assumingMemoryBound(to:UInt8.self)
        let sa = CVPixelBufferGetBytesPerRowOfPlane(pb,0),sb = CVPixelBufferGetBytesPerRowOfPlane(source,0)
        var mismatches = 0,id = 0
        for y in 540..<h { for x in 960..<w { if a[y*sa+x] != b[(y-540)*sb+x-960] { mismatches += 1 } } }
        for bit in 0..<3 { if a[580*sa+1000+bit*48]>128 { id |= 1<<bit } }
        try note("frame\(frame)-geometry",["topYComparedPixels":960*540,"differentTopLumaPixels":mismatches,"visibleTopFrameID":id,"expectedID":frame])
        guard mismatches == 0,id == frame else { throw IBContract.error("top geometry/lane identity",code:200) }
    }
    func checkQuality(_ pb: CVPixelBuffer,dir: URL,frame: Int,png: CGImage,label: String) async throws {
        let refs = try await originalReferences(dir,frame:frame,png:png),actualImage = try IBReference.managed(pb)
        let actual = try IBReference.bytes(actualImage),cg = try IBReference.bytes(refs.0),sampled = try IBReference.bytes(refs.1)
        let sampledStats = try IBReference.stats(actual,sampled),cgStats = try IBReference.stats(actual,cg)
        var points: [[String:Any]] = []
        for (x,y) in [(100,200),(800,200),(1500,200),(959,800),(960,800),(1500,539),(1500,540),(1000,580),(1500,800)] {
            let k = (y*w+x)*4;points.append(["xy":[x,y],"actual":Array(actual[k..<k+4]),"CG":Array(cg[k..<k+4]),"sampled420":Array(sampled[k..<k+4])])
        }
        try note(label+"-frame\(frame)",["sampled420":sampledStats,"CG":cgStats,"points":points])
        if frame == 1 || (sampledStats["qualityPass"] as? Bool != true) || (cgStats["qualityPass"] as? Bool != true) {
            try IBReference.save(actualImage,to:root.appendingPathComponent(label+"-frame\(frame)-actual.png"))
            try IBReference.save(refs.0,to:root.appendingPathComponent(label+"-frame\(frame)-CG.png"))
            try IBReference.save(refs.1,to:root.appendingPathComponent(label+"-frame\(frame)-sampled420.png"))
        }
        guard sampledStats["qualityPass"] as? Bool == true,cgStats["qualityPass"] as? Bool == true else { throw IBContract.error("unchanged quality threshold failed at frame\(frame)",code:400) }
    }
    func status(_ error: Error) -> String {
        let e = error as NSError
        if e.domain == "IMG-B-POC-1" { return e.code == 200 ? "STRUCTURAL FAIL" : e.code == 400 ? "QUALITY FAIL" : e.code == 300 ? "BLOCKED" : "INCONCLUSIVE" }
        return "INCONCLUSIVE"
    }
    func testInterleavedReaderGate() async throws {
        var plan: Plan?
        do {
            try contract()
            let urls = inputs(root)
            let png: (CGImage,IBImage)
            if let previous = ProcessInfo.processInfo.environment["OTF_IMG_B_POC1_FIXTURES"] {
                let sourceURLs = inputs(URL(fileURLWithPath:previous))
                for (source,destination) in zip(sourceURLs,urls) { try FileManager.default.copyItem(at:source,to:destination) }
                guard try IBReference.digest(sourceURLs) == IBReference.digest(urls) else { throw IBContract.error("fixture copy changed",code:300) }
                png = try IBReference.loadPNG(urls[2])
                try note("fixtures-reused-byte-identically",["source":previous,"digest":try IBReference.digest(urls)])
            } else {
                try await IBReference.fixture(urls[0],top:false);try await IBReference.fixture(urls[1],top:true)
                png = try IBReference.createPNG(urls[2])
            }
            try note("fixtures-ready",["urls":urls.map(\.lastPathComponent),"sourceFrameCount":6,"sourceFramePTS":"0...5/30","duration":"6/30","PNGAlpha":[128,255]])
            let p = try await makePlan(root,png:png.1);plan = p
            let reader = try AVAssetReader(asset:p.asset),tracks = try await p.asset.loadTracks(withMediaType:.video)
            let output = AVAssetReaderVideoCompositionOutput(videoTracks:tracks,videoSettings:[kCVPixelBufferPixelFormatTypeKey as String:IBContract.format])
            output.videoComposition = p.custom;reader.add(output)
            guard reader.startReading() else { throw reader.error ?? IBContract.error("custom reader unsupported",code:300) }
            defer { reader.cancelReading() }
            var count = 0
            while let sample = output.copyNextSampleBuffer() {
                guard count<6,let pb = CMSampleBufferGetImageBuffer(sample) else { throw IBContract.error("missing/excess output",code:200) }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample),expected = CMTime(value:Int64(count),timescale:30)
                guard CMTimeCompare(pts,expected) == 0 else { throw IBContract.error("output PTS",code:200) }
                try IBContract.validate(pb)
                try note("frame\(count)-PTS",["actual":"\(pts.value)/\(pts.timescale)","requested":"\(count)/30","bufferAttachments":String(describing:CVBufferCopyAttachments(pb,.shouldPropagate)),"requests":p.log.snapshot])
                try await geometry(pb,topURL:urls[1],frame:count)
                try await checkQuality(pb,dir:root,frame:count,png:png.0,label:"reader")
                if count == 0 || count == 5 || count == 2 || count == 3 {
                    let nativePB = try await IBReference.read(p.asset,frame:count,vc:p.native,format:IBContract.format)
                    let native = try IBReference.bytes(IBReference.managed(nativePB)),candidate = try IBReference.bytes(IBReference.managed(pb))
                    let region: CGRect? = count == 2 || count == 3 ? CGRect(x:960,y:540,width:960,height:540) : nil
                    let stats = try IBReference.stats(candidate,native,region:region)
                    try note("frame\(count)-native-video-component",["region":region.map { String(describing:$0) } ?? "full frame, PNG inactive","stats":stats])
                    guard stats["qualityPass"] as? Bool == true else { throw IBContract.error("native component quality failure",code:400) }
                }
                count += 1
            }
            guard reader.status != .failed else { throw reader.error ?? IBContract.error("reader failed",code:300) }
            guard count == 6 else { throw IBContract.error("output count\(count)",code:200) }
            let marker: [String:Any] = ["gate1":"PASS","sourceDigest":try IBReference.digest(sourceFiles()),"fixtureDigest":try IBReference.digest(urls),
                "plan":"FHD30/6/bottom0:6/png1:5/top2:4/sourceIn0-at0/translation960,540/420v"]
            try JSONSerialization.data(withJSONObject:marker,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("gate1-pass.json"),options:.atomic)
            try note("gate1-decision",["status":"GATE1 PASS ONLY","count":count,"requests":p.log.snapshot,"gate2":"not yet run","peakObservedRSS":diagnostics.peakRSS])
        } catch {
            try? note("gate1-decision",["status":status(error),"error":String(describing:error),"requests":plan?.log.snapshot ?? [],"gate2":"NOT RUN"])
            throw error
        }
    }
    @MainActor func testPlayerAndShortExportGate() async throws {
        let source = base.appendingPathComponent("reader"),markerURL = source.appendingPathComponent("gate1-pass.json")
        guard let data = try? Data(contentsOf:markerURL),let marker = try JSONSerialization.jsonObject(with:data) as? [String:Any],marker["gate1"] as? String == "PASS" else { throw XCTSkip("Gate1 has not passed; Gate2 forbidden") }
        guard marker["sourceDigest"] as? String == (try IBReference.digest(sourceFiles())),marker["fixtureDigest"] as? String == (try IBReference.digest(inputs(source))) else { throw IBContract.error("verified source/fixture changed",code:300) }
        do {
            let png = try IBReference.loadPNG(inputs(source)[2]),plan = try await makePlan(source,png:png.1)
            let item = AVPlayerItem(asset:plan.asset);item.videoComposition = plan.custom
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:IBContract.format]);item.add(output)
            let player = AVPlayer(playerItem:item);player.isMuted = true;player.actionAtItemEnd = .pause
            defer { player.pause();item.remove(output);player.replaceCurrentItem(with:nil) }
            for _ in 0..<100 { if item.status != .unknown { break };try await Task.sleep(nanoseconds:50_000_000) }
            guard item.status == .readyToPlay else { throw item.error ?? IBContract.error("AVPlayer not ready",code:300) }
            let seekHelper = ImageCacheInvestigationTests()
            var rejected = 0
            for frame in 0..<6 {
                let time = CMTime(value:Int64(frame),timescale:30)
                guard await seekHelper.boundedSeek(player,time) else { throw IBContract.error("bounded seek failed",code:300) }
                var found: CVPixelBuffer?
                for _ in 0..<40 {
                    var actual = CMTime.invalid
                    if let pb = output.copyPixelBuffer(forItemTime:time,itemTimeForDisplay:&actual) {
                        if actual.isNumeric && CMTimeCompare(actual,time) == 0 { found = pb;break };rejected += 1
                    }
                    try await Task.sleep(nanoseconds:25_000_000)
                }
                guard let pb = found else { throw IBContract.error("no fresh AVPlayer frame\(frame)",code:300) }
                try await checkQuality(pb,dir:source,frame:frame,png:png.0,label:"AVPlayer")
            }
            try note("AVPlayer-six-seeks",["fresh":6,"staleRejected":rejected,"physicalDisplayVerified":false])
            guard await seekHelper.boundedSeek(player,.zero) else { throw IBContract.error("playback seek",code:300) }
            player.play();var displayFrames = Set<Int>()
            for _ in 0..<30 {
                let time = output.itemTime(forHostTime:CACurrentMediaTime());var shown = CMTime.invalid
                if let _ = output.copyPixelBuffer(forItemTime:time,itemTimeForDisplay:&shown),shown.isNumeric { displayFrames.insert(Int((shown.seconds*30).rounded())) }
                try await Task.sleep(nanoseconds:10_000_000)
            }
            player.pause();try note("short-playback",["observedFrames":displayFrames.sorted(),"physicalDisplayVerified":false])
            let out = root.appendingPathComponent("six-frames.mp4")
            let p = PlannedComposition(composition:plan.asset,videoComposition:plan.custom,durationFrames:6,settings:RenderSettings(),hasAudio:false,audioMix:nil,hasVideo:true,assets:plan.assets)
            let result = await ExportService.export(p,to:ExportDestination(url:out,confirmedReplace:false,identityAtConfirmation:nil),sources:[]) { _ in }
            guard result == .completed(out) else { throw IBContract.error("existing ExportService could not export: \(result)",code:300) }
            let asset = AVURLAsset(url:out),reader = try AVAssetReader(asset:asset),tracks = try await asset.loadTracks(withMediaType:.video)
            guard let track = tracks.first else { throw IBContract.error("export video track",code:200) }
            let duration = try await track.load(.timeRange).duration
            guard CMTimeCompare(duration,CMTime(value:6,timescale:30)) == 0 else { throw IBContract.error("export duration",code:200) }
            let decoded = AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:IBContract.format]);reader.add(decoded)
            guard reader.startReading() else { throw reader.error ?? IBContract.error("export decode",code:300) }
            defer { reader.cancelReading() };var count = 0
            while let sample = decoded.copyNextSampleBuffer() {
                guard count<6,CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample),CMTime(value:Int64(count),timescale:30)) == 0,
                      let pb = CMSampleBufferGetImageBuffer(sample) else { throw IBContract.error("export frame/PTS",code:200) }
                try await checkQuality(pb,dir:source,frame:count,png:png.0,label:"H264")
                count += 1
            }
            guard count == 6,reader.status != .failed else { throw IBContract.error("export count",code:200) }
            try note("gate2-decision",["status":"STRUCTURAL AND QUALITY PASS","frames":count,"duration":"6/30","exportCount":1,"requests":plan.log.snapshot,
                "cancellation":"generation/once-only implemented; cancellation races not exercised; no production cancellation claim"])
        } catch { try? note("gate2-decision",["status":status(error),"error":String(describing:error)]);throw error }
    }
}
