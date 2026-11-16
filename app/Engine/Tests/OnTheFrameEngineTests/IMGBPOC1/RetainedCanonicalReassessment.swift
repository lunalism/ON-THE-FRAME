import XCTest
import AVFoundation
import CoreGraphics

extension CanonicalNV12QATests {
    func testRetainedFrame0() async throws { try await reassess(0) }
    func testRetainedFrame1() async throws { try await reassess(1) }
    func testRetainedFrame2() async throws { try await reassess(2) }
    func testRetainedFrame3() async throws { try await reassess(3) }
    func testRetainedFrame4() async throws { try await reassess(4) }
    func testRetainedFrame5() async throws { try await reassess(5) }
    func retainedPaths() throws -> (URL,URL) {
        guard let p=ProcessInfo.processInfo.environment["OTF_IMG_B_QA02_MP4"],let f=ProcessInfo.processInfo.environment["OTF_IMG_B_QA02_FIXTURES"] else { throw IBContract.error("QA02 retained paths required",code:300) }
        return (URL(fileURLWithPath:p),URL(fileURLWithPath:f))
    }
    func frameID(_ pixels:[UInt8],ox:Int=0,oy:Int=0)->Int {
        var id=0
        for bit in 0..<3 { if pixels[((oy+40)*1920+ox+40+48*bit)*4+1]>128 { id |= 1<<bit } }
        return id
    }
    /// Scalar encoded-sRGB premultiplied source-over, independent of CGContext blending.
    /// Same opaque video coverage and integer translation as the frozen reference.
    func blendOracle(_ bottom:[UInt8],_ top:[UInt8]?,_ png:[UInt8],_ frame:Int)->[UInt8] {
        var result=bottom
        if frame>=1 && frame<5 {
            for k in stride(from:0,to:result.count,by:4) {
                let alpha=Int(png[k+3])
                for c in 0..<3 { result[k+c]=UInt8(min(255,Int(png[k+c])+(Int(bottom[k+c])*(255-alpha)+127)/255)) }
                result[k+3]=255
            }
        }
        if let top {
            for y in 540..<1080 { for x in 960..<1920 {
                let d=(y*1920+x)*4,s=((y-540)*1920+x-960)*4
                for c in 0..<4 { result[d+c]=top[s+c] }
            } }
        }
        return result
    }
    func edgeOnly(_ actual:[UInt8],_ reference:[UInt8])->[String:Any] {
        // Unchanged legacy edge predicate; union mask excludes flat interiors.
        var count=0,sum=0.0,maximum=0,hist=[Int](repeating:0,count:256),worst=[0,0,0]
        for y in 0..<1080 { for x in 0..<1920 {
            guard abs(x-640)<=3 || abs(x-1280)<=3 || abs(x-960)<=3 || abs(y-540)<=3 else { continue }
            count+=1;let k=(y*1920+x)*4
            for c in 0..<3 { let d=abs(Int(actual[k+c])-Int(reference[k+c]));sum+=Double(d*d);hist[d]+=1;if d>maximum {maximum=d;worst=[x,y,c]} }
        } }
        var total=0,p99=0
        for i in 0..<256 {total+=hist[i];if total>=count*3*99/100 {p99=i;break}}
        return ["mask":"abs(x-640/1280/960)<=3 or abs(y-540)<=3, legacy union","pixels":count,"maximum":maximum,"p99":p99,"worstXYC":worst,"psnr":sum==0 ? 999:10*log10(65025/(sum/Double(count*3)))]
    }
    func timing(_ url:URL) async throws {
        let asset=AVURLAsset(url:url),tracks=try await asset.loadTracks(withMediaType:.video)
        let track=try XCTUnwrap(tracks.first),range=try await track.load(.timeRange),duration=try await asset.load(.duration),transform=try await track.load(.preferredTransform)
        guard range.start.isNumeric,range.duration.isNumeric,duration.isNumeric,CMTimeCompare(range.start,.zero)==0,
              CMTimeCompare(range.duration,CMTime(value:6,timescale:30))==0,CMTimeCompare(duration,CMTime(value:6,timescale:30))==0,transform == .identity else { throw IBContract.error("QA02 invalid timing/transform",code:200) }
        let reader=try AVAssetReader(asset:asset),o=AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:IBContract.format]);reader.add(o)
        guard reader.startReading() else {throw reader.error ?? IBContract.error("QA02 timing reader")}
        var times=[String](),i=0
        while let s=o.copyNextSampleBuffer() {
            guard CMSampleBufferGetImageBuffer(s) != nil else {continue}
            let t=CMSampleBufferGetPresentationTimeStamp(s)
            guard i<6,t.isNumeric,CMTimeCompare(t,CMTime(value:Int64(i),timescale:30))==0 else {reader.cancelReading();throw IBContract.error("QA02 frame count/PTS",code:200)}
            times.append("\(t.value)/\(t.timescale)");i+=1
        }
        guard reader.status == .completed,i==6 else {throw reader.error ?? IBContract.error("QA02 missing presentation frames",code:200)}
        try note("retained-timing",["presentationFrames":i,"PTS":times,"trackDuration":"\(range.duration.value)/\(range.duration.timescale)","containerDuration":"\(duration.value)/\(duration.timescale)","preferredTransform":"identity"])
    }
    func reassess(_ frame:Int) async throws {
        try contract()
        let (mp4,dir)=try retainedPaths(),inputs=["bottom.mov","top.mov","middle.png"].map{dir.appendingPathComponent($0)}
        let mp4SHA=QA01.sha(try Data(contentsOf:mp4)),fixtureDigest=try IBReference.digest(inputs)
        guard mp4SHA=="c7781efd86c905b80ed60909bca4df0cae364c0eca85ff580b25a219e93acdf5",fixtureDigest=="26bac46cb85992b6e7140cb36cc8f8905c9b700590369af272a506c766db04d1" else {throw IBContract.error("QA02 retained evidence digest mismatch",code:200)}
        if frame==0 {try await timing(mp4)}
        let actualPB=try await IBReference.read(AVURLAsset(url:mp4),frame:frame,format:IBContract.format)
        try note("retained-input",["frame":frame,"path":mp4.path,"MP4SHA256":mp4SHA,"fixtureDigest":fixtureDigest,"actual":try QA01.metadata(actualPB,allocation:"read-only retained decode"),"version":IBCanonicalNV12.version])
        let bottomPB=try await IBReference.read(AVURLAsset(url:inputs[0]),frame:frame)
        let bottom=try IBReference.managed(bottomPB),bottomBytes=try IBReference.bytes(bottom)
        let png=try IBReference.loadPNG(inputs[2]),pngBytes=try IBReference.bytes(png.0)
        var top:CGImage?,topBytes:[UInt8]?
        if frame>=2 && frame<4 {
            let topPB=try await IBReference.read(AVURLAsset(url:inputs[1]),frame:frame)
            top=try IBReference.managed(topPB);topBytes=try IBReference.bytes(XCTUnwrap(top))
        }
        // Original independent source-over and output downsampling are deliberately unchanged.
        let referenceCG=try IBReference.composite(bottom:bottom,top:top,png:png.0,frame:frame),cgBytes=try IBReference.bytes(referenceCG)
        let oracle=blendOracle(bottomBytes,topBytes,pngBytes,frame),blendStats=try IBReference.stats(cgBytes,oracle)
        guard (blendStats["maximum"] as? Int ?? 999)<=1 else {throw IBContract.error("QA02 independent blend reference mismatch",code:200)}
        let referencePB=try IBReference.sampled420(referenceCG)
        let actual=try IBReference.bytes(IBReference.managed(actualPB)),reference=try IBReference.bytes(IBReference.managed(referencePB))
        let stats=try IBReference.stats(actual,reference),auxiliary=try IBReference.stats(actual,cgBytes)
        let bottomID=frameID(actual),sourceBottomID=frameID(bottomBytes),visibleTopID=topBytes==nil ? -1:frameID(actual,ox:960,oy:540)
        guard sourceBottomID==frame,bottomID==frame,(topBytes==nil || (frameID(topBytes!)==frame && visibleTopID==frame)) else {throw IBContract.error("QA02 source frame/layer marker",code:200)}
        var points=[[String:Any]]()
        for (x,y) in [(100,200),(800,200),(1500,200),(959,800),(960,800),(1500,539),(1500,540),(1000,580),(1500,800),(1279,539)] {
            let k=(y*1920+x)*4
            points.append(["xy":[x,y],"actual":Array(actual[k..<k+4]),"canonicalSampledReference":Array(reference[k..<k+4]),"CGReference":Array(cgBytes[k..<k+4])])
        }
        var regions=[String:Any]()
        for (name,r) in [("PNG-x640",CGRect(x:636,y:0,width:8,height:1080)),("PNG-x1280",CGRect(x:1276,y:0,width:8,height:1080)),("top-x960",CGRect(x:956,y:540,width:8,height:540)),("top-horizontal",CGRect(x:960,y:536,width:960,height:8)),("prior-worst",CGRect(x:1276,y:536,width:8,height:8))] {
            regions[name]=try QA01.stats(actual,reference,width:1920,height:1080,region:r)
        }
        var topGeometry:[String:Any]=["visible":false]
        if topBytes != nil {
            // Lossy output: report discrepancies across all expected top luma positions, do not demand byte parity.
            let source=try await IBReference.read(AVURLAsset(url:inputs[1]),frame:frame,format:IBContract.format),a=try IBCanonicalNV12.Planes(actualPB),b=try IBCanonicalNV12.Planes(source)
            var maxY=0,changed=0
            for y in 540..<1080 {for x in 960..<1920 {let d=abs(Int(a.y[y*1920+x])-Int(b.y[(y-540)*1920+x-960]));maxY=max(maxY,d);if d>0 {changed+=1}}}
            topGeometry=["visible":true,"expectedRectangle":[960,540,960,540],"comparedLumaPixels":518400,"differentLumaPixels":changed,"maximumYDifference":maxY,"translatedMarkerID":visibleTopID,"lossyGeometryScope":"expected ROI and markers; not bit-identical edge coverage proof"]
        }
        try note("frame\(frame)-canonical-results",["frame":frame,"PTS":"\(frame)/30","primaryCanonicalSampled420":stats,"auxiliaryDirectCG-notEquivalentToSampled420":auxiliary,
            "edgeOnly":edgeOnly(actual,reference),"chromaRegions":regions,"points":points,"independentBlendCG-vs-scalar":blendStats,
            "sourceIDs":["bottom":bottomID,"bottomDecodedSource":sourceBottomID,"visibleTop":visibleTopID],"topGeometry":topGeometry,
            "numericQualityPass":stats["qualityPass"] ?? false,"historicalVerdict":"QUALITY FAIL preserved","referenceScope":"frozen BGRA source decode+ICC, unchanged CG encoded-sRGB source-over and scalar420 sampling; both actual/reference420 converted by canonical-v1",
            "structuralScope":"six PTS/duration checked once; source markers, expected layer probes/ROI checked per frame; original pre-encode exact geometry evidence preserved",
            "newExports":0,"AVPlayerRuns":0])
        try IBReference.save(IBReference.image(actual),to:root.appendingPathComponent("canonical-v1-frame\(frame)-actual.png"))
        try IBReference.save(IBReference.image(reference),to:root.appendingPathComponent("canonical-v1-frame\(frame)-reference.png"))
        guard QA01.sha(try Data(contentsOf:mp4))==mp4SHA,try IBReference.digest(inputs)==fixtureDigest else {throw IBContract.error("QA02 evidence mutated",code:200)}
        try note("frame-complete",["frame":frame,"qualityPass":stats["qualityPass"] ?? false,"meaning":"successful measurement collection is not a quality PASS; aggregate verdict is separate"])
    }
}
