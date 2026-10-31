import XCTest
import AVFoundation
import OTFDevSupport
@testable import OnTheFrameEngine

/// Opt-in, generated inputs only. Keeps outputs/metrics for checkpoint review.
final class GatedImageExportTests: XCTestCase {
    var root: URL!
    override func setUp() async throws {
        guard let path=ProcessInfo.processInfo.environment["OTF_IMAGE_EXPORT_RUN"] else {throw XCTSkip("explicit disposable image export opt-in")}
        root=URL(fileURLWithPath:path).appendingPathComponent(name.components(separatedBy:" ").last!.replacingOccurrences(of:"]",with:""))
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    }
    struct Setup {var t:Timeline;var media:[UUID:MediaAsset];var urls:[UUID:URL]}
    func setup(_ mixed:Bool=false,n:Int=150) async throws -> Setup {
        var t=Timeline(),media=[UUID:MediaAsset](),urls=[UUID:URL]()
        if mixed {
            let path=try XCTUnwrap(ProcessInfo.processInfo.environment["OTF_EXPORT_FIXTURES"])
            let v=try await MediaProbe.inspect(URL(fileURLWithPath:path).appendingPathComponent("otf-A.mp4"));media[v.id]=v
            t=t.registering(v).rebuilt(video:[Clip(mediaID:v.id,start:0,sourceIn:0,length:min(n,120),lane:Lane.videoID)],duration:n)
        }
        let b=UUID(),a=UUID(),j=UUID(),upper=UUID(),highest=UUID()
        let blue=try ProductImagePreviewTests.solid(root,name:"blue.png",color:[0,0,255,255])
        let alpha=try ProductImagePreviewTests.solid(root,name:"alpha.png",color:[128,0,0,128])
        let jpeg=try ProductImagePreviewTests.solid(root,name:"oriented.jpg",color:[200,0,0,255],orientation:6)
        if !mixed {t=try t.registeringImage(await StillImageProjectModel.ValidatedImage.inspect(blue),id:b).placingImage(media:b,at:0,lane:Lane.videoID,length:n);urls[b]=blue}
        t=try t.addingLane(.video,name:"alpha",id:upper,outward:true).registeringImage(await StillImageProjectModel.ValidatedImage.inspect(alpha),id:a).placingImage(media:a,at:1,lane:upper,length:n-2)
        let clip=t.clips.first{$0.mediaID==a}!
        t=t.rebuilt(video:t.clips.map{$0.id==clip.id ? $0.with(transform:.some(.init(scale:0.5,x:120,y:40))):$0})
        t=try t.splitting(clip:clip.id,atFrame:n/2)
        t=try t.addingLane(.video,name:"portrait",id:highest,outward:true).registeringImage(await StillImageProjectModel.ValidatedImage.inspect(jpeg),id:j).placingImage(media:j,at:2,lane:highest,length:min(12,n-2))
        urls[a]=alpha;urls[j]=jpeg
        XCTAssertTrue(t.isValid);XCTAssertTrue(t.stillImageIDs.allSatisfy{t.mediaFrames[$0]==nil})
        return Setup(t:t,media:media,urls:urls)
    }
    final class Log:@unchecked Sendable {
        let lock=NSLock();var progress=[Double](),temp:URL?,task:Task<ExportOutcome,Never>?
        func add(_ v:Double){lock.withLock{progress.append(v)}}
    }
    func export(_ s:Setup,_ file:String,options:ExportService.Options = .init(),enabled:Bool=true)async -> (ExportOutcome,URL,Log) {
        let dest=root.appendingPathComponent(file),log=Log()
        let result=await ExportService.exportImages(s.t,media:s.media,enabled:enabled,resolvedImages:s.urls,to:.fromSavePanel(dest),options:options){log.add($0)}
        return(result,dest,log)
    }
    func reader(_ asset:AVAsset,_ plan:PlannedComposition?=nil)async throws -> (AVAssetReader,AVAssetReaderOutput) {
        let r=try AVAssetReader(asset:asset),tracks=try await asset.loadTracks(withMediaType:.video)
        let settings:[String:Any]=[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        let o:AVAssetReaderOutput
        if let plan {let v=AVAssetReaderVideoCompositionOutput(videoTracks:tracks,videoSettings:settings);v.videoComposition=plan.videoComposition;o=v}
        else {o=AVAssetReaderTrackOutput(track:try XCTUnwrap(tracks.first),outputSettings:settings)}
        r.add(o);XCTAssertTrue(r.startReading());return(r,o)
    }
    /// Compare EVERY decoded MP4 frame to the shared preview composition, streaming.
    /// H.264 is lossy: retain sampled plane PSNR/max error, not a raw-hash equivalence claim.
    func inspect(_ s:Setup,_ url:URL,subtitle:Bool=false)async throws {
        let asset=AVURLAsset(url:url);let tracks=try await asset.loadTracks(withMediaType:.video);let video=try XCTUnwrap(tracks.first)
        let size=try await video.load(.naturalSize),rate=try await video.load(.nominalFrameRate),range=try await video.load(.timeRange),formats=try await video.load(.formatDescriptions)
        XCTAssertEqual(size,CGSize(width:1920,height:1080));XCTAssertEqual(rate,30,accuracy:0.01)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(try XCTUnwrap(formats.first)),kCMVideoCodecType_H264)
        XCTAssertEqual(CMTimeCompare(range.start,.zero),0);XCTAssertEqual(CMTimeCompare(range.duration,CMTime(value:Int64(s.t.durationFrames),timescale:30)),0)
        let p=try await InternalImagePreview.plan(s.t,media:s.media,enabled:true,resolvedImages:s.urls)
        let (rr,ro)=try await reader(p.composition,p), (er,eo)=try await reader(asset)
        defer{rr.cancelReading();er.cancelReading()}
        let footprints=FootprintWindow(p.subtitles)
        var rows=[[String:Any]](),k=0
        while let sample=eo.copyNextSampleBuffer() {
            let t=CMTime(value:Int64(k),timescale:30)
            XCTAssertEqual(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample),t),0,"MP4 PTS \(k)")
            let refSample=try XCTUnwrap(ro.copyNextSampleBuffer());XCTAssertEqual(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(refSample),t),0)
            let ref=try XCTUnwrap(CMSampleBufferGetImageBuffer(refSample)),actual=try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
            // Same existing subtitle footprint arithmetic, independently applied to preview reference.
            if subtitle {
                CVPixelBufferLockBaseAddress(ref,[]);for f in footprints.visible(at:k){f.composite(ref)};CVPixelBufferUnlockBaseAddress(ref,[])
            }
            CVPixelBufferLockBaseAddress(ref,.readOnly);CVPixelBufferLockBaseAddress(actual,.readOnly)
            var mse=0.0,count=0,maximum=0
            for plane in 0..<2 {
                let a=CVPixelBufferGetBaseAddressOfPlane(ref,plane)!.assumingMemoryBound(to:UInt8.self),b=CVPixelBufferGetBaseAddressOfPlane(actual,plane)!.assumingMemoryBound(to:UInt8.self)
                let w=plane==0 ? 1920:1920,h=plane==0 ? 1080:540,ar=CVPixelBufferGetBytesPerRowOfPlane(ref,plane),br=CVPixelBufferGetBytesPerRowOfPlane(actual,plane)
                for y in stride(from:4,to:h-4,by:8){for x in stride(from:4,to:w-4,by:8){for component in 0..<(plane==0 ? 1:2){let d=abs(Int(a[y*ar+x+component])-Int(b[y*br+x+component]));mse+=Double(d*d);count+=1;maximum=max(maximum,d)}}}
            }
            CVPixelBufferUnlockBaseAddress(actual,.readOnly);CVPixelBufferUnlockBaseAddress(ref,.readOnly)
            let psnr=mse==0 ? 100:10*log10(255*255*Double(count)/mse)
            XCTAssertGreaterThanOrEqual(psnr,40,"lossy sampled plane PSNR f\(k)")
            rows.append(["frame":k,"PTS":Double(k)/30,"sampledPlanePSNR":psnr,"maximumSampledError":maximum]);k+=1
        }
        XCTAssertEqual(k,s.t.durationFrames);XCTAssertNil(ro.copyNextSampleBuffer());XCTAssertEqual(er.status,.completed);XCTAssertEqual(rr.status,.completed)
        let audio=try await asset.loadTracks(withMediaType:.audio)
        if let first=audio.first {let formats=try await first.load(.formatDescriptions);XCTAssertEqual(CMFormatDescriptionGetMediaSubType(formats.first!),kAudioFormatMPEG4AAC)}
        try JSONSerialization.data(withJSONObject:["frames":k,"width":1920,"height":1080,"fps":rate,"duration":range.duration.seconds,"audioTracks":audio.count,"comparisons":rows],options:[.prettyPrinted,.sortedKeys]).write(to:url.appendingPathExtension("metrics.json"))
        try await ClockCarrierCompatibilityTests.wait(5){ImagePreviewCompositor.admission.outstanding==0 && ImagePreviewMetal.ownership.counts.active==0}
        XCTAssertEqual(ImagePreviewMetal.ownership.counts.resources,0)
    }
    func testImageOnlyFiveSecondAndSharedRendering()async throws {
        let s=try await setup(),(result,url,log)=await export(s,"five-second.mp4")
        XCTAssertEqual(result,.completed(url));guard case .completed=result else{return}
        XCTAssertEqual(log.progress.last,1);XCTAssertEqual(log.progress.filter{$0==1}.count,1)
        XCTAssertTrue(zip(log.progress,log.progress.dropFirst()).allSatisfy{$0<=$1});XCTAssertTrue(log.progress.allSatisfy{$0.isFinite && $0>=0 && $0<=1})
        try await inspect(s,url)
    }
    func testMusicMixedAudioAndSubtitles()async throws {
        for mixed in [false,true] {
            var s=try await setup(mixed,n:60)
            let fixtures=URL(fileURLWithPath:try XCTUnwrap(ProcessInfo.processInfo.environment["OTF_EXPORT_FIXTURES"]))
            let a=try await MediaProbe.inspect(fixtures.appendingPathComponent("aud-wav48s.wav"));s.media[a.id]=a;s.t=s.t.registering(a)
            let clips=[Clip(mediaID:a.id,start:5,sourceIn:0,length:25,lane:Lane.audioID,audio:.init(volumePercent:50)),Clip(mediaID:a.id,start:30,sourceIn:25,length:30,lane:Lane.audioID,audio:.init(muted:true))]
            s.t=s.t.rebuilt(audio:clips)
            let lane=UUID();s.t=try s.t.addingLane(.subtitle,name:"subtitle",id:lane).addingSubtitle(lane:lane,at:12,length:18,text:"IMG EXPORT")
            let unchanged=s.t
            let (result,url,_)=await export(s,mixed ? "mixed.mp4":"music.mp4");XCTAssertEqual(result,.completed(url));guard case .completed=result else{continue}
            try await inspect(s,url,subtitle:true)
            let decoded=try await AudioMixExportTests.decodeMP4(url),plan=try await InternalImagePreview.plan(s.t,media:s.media,enabled:true,resolvedImages:s.urls),preview=try await AudioMixExportTests.decodePreview(plan)
            XCTAssertEqual(decoded.audioTracks,1);XCTAssertEqual(decoded.channels,2)
            var audioRows=[[String:Any]]()
            for f in [1,10,20,40,55] {
                let actual=AudioMixExportTests.rms(decoded.pcm.l,from:f,to:f+1),expected=AudioMixExportTests.rms(preview.l,from:f,to:f+1)
                XCTAssertEqual(actual,expected,accuracy:0.02);audioRows.append(["frame":f,"decodedRMS":actual,"previewRMS":expected])
            }
            XCTAssertEqual(AudioMixExportTests.rms(decoded.pcm.l,from:20,to:21),0.1/sqrt(2),accuracy:0.02,"independent 0.2 sine amplitude x 50% gain")
            try JSONSerialization.data(withJSONObject:audioRows,options:[.prettyPrinted,.sortedKeys]).write(to:url.appendingPathExtension("audio.json"))
            XCTAssertLessThan(AudioMixExportTests.rms(decoded.pcm.l,from:35,to:55),0.002)
            XCTAssertEqual(s.t,unchanged);XCTAssertEqual(s.t.audioClips.map(\.lineageKey),clips.map(\.lineageKey))
        }
    }
    func testCancelWriterFailureAndDestinationProtection()async throws {
        let s=try await setup(),dest=root.appendingPathComponent("existing.mp4"),sentinel=Data("preserved output".utf8)
        try sentinel.write(to:dest)
        let log=Log();var opt=ExportService.Options();opt.onTempDirectory={u in log.lock.withLock{log.temp=u}}
        let task=Task {await ExportService.exportImages(s.t,media:s.media,enabled:true,resolvedImages:s.urls,to:.fromSavePanel(dest),options:opt){v in log.add(v);if v>0.1 {log.lock.withLock{log.task?.cancel()}}}}
        log.lock.withLock{log.task=task};let cancelled=await task.value
        XCTAssertEqual(cancelled,.cancelled);XCTAssertEqual(try Data(contentsOf:dest),sentinel);XCTAssertFalse(log.progress.contains(1));XCTAssertFalse(FileManager.default.fileExists(atPath:try XCTUnwrap(log.temp).path))
        opt.onTempDirectory={u in log.lock.withLock{log.temp=u};try? FileManager.default.createDirectory(at:u.appendingPathComponent("output.mp4"),withIntermediateDirectories:false)}
        let failure=await ExportService.exportImages(s.t,media:s.media,enabled:true,resolvedImages:s.urls,to:.fromSavePanel(dest),options:opt){_ in}
        guard case .failed=failure else{return XCTFail("real writer file-exists error not reported")}
        XCTAssertEqual(try Data(contentsOf:dest),sentinel);XCTAssertFalse(FileManager.default.fileExists(atPath:try XCTUnwrap(log.temp).path))
        let source=try XCTUnwrap(s.urls.values.first),bytes=try Data(contentsOf:source)
        let protected=await ExportService.exportImages(s.t,media:s.media,enabled:true,resolvedImages:s.urls,to:.fromSavePanel(source)){_ in}
        XCTAssertEqual(protected,.failed(.destinationIsSource));XCTAssertEqual(try Data(contentsOf:source),bytes)
        let (replacement,url,_)=await export(s,"existing.mp4");XCTAssertEqual(replacement,.completed(url));try await inspect(s,url)
    }
    func testGateUnverifiedAndSpectrumRefusedBeforeWriting()async throws {
        var s=try await setup(n:30)
        let (off,url,_)=await export(s,"off.mp4",enabled:false);guard case .failed=off else{return XCTFail("disabled admission")};XCTAssertFalse(FileManager.default.fileExists(atPath:url.path))
        let data=try ProjectPersistence.encode(ProjectPersistence.make(timeline:s.t,projectID:UUID()),at:root.appendingPathComponent("project.ontheframe"))
        let restored=try ProjectPersistence.decode(data).timeline
        let missing=await ExportService.exportImages(restored,media:[:],enabled:true,to:.fromSavePanel(url)){_ in};guard case .failed=missing else{return XCTFail("unverified admission")}
        let plan=try await InternalImagePreview.plan(s.t,media:[:],enabled:true,resolvedImages:s.urls)
        let direct=await ExportService.export(plan,to:.fromSavePanel(url),sources:[]){_ in};guard case .failed=direct else{return XCTFail("preview export bypass")}
        let fixtures=URL(fileURLWithPath:try XCTUnwrap(ProcessInfo.processInfo.environment["OTF_EXPORT_FIXTURES"]))
        let audio=try await MediaProbe.inspect(fixtures.appendingPathComponent("aud-wav48s.wav"));s.t=s.t.registering(audio)
        let audioClip=Clip(mediaID:audio.id,start:0,sourceIn:0,length:30,lane:Lane.audioID)
        s.t=s.t.rebuilt(audio:[audioClip]);s.media[audio.id]=audio
        let lane=UUID();s.t=try s.t.addingLane(.spectrum,name:"spectrum",id:lane).addingSpectrum(lane:lane,at:0,length:10,sourceKey:audioClip.lineageKey)
        let (spectrum,_,_)=await export(s,"spectrum.mp4");guard case .failed=spectrum else{return XCTFail("spectrum omission")}
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("spectrum.mp4").path));XCTAssertFalse(FileManager.default.fileExists(atPath:url.path))
    }
}
