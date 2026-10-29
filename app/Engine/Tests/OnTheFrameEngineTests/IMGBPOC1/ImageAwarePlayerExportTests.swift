import XCTest
import AVFoundation
import CoreGraphics
import ImageIO
import QuartzCore
import CryptoKit
import VideoToolbox
import IOSurface

/// IMG-B-POC-2 harness only. Frozen compositor/reference/scheduler files are not changed.
final class ImageAwareGate2Tests: XCTestCase {
    var root: URL!,source: URL!,diagnostics: IBDiagnostics!,helper: ImageAware420GateTests!
    var playerStatus = "BLOCKED",exportStatus = "NOT RUN",exportAttempts = 0
    override func setUp() async throws {
        guard let run = ProcessInfo.processInfo.environment["OTF_IMG_B_POC2_RUN"],
              let fixture = ProcessInfo.processInfo.environment["OTF_IMG_B_POC2_SOURCE"] else { throw XCTSkip("IMG-B-POC-2 explicit opt-in") }
        let allowed = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("selftest-work").path+"/"
        let base = URL(fileURLWithPath:run).standardizedFileURL;source = URL(fileURLWithPath:fixture).standardizedFileURL
        guard base.path.hasPrefix(allowed),source.path.hasPrefix(allowed) else { throw IBContract.error("Gate2 paths outside disposable work",code:300) }
        root = base.appendingPathComponent("gate2")
        guard !FileManager.default.fileExists(atPath:root.path) else { throw IBContract.error("Gate2 fresh root required",code:300) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        diagnostics = IBDiagnostics(root:root);helper = ImageAware420GateTests();helper.root = root;helper.base = base;helper.diagnostics = diagnostics
    }
    func note(_ name: String,_ fields: [String:Any]) throws { try diagnostics.note(name,fields) }
    func time(_ t: CMTime) -> String { t.isNumeric ? "\(t.value)/\(t.timescale)" : "invalid-or-nonfinite-time" }
    func audit(_ plan: ImageAware420GateTests.Plan,_ label: String) throws {
        let rows = plan.log.snapshot
        var maxActive = 0,maxPending = 0,overflow = 0,cancels = 0
        for row in rows {
            guard let s = row["scheduler"] as? [String:Any] else { continue }
            maxActive = max(maxActive,s["maxActive"] as? Int ?? 0);maxPending = max(maxPending,s["maxPending"] as? Int ?? 0)
            overflow = max(overflow,s["overflowCount"] as? Int ?? 0)
            let events = s["events"] as? [[String:Any]] ?? []
            var terminalIDs = Set<UInt64>()
            for e in events {
                let name = e["event"] as? String ?? ""
                if ["success","failure","cancelled","pending-cancelled","pending-expired","overflow-failure"].contains(name),let id = e["id"] as? UInt64 {
                    guard terminalIDs.insert(id).inserted else { throw IBContract.error("duplicate scheduler terminal claim",code:200) }
                }
            }
        }
        cancels = rows.filter { ($0["event"] as? String ?? "").hasPrefix("cancelled") }.count
        try note(label,["maxActive":maxActive,"maxPending":maxPending,"overflow":overflow,"renderCancellationRows":cancels,
            "requests":rows,"auditScope":"each retained scheduler snapshot; IDs are scheduler-local, not global across AVFoundation instances"])
        guard maxActive<=2,maxPending<=4,overflow==0 else { throw IBContract.error("frozen scheduler budget failure",code:300) }
    }
    func edgeStats(_ actual: [UInt8],_ reference: [UInt8]) throws -> [String:Any] {
        var result: [String:Any] = [:]
        for (name,rect) in [("PNG-x640",CGRect(x:636,y:0,width:8,height:1080)),
            ("PNG-x1280",CGRect(x:1276,y:0,width:8,height:1080)),
            ("top-horizontal",CGRect(x:960,y:536,width:960,height:8)),
            ("prior-worst-crossing",CGRect(x:1276,y:536,width:8,height:8))] {
            result[name] = try IBReference.stats(actual,reference,region:rect)
        }
        return result
    }
    /// Diagnostic only, never substituted for the frozen quality reference.
    /// Preserve luma/chroma and neighboring chroma samples before assigning an RGB edge difference to a cause.
    func rawBoundary(_ pb: CVPixelBuffer) throws -> [String:Any] {
        try IBContract.validate(pb)
        var image: CGImage?
        let conversion = VTCreateCGImageFromCVPixelBuffer(pb,options:nil,imageOut:&image)
        let profile = image?.colorSpace?.copyICCData()
        let hash = profile.map { SHA256.hash(data:$0 as Data).map { String(format:"%02x",$0) }.joined() } ?? "none"
        CVPixelBufferLockBaseAddress(pb,.readOnly);defer { CVPixelBufferUnlockBaseAddress(pb,.readOnly) }
        let yplane = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pb,0)).assumingMemoryBound(to:UInt8.self)
        let chroma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pb,1)).assumingMemoryBound(to:UInt8.self)
        let ys = CVPixelBufferGetBytesPerRowOfPlane(pb,0),cs = CVPixelBufferGetBytesPerRowOfPlane(pb,1)
        var samples: [[String:Any]] = []
        for (x,y) in [(638,0),(639,0),(640,0),(1278,538),(1279,539),(1280,540),(960,540)] {
            let cy = y/2,cx = x/2,yy = Int(yplane[y*ys+x]),u = Int(chroma[cy*cs+cx*2]),v = Int(chroma[cy*cs+cx*2+1])
            var neighborhood: [[Int]] = []
            for dy in -1...1 { for dx in -1...1 {
                let xx = max(0,min(959,cx+dx)),zz = max(0,min(539,cy+dy))
                neighborhood.append([xx,zz,Int(chroma[zz*cs+xx*2]),Int(chroma[zz*cs+xx*2+1])])
            } }
            let l = Double(yy-16)*255/219,cb = Double(u-128)*255/224,cr = Double(v-128)*255/224
            let rgb709 = [l+1.5748*cr,l-0.187324*cb-0.468124*cr,l+1.8556*cb].map { UInt8(max(0,min(255,$0.rounded()))) }+[255]
            let tiny = try IBReference.image(rgb709,width:1,height:1,space:IBContract.profile())
            samples.append(["xy":[x,y],"YUV":[yy,u,v],"chromaNeighbors":neighborhood,
                "nearest709MatrixThenICC-sRGB":try IBReference.bytes(tiny)])
        }
        return ["format":CVPixelBufferGetPixelFormatType(pb),"VTStatus":conversion,"VTProfile":String(describing:image?.colorSpace),
            "VTProfileSHA256":hash,"VTBitsPerComponent":image?.bitsPerComponent ?? -1,
            "attachments":String(describing:CVBufferCopyAttachments(pb,.shouldPropagate)),"samples":samples,
            "interpretation":"nearest matrix samples are localization diagnostics, not an approved resampling reference or a replacement quality score"]
    }
    final class SeekResult: @unchecked Sendable {
        let lock = NSLock();var continuation: CheckedContinuation<Bool,Never>?
        init(_ continuation: CheckedContinuation<Bool,Never>) { self.continuation = continuation }
        func finish(_ result: Bool) { lock.lock();let c = continuation;continuation = nil;lock.unlock();c?.resume(returning:result) }
    }
    @MainActor func seek(_ player: AVPlayer,_ t: CMTime) async -> Bool {
        await withCheckedContinuation { continuation in
            let box = SeekResult(continuation)
            Task { try? await Task.sleep(nanoseconds:10_000_000_000);box.finish(false) }
            player.seek(to:t,toleranceBefore:.zero,toleranceAfter:.zero) { box.finish($0) }
        }
    }
    @MainActor func testFrozenPlayerThenOneExport() async throws {
        var currentPlan: ImageAware420GateTests.Plan?
        do {
            let markerData = try Data(contentsOf:source.appendingPathComponent("gate1-pass.json"))
            guard let marker = try JSONSerialization.jsonObject(with:markerData) as? [String:Any],marker["gate1"] as? String == "PASS" else { throw IBContract.error("Gate1 marker absent",code:300) }
            let sd = try IBReference.digest(helper.sourceFiles()),fd = try IBReference.digest(helper.inputs(source))
            guard marker["sourceDigest"] as? String == sd,marker["fixtureDigest"] as? String == fd else { throw IBContract.error("frozen source/fixture fingerprint changed",code:300) }
            let expectedPlan = "FHD30/6/bottom0:6/png1:5/top2:4/sourceIn0-at0/translation960,540/420v"
            guard marker["plan"] as? String == expectedPlan else { throw IBContract.error("frozen plan mismatch",code:300) }
            try note("frozen-preconditions",["sourceDigest":sd,"fixtureDigest":fd,"plan":expectedPlan,
                "contract":"unchanged Gate1 709/video-range/Left/ICC+encoded-sRGB/premultiplied128+255/reference sampling",
                "binaryRecheck":"one reader frame2, no full Gate1 rerun","priorBoundaryMaximum":102,
                "physicalDisplay":false,"ownerUI":false,"exportRoute":"direct experimental AVAssetExportSession; never production ExportService",
                "bounds":"120s whole test;ready10s;seek10s;fresh-buffer6s;two active+pending4;at most one0.2s export"])
            let png = try IBReference.loadPNG(helper.inputs(source)[2])
            let recheck = try await helper.makePlan(source,png:png.1)
            let readerPB = try await IBReference.read(recheck.asset,frame:2,vc:recheck.custom,format:IBContract.format)
            try IBContract.validate(readerPB)
            try await helper.geometry(readerPB,topURL:helper.inputs(source)[1],frame:2)
            try await helper.checkQuality(readerPB,dir:source,frame:2,png:png.0,label:"binary-recheck")
            let boundaryReference = try await helper.originalReferences(source,frame:2,png:png.0)
            let reference420 = try IBReference.sampled420(boundaryReference.0)
            try note("preencode-boundary-raw",["candidate":try rawBoundary(readerPB),"independentSampledReference":try rawBoundary(reference420),
                "priorWorstXY":[1279,539],"priorMaximum":102])
            try audit(recheck,"binary-recheck-scheduler")
            try note("binary-recheck-pass",["frame":2,"PTS":"2/30","rendererAndReferenceUnchanged":true])

            let plan = try await helper.makePlan(source,png:png.1);currentPlan = plan
            let item = AVPlayerItem(asset:plan.asset);item.videoComposition = plan.custom
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:IBContract.format]);item.add(output)
            let player = AVPlayer(playerItem:item);player.isMuted = true;player.actionAtItemEnd = .pause
            defer { player.pause();item.cancelPendingSeeks();item.remove(output);player.replaceCurrentItem(with:nil) }
            let readyStart = Date()
            while item.status == .unknown && Date().timeIntervalSince(readyStart)<10 { try await Task.sleep(nanoseconds:25_000_000) }
            try note("player-ready",["status":item.status.rawValue,"error":String(describing:item.error),"seconds":Date().timeIntervalSince(readyStart)])
            guard item.status == .readyToPlay else { throw IBContract.error("AVPlayer ready timeout/error",code:300) }
            var returnedFrames = Set<Int>(),pixelFingerprints = Set<String>(),staleCount = 0
            // Non-monotonic seeks explicitly exercise stale and after-seek reuse protection.
            for frame in [0,5,1,4,2,3] {
                let requested = CMTime(value:Int64(frame),timescale:30),start = Date()
                try note("seek-start",["frame":frame,"requested":time(requested)])
                let completed = await seek(player,requested)
                try note("seek-completion",["frame":frame,"completed":completed,"seconds":Date().timeIntervalSince(start)])
                guard completed else { item.cancelPendingSeeks();throw IBContract.error("AVPlayer seek frame\(frame) did not finish in10s",code:300) }
                var pb: CVPixelBuffer?,display = CMTime.invalid,observations: [String] = []
                let deadline = Date().addingTimeInterval(6)
                while Date()<deadline {
                    var actual = CMTime.invalid
                    if let candidate = output.copyPixelBuffer(forItemTime:requested,itemTimeForDisplay:&actual) {
                        observations.append(time(actual))
                        if actual.isNumeric && CMTimeCompare(actual,requested)==0 { pb = candidate;display = actual;break }
                        staleCount += 1
                    }
                    if item.status == .failed { break }
                    try await Task.sleep(nanoseconds:25_000_000)
                }
                try note("seek-buffer",["frame":frame,"requested":time(requested),"acceptedDisplay":time(display),
                    "returnedDisplayObservations":observations,"seconds":Date().timeIntervalSince(start),"fresh":pb != nil])
                guard let pb else { throw IBContract.error("no fresh AVPlayer frame\(frame) within6s after seek; \(String(describing:item.error))",code:300) }
                try IBContract.validate(pb)
                try await helper.geometry(pb,topURL:helper.inputs(source)[1],frame:frame)
                try await helper.checkQuality(pb,dir:source,frame:frame,png:png.0,label:"AVPlayer")
                let actualImage = try IBReference.managed(pb),pixels = try IBReference.bytes(actualImage)
                let fingerprint = SHA256.hash(data:Data(pixels)).map { String(format:"%02x",$0) }.joined()
                guard pixelFingerprints.insert(fingerprint).inserted else { throw IBContract.error("identical content reused across distinct fixture frames",code:200) }
                returnedFrames.insert(frame)
                try IBReference.save(actualImage,to:root.appendingPathComponent("preencode-frame\(frame).png"))
                let refs = try await helper.originalReferences(source,frame:frame,png:png.0)
                try note("AVPlayer-frame\(frame)-edge-localization",["pixelSHA256":fingerprint,
                    "CGRegions":try edgeStats(pixels,IBReference.bytes(refs.0)),"sampled420Regions":try edgeStats(pixels,IBReference.bytes(refs.1))])
            }
            guard returnedFrames == Set(0..<6) else { throw IBContract.error("AVPlayer missing requested frame",code:200) }
            try audit(plan,"player-six-frame-scheduler")
            playerStatus = "PASS"
            try note("AVPlayer-decision",["status":playerStatus,"requestedSequence":[0,5,1,4,2,3],"freshFrames":returnedFrames.sorted(),
                "staleRejected":staleCount,"distinctPixelFingerprints":pixelFingerprints.count,
                "scope":"AVPlayer API-buffer delivery and frozen numerical/structural gate; no physical presentation/owner UI/sustained30fps claim"])

            guard await seek(player,.zero) else { throw IBContract.error("optional playback preparation timed out",code:300) }
            player.play();var playback: [String] = []
            for _ in 0..<40 {
                let t = output.itemTime(forHostTime:CACurrentMediaTime());var actual = CMTime.invalid
                if let _ = output.copyPixelBuffer(forItemTime:t,itemTimeForDisplay:&actual) { playback.append(time(actual)) }
                try await Task.sleep(nanoseconds:10_000_000)
            }
            player.pause();try note("brief-playback-observation",["displayTimes":playback,"smoothnessClaim":false])
            item.cancelPendingSeeks();item.remove(output);player.replaceCurrentItem(with:nil)
            let settle = Date().addingTimeInterval(6)
            while Date()<settle {
                let snapshots = plan.log.snapshot.compactMap { $0["scheduler"] as? [String:Any] }
                if let last = snapshots.last,last["active"] as? Int == 0,last["pending"] as? Int == 0 { break }
                try await Task.sleep(nanoseconds:25_000_000)
            }
            try audit(plan,"player-after-detach")
            try await isolatedExport(plan,png:png.0)
        } catch {
            if playerStatus != "PASS" { playerStatus = (error as NSError).domain == "IMG-B-POC-1" && [200,400].contains((error as NSError).code) ? "FAIL" : "BLOCKED" }
            if exportAttempts>0 && exportStatus == "NOT RUN" { exportStatus = "BLOCKED" }
            try? note("gate2-decision",["AVPLAYER":playerStatus,"EXPORT":exportStatus,"exportAttempts":exportAttempts,
                "error":String(describing:error),"requests":currentPlan?.log.snapshot ?? [],"partialResultsAreNotValidatedOutputs":true])
            throw error
        }
    }
    func isolatedExport(_ plan: ImageAware420GateTests.Plan,png: CGImage) async throws {
        let url = root.appendingPathComponent("six-frames.unvalidated.mp4")
        guard exportAttempts == 0,!FileManager.default.fileExists(atPath:url.path),
              let session = AVAssetExportSession(asset:plan.asset,presetName:AVAssetExportPreset1920x1080) else { throw IBContract.error("isolated export unavailable/existing output",code:300) }
        session.videoComposition = plan.custom;session.timeRange = CMTimeRange(start:.zero,duration:CMTime(value:6,timescale:30))
        exportAttempts = 1
        try note("export-attempt",["count":exportAttempts,"path":url.path,"duration":"6/30","productionExportServiceInvoked":false,
            "promotion":"unvalidated name retained until separate quality decision"])
        let started = Date()
        try await session.export(to:url,as:.mp4)
        try note("export-session-completed",["seconds":Date().timeIntervalSince(started),"sessionStatus":session.status.rawValue,
            "bytes":try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? -1])
        let asset = AVURLAsset(url:url),tracks = try await asset.loadTracks(withMediaType:.video)
        guard let track = tracks.first else { exportStatus = "STRUCTURAL FAIL";throw IBContract.error("export has no video",code:200) }
        let range = try await track.load(.timeRange),containerDuration = try await asset.load(.duration),descriptions = try await track.load(.formatDescriptions)
        let codec = descriptions.first.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
        let expectedCodec = UInt32(0x61766331) // avc1
        try note("export-format",["codecFourCC":codec,"expectedH264avc1":expectedCodec,"trackStart":time(range.start),"trackDuration":time(range.duration),
            "containerDuration":time(containerDuration),"formatDescriptions":descriptions.map { String(describing:$0) }])
        guard codec == expectedCodec,CMTimeCompare(range.duration,CMTime(value:6,timescale:30)) == 0 else { exportStatus = "STRUCTURAL FAIL";throw IBContract.error("export format/duration",code:200) }
        let reader = try AVAssetReader(asset:asset),output = AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:IBContract.format]);reader.add(output)
        guard reader.startReading() else { throw reader.error ?? IBContract.error("export independent decode",code:300) }
        defer { reader.cancelReading() }
        var count = 0,numericPass = true,maxBoundary = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue } // Count presentation images only.
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            guard count<6,CMTimeCompare(pts,CMTime(value:Int64(count),timescale:30)) == 0 else { exportStatus = "STRUCTURAL FAIL";throw IBContract.error("export decoded PTS/count",code:200) }
            try IBContract.validate(pb)
            let actualImage = try IBReference.managed(pb),actual = try IBReference.bytes(actualImage)
            let refs = try await helper.originalReferences(source,frame:count,png:png)
            let cg = try IBReference.bytes(refs.0),sampled = try IBReference.bytes(refs.1)
            let statsCG = try IBReference.stats(actual,cg),stats420 = try IBReference.stats(actual,sampled)
            if count == 2 {
                let reference420 = try IBReference.sampled420(refs.0)
                try note("postencode-boundary-raw",["decoded":try rawBoundary(pb),"independentSampledReference":try rawBoundary(reference420)])
            }
            numericPass = numericPass && statsCG["qualityPass"] as? Bool == true && stats420["qualityPass"] as? Bool == true
            maxBoundary = max(maxBoundary,statsCG["edgeMaximum"] as? Int ?? 0)
            let preURL = root.appendingPathComponent("preencode-frame\(count).png")
            guard let imageSource = CGImageSourceCreateWithURL(preURL as CFURL,nil),let pre = CGImageSourceCreateImageAtIndex(imageSource,0,nil) else { throw IBContract.error("preencode sample evidence absent",code:300) }
            let preBytes = try IBReference.bytes(pre)
            var nativeComparison: [String:Any] = ["applicable":false]
            if [0,2,3,5].contains(count) {
                let nativePB = try await IBReference.read(plan.asset,frame:count,vc:plan.native,format:IBContract.format)
                let native = try IBReference.bytes(IBReference.managed(nativePB))
                let roi: CGRect? = count==2 || count==3 ? CGRect(x:960,y:540,width:960,height:540) : nil
                nativeComparison = ["applicable":true,"stats":try IBReference.stats(actual,native,region:roi)]
            }
            try note("export-frame\(count)",["PTS":time(pts),"sampled420":stats420,"CG":statsCG,
                "postVsPreencode":try IBReference.stats(actual,preBytes),"CGEdgeRegions":try edgeStats(actual,cg),
                "postVsPreencodeEdges":try edgeStats(actual,preBytes),"nativeVideoComponent":nativeComparison,
                "colorAttachments":String(describing:CVBufferCopyAttachments(pb,.shouldPropagate))])
            try IBReference.save(actualImage,to:root.appendingPathComponent("decoded-frame\(count).png"))
            count += 1
        }
        guard count == 6,reader.status != .failed else { exportStatus = "STRUCTURAL FAIL";throw IBContract.error("export presentation count\(count)",code:200) }
        try audit(plan,"export-scheduler")
        // Mechanical results only: the known large unexplained boundary error needs explicit review,
        // not an invented edge tolerance or an automatic PASS from the global score.
        exportStatus = numericPass ? "INCONCLUSIVE" : "QUALITY FAIL"
        try note("gate2-decision",["AVPLAYER":playerStatus,"EXPORT":exportStatus,"exportAttempts":exportAttempts,"decodedFrames":count,
            "numericGatePass":numericPass,"maximumBoundaryCG":maxBoundary,"priorBoundaryMaximum":102,
            "trackDuration":time(range.duration),"containerDuration":time(containerDuration),"output":url.path,
            "qualityReview":"pre/post localization is recorded; no causal explanation of the existing large boundary discrepancy has been established; no validated-output promotion",
            "productionIntegration":false,"physicalDisplay":false,"ownerUI":false])
    }
    /// One existing decoded frame, one byte-identical clone. No rendering or export retry.
    func testReadOnlyDecodedBoundaryClone() async throws {
        guard let path = ProcessInfo.processInfo.environment["OTF_IMG_B_POC2_REVIEW_FILE"] else { throw XCTSkip("existing output review only") }
        let url = URL(fileURLWithPath:path).standardizedFileURL
        guard url.path.hasPrefix(source.deletingLastPathComponent().deletingLastPathComponent().path+"/") else { throw IBContract.error("review file outside disposable workspace",code:300) }
        let before = try IBReference.digest([url])
        let original = try await IBReference.read(AVURLAsset(url:url),frame:2,format:IBContract.format)
        try IBContract.validate(original)
        var clone: CVPixelBuffer?
        guard CVPixelBufferCreate(nil,IBContract.w,IBContract.h,IBContract.format,nil,&clone) == kCVReturnSuccess,let clone else { throw IBContract.error("diagnostic clone allocation",code:300) }
        do {
            CVPixelBufferLockBaseAddress(original,.readOnly);CVPixelBufferLockBaseAddress(clone,[])
            defer { CVPixelBufferUnlockBaseAddress(clone,[]);CVPixelBufferUnlockBaseAddress(original,.readOnly) }
            for plane in 0..<2 {
                guard let src = CVPixelBufferGetBaseAddressOfPlane(original,plane),let dst = CVPixelBufferGetBaseAddressOfPlane(clone,plane) else { throw IBContract.error("diagnostic clone planes",code:300) }
                let rows = CVPixelBufferGetHeightOfPlane(original,plane),bytes = CVPixelBufferGetWidthOfPlane(original,plane)*(plane == 0 ? 1 : 2)
                let ss = CVPixelBufferGetBytesPerRowOfPlane(original,plane),ds = CVPixelBufferGetBytesPerRowOfPlane(clone,plane)
                for row in 0..<rows { memcpy(dst+row*ds,src+row*ss,bytes) }
            }
        }
        // Exact metadata propagation is intentional for this equal-input diagnostic, not a renderer policy.
        CVBufferPropagateAttachments(original,clone)
        func activeData(_ pb: CVPixelBuffer) throws -> Data {
            CVPixelBufferLockBaseAddress(pb,.readOnly);defer { CVPixelBufferUnlockBaseAddress(pb,.readOnly) }
            var result = Data()
            for plane in 0..<2 {
                let p = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pb,plane)).assumingMemoryBound(to:UInt8.self)
                let rows = CVPixelBufferGetHeightOfPlane(pb,plane),stride = CVPixelBufferGetBytesPerRowOfPlane(pb,plane)
                let bytes = CVPixelBufferGetWidthOfPlane(pb,plane)*(plane == 0 ? 1 : 2)
                for row in 0..<rows { result.append(p+row*stride,count:bytes) }
            }
            return result
        }
        let a = try activeData(original),b = try activeData(clone)
        guard a == b else { throw IBContract.error("clone not byte-identical",code:200) }
        let originalImage = try IBReference.managed(original),cloneImage = try IBReference.managed(clone)
        let oa = try IBReference.bytes(originalImage),ob = try IBReference.bytes(cloneImage)
        let rawA = try rawBoundary(original),rawB = try rawBoundary(clone)
        try IBReference.save(originalImage,to:root.appendingPathComponent("original-decoded-frame2.png"))
        try IBReference.save(cloneImage,to:root.appendingPathComponent("same-bytes-clone-frame2.png"))
        try a.write(to:root.appendingPathComponent("original-active-420v.bin"));try b.write(to:root.appendingPathComponent("clone-active-420v.bin"))
        guard try IBReference.digest([url]) == before else { throw IBContract.error("existing export changed",code:200) }
        let k = (539*IBContract.w+1279)*4
        let worstPoint: [String:Any] = ["xy":[1279,539],"originalRGB":Array(oa[k..<k+4]),"cloneRGB":Array(ob[k..<k+4])]
        try note("read-only-boundary-clone",["existingFile":url.path,"existingFileSHA256":before,"frame":2,"PTS":"2/30",
            "activeBytes":a.count,"activeByteDifferences":0,"activeSHA256":SHA256.hash(data:a).map { String(format:"%02x",$0) }.joined(),
            "originalIOSurface":CVPixelBufferGetIOSurface(original) != nil,"cloneIOSurface":CVPixelBufferGetIOSurface(clone) != nil,
            "originalRaw":rawA,"cloneRaw":rawB,"RGBDifference":try IBReference.stats(oa,ob),"edgeRegions":try edgeStats(oa,ob),
            "atPriorWorst":worstPoint,
            "exportsInThisReview":0,"frozenReferenceReplaced":false,
            "scope":"tests buffer-representation dependence of the unchanged VT+ICC inspection path; does not reclassify the original frozen-reference export failure"])
    }
}
