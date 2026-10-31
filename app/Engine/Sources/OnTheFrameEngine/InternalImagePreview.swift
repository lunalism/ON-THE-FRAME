import AVFoundation
import CoreGraphics
import ImageIO
import Metal

/// Internal preview capability only. ExportService and the ordinary planner retain
/// their complete-catalog rejection; this never changes the persisted media model.
public enum InternalImagePreview {
    static func error(_ s: String) -> NSError { NSError(domain:"OTFInternalImagePreview",code:1,userInfo:[NSLocalizedDescriptionKey:s]) }
    public static func containsImages(_ t: Timeline) -> Bool { !t.stillImageIDs.isEmpty }

    /// Decode/Metal work is detached from the caller's (normally UI) executor. A
    /// persisted descriptor is compared against a fresh full probe under source access.
    public static func plan(_ t: Timeline, media: [UUID:MediaAsset], enabled: Bool,
                            settings: RenderSettings = .m1, resolvedImages:[UUID:URL] = [:]) async throws -> PlannedComposition {
        guard enabled else { throw error("내부 이미지 프리뷰가 꺼져 있습니다.") }
        let work=Task.detached { try await build(t,media:media,settings:settings,resolvedImages:resolvedImages) }
        return try await withTaskCancellationHandler(operation:{let result=try await work.value;try Task.checkCancellation();return result},onCancel:{work.cancel()})
    }
    private static func build(_ t:Timeline,media:[UUID:MediaAsset],settings:RenderSettings,resolvedImages:[UUID:URL]) async throws -> PlannedComposition {
        guard settings.renderSize==CGSize(width:1920,height:1080),settings.fps==30,t.durationFrames>0 else {throw error("내부 이미지 프리뷰는 FHD 30fps만 검증합니다.")}
        try Task.checkCancellation()
        let renderer=try ImagePreviewMetal()
        var images=[UUID:MTLTexture](),sizes=[UUID:CGSize](),decodedBytes=0
        // Includes hidden and unused catalog images: never silently omit invalid sources.
        for entry in t.mediaCatalog {
            guard let source=entry.still else {continue}
            guard let url=resolvedImages[entry.id] ?? source.validated?.url,url.isFileURL else {throw error("이미지 원본 접근·검증이 필요합니다. 저장된 참조는 유지했습니다.")}
            let scoped=url.startAccessingSecurityScopedResource()
            defer {if scoped {url.stopAccessingSecurityScopedResource()}}
            let proof=try await StillImageProjectModel.ValidatedImage.inspect(url)
            guard proof.descriptor.identity.size==source.reference.size,
                  proof.descriptor.identity.modifiedNs==source.reference.modifiedNs,
                  StillImageProjectModel.ImageInfo(proof.descriptor)==source.reference.image else {throw error("이미지 원본이 저장된 검증 정보와 다릅니다. 재검증/재연결이 필요합니다.")}
            let d=proof.descriptor
            let count=d.displayWidth*d.displayHeight*4
            guard count<=64*1024*1024-decodedBytes else {throw error("내부 이미지 프리뷰의 64 MiB 이미지 예산을 초과했습니다.")}
            guard let src=CGImageSourceCreateWithURL(url as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary),
                  let im=CGImageSourceCreateThumbnailAtIndex(src,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:max(d.width,d.height)] as CFDictionary),
                  im.width==d.displayWidth,im.height==d.displayHeight,
                  let space=CGColorSpace(name:CGColorSpace.sRGB),
                  let c=CGContext(data:nil,width:im.width,height:im.height,bitsPerComponent:8,bytesPerRow:im.width*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),let bytes=c.data else {throw error("이미지를 안전하게 디코딩하지 못했습니다.")}
            c.interpolationQuality = .none;c.draw(im,in:CGRect(x:0,y:0,width:im.width,height:im.height))
            try Task.checkCancellation()
            guard FileIdentity.of(url)==d.identity else {throw StillImageProbeError.changed}
            images[entry.id]=try renderer.upload(width:im.width,height:im.height,bytes:bytes)
            sizes[entry.id]=CGSize(width:im.width,height:im.height);decodedBytes+=count
        }
        // Explicit AUDIO-ONLY projection. It never becomes model/session state and
        // is never used for eligibility or image visibility. Reuse exact native audio
        // source-time, silence, gain and fade construction and retained AVURLAssets.
        let audioTimeline=Timeline(audioClips:t.audioClips,lanes:t.lanes,media:t.media,
                                   mediaFrames:t.mediaFrames,mediaHasAudio:t.mediaHasAudio,
                                   mediaHasVideo:t.mediaHasVideo,durationFrames:t.durationFrames)
        let audio:PlannedComposition? = t.audioClips.isEmpty ? nil:try await CompositionPlanner.plan(audioTimeline,media:media,settings:settings)
        let comp=(audio?.composition.mutableCopy() as? AVMutableComposition) ?? AVMutableComposition()
        for track in comp.tracks(withMediaType:.video) {comp.removeTrack(track)}
        var keep=audio?.assets ?? []
        let carrierURL=try await ImagePreviewClock.shared.url()
        let carrierAsset=AVURLAsset(url:carrierURL);keep.append(carrierAsset)
        guard let src=try await carrierAsset.loadTracks(withMediaType:.video).first,
              let carrier=comp.addMutableTrack(withMediaType:.video,preferredTrackID:kCMPersistentTrackID_Invalid) else {throw error("프리뷰 시계를 구성하지 못했습니다.")}
        let range=try await src.load(.timeRange)
        try carrier.insertTimeRange(range,of:src,at:.zero)
        carrier.scaleTimeRange(CMTimeRange(start:.zero,duration:range.duration),toDuration:settings.time(t.durationFrames))
        var videoTracks=[UUID:CMPersistentTrackID]()
        for clip in t.clips where !t.isStillImage(clip.mediaID) {
            try Task.checkCancellation()
            guard let m=media[clip.mediaID],let dst=comp.addMutableTrack(withMediaType:.video,preferredTrackID:kCMPersistentTrackID_Invalid) else {throw PlanError.missingMedia(clip.mediaID)}
            let asset=AVURLAsset(url:m.url);keep.append(asset)
            guard let v=try await asset.loadTracks(withMediaType:.video).first else {throw PlanError.missingMedia(clip.mediaID)}
            let r=try await v.load(.timeRange)
            try dst.insertTimeRange(CMTimeRange(start:r.start+settings.time(clip.sourceIn),duration:settings.time(clip.length)),of:v,at:settings.time(clip.start))
            videoTracks[clip.id]=dst.trackID
        }
        let bounds=Set([0,t.durationFrames]+t.clips.flatMap{[$0.start,$0.end]}).sorted()
        var instructions=[ImagePreviewInstruction]()
        // Same visual lane order, WITHOUT the opaque-video culler: alpha images
        // cannot establish full-canvas occlusion merely by occupying a rectangle.
        let lanes=t.lanes.filter{$0.kind == .video}.reversed()
        for (lo,hi) in zip(bounds,bounds.dropFirst()) where hi>lo {
            var layers=[ImagePreviewInstruction.Layer]()
            for lane in lanes {
                guard let clip=t.clips.first(where:{$0.lane==lane.id && $0.start<=lo && $0.end>=hi}) else {continue}
                let transform:CGAffineTransform
                if let size=sizes[clip.mediaID] {
                    let x=clip.effectiveTransform,cx=settings.renderSize.width/2,cy=settings.renderSize.height/2
                    transform=CompositionPlanner.fitTransform(natural:size,preferred:.identity,render:settings.renderSize)
                        .concatenating(CGAffineTransform(translationX:-cx,y:-cy))
                        .concatenating(CGAffineTransform(scaleX:x.scale,y:x.scale))
                        .concatenating(CGAffineTransform(translationX:cx+x.x,y:cy+x.y))
                } else {
                    guard let m=media[clip.mediaID] else {throw PlanError.missingMedia(clip.mediaID)}
                    transform=CompositionPlanner.layerTransform(m,clip.effectiveTransform,render:settings.renderSize)
                }
                layers.append(.init(image:images[clip.mediaID],track:videoTracks[clip.id],inverse:transform.inverted()))
            }
            guard layers.count<=8 else {throw error("내부 이미지 프리뷰는 동시 시각 레이어 8개까지 검증합니다.")}
            instructions.append(ImagePreviewInstruction(range:CMTimeRange(start:settings.time(lo),duration:settings.time(hi-lo)),carrier:carrier.trackID,layers:layers,renderer:renderer,projectEnd:settings.time(t.durationFrames)))
        }
        guard CMTimeCompare(comp.duration,settings.time(t.durationFrames))==0 else {throw error("프리뷰 시계 길이가 프로젝트와 다릅니다.")}
        let vc=AVMutableVideoComposition();vc.customVideoCompositorClass=ImagePreviewCompositor.self
        vc.renderSize=settings.renderSize;vc.frameDuration=settings.frameDuration;vc.instructions=instructions
        try Task.checkCancellation()
        var result=PlannedComposition(composition:comp.copy() as! AVComposition,videoComposition:vc.copy() as! AVVideoComposition,durationFrames:t.durationFrames,settings:settings,hasAudio:audio?.hasAudio ?? false,audioMix:audio?.audioMix,hasVideo:true,assets:keep,subtitles:t.renderedSubtitles,spectra:t.spectra)
        result.imagePreviewOnly=true
        return result
    }
}

/// One generated 30-sample transport, never a media-catalog entry. Its contents
/// are required only for native AVPlayer scheduling, never passed to the shader.
private actor ImagePreviewClock {
    static let shared=ImagePreviewClock()
    private var cached:URL?
    func url() async throws -> URL {
        if let cached {return cached}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("OTF-preview-clock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let url=root.appendingPathComponent("timing-only.mov")
        let writer=try AVAssetWriter(outputURL:url,fileType:.mov)
        let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:16,AVVideoHeightKey:16])
        input.expectsMediaDataInRealTime=false
        let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:16,kCVPixelBufferHeightKey as String:16])
        guard writer.canAdd(input) else {throw InternalImagePreview.error("clock writer input")};writer.add(input)
        guard writer.startWriting() else {throw writer.error ?? InternalImagePreview.error("clock writer start")};writer.startSession(atSourceTime:.zero)
        var pb:CVPixelBuffer?
        guard CVPixelBufferCreate(nil,16,16,kCVPixelFormatType_32BGRA,nil,&pb)==kCVReturnSuccess,let pb else {writer.cancelWriting();throw InternalImagePreview.error("clock buffer")}
        CVPixelBufferLockBaseAddress(pb,[]);memset(CVPixelBufferGetBaseAddress(pb),0,CVPixelBufferGetBytesPerRow(pb)*16);CVPixelBufferUnlockBaseAddress(pb,[])
        do {
            for f in 0..<30 {
                while !input.isReadyForMoreMediaData {try Task.checkCancellation();guard writer.status == .writing else{throw writer.error ?? InternalImagePreview.error("clock writer stopped")};try await Task.sleep(nanoseconds:1_000_000)}
                guard adaptor.append(pb,withPresentationTime:CMTime(value:Int64(f),timescale:30)) else {throw writer.error ?? InternalImagePreview.error("clock append")}
            }
            input.markAsFinished();writer.endSession(atSourceTime:CMTime(value:1,timescale:1));await writer.finishWriting()
            guard writer.status == .completed else {throw writer.error ?? InternalImagePreview.error("clock completion")}
            cached=url;return url
        } catch {writer.cancelWriting();throw error}
    }
}

final class ImagePreviewInstruction:NSObject,AVVideoCompositionInstructionProtocol,@unchecked Sendable {
    struct Layer {let image:MTLTexture?,track:CMPersistentTrackID?,inverse:CGAffineTransform}
    let timeRange:CMTimeRange,enablePostProcessing=false,containsTweening=true
    let passthroughTrackID=kCMPersistentTrackID_Invalid
    let requiredSourceTrackIDs:[NSValue]?
    let carrier:CMPersistentTrackID,layers:[Layer],renderer:ImagePreviewMetal
    let projectEnd:CMTime
    init(range:CMTimeRange,carrier:CMPersistentTrackID,layers:[Layer],renderer:ImagePreviewMetal,projectEnd:CMTime) {
        timeRange=range;self.carrier=carrier;self.layers=layers;self.renderer=renderer;self.projectEnd=projectEnd
        requiredSourceTrackIDs=([carrier]+layers.compactMap(\.track)).map{NSNumber(value:$0)}
    }
}

final class ImagePreviewCompositor:NSObject,AVVideoCompositing,@unchecked Sendable {
    let sourcePixelBufferAttributes:[String:any Sendable]?=[kCVPixelBufferPixelFormatTypeKey as String:[kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]]
    let requiredPixelBufferAttributesForRenderContext:[String:any Sendable]=[kCVPixelBufferPixelFormatTypeKey as String:[kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange],kCVPixelBufferMetalCompatibilityKey as String:true,kCVPixelBufferIOSurfacePropertiesKey as String:[String:Int]()]
    /// Bounded opt-in diagnostic ring; disabled in normal operation.
    final class Trace:@unchecked Sendable {
        private let lock=NSLock();private var enabled=false,rows=[[String:Any]]()
        func reset(){lock.lock();enabled=true;rows=[];lock.unlock()}
        func add(_ fields:[String:Any]){lock.lock();defer{lock.unlock()};guard enabled else{return};if rows.count==128{rows.removeFirst()};var row=fields;row["ns"]=DispatchTime.now().uptimeNanoseconds;rows.append(row)}
        var snapshot:[[String:Any]]{lock.lock();defer{lock.unlock()};return rows}
    }
    static let trace=Trace()
    private static let worker=DispatchQueue(label:"dev.ontheframe.internal-image-preview")
    final class Admission:@unchecked Sendable {
        private let lock=NSLock();private var count=0
        func acquire()->Bool{lock.lock();defer{lock.unlock()};guard count<5 else{return false};count+=1;return true}
        func release(){lock.lock();count-=1;lock.unlock()}
        var outstanding:Int{lock.lock();defer{lock.unlock()};return count}
    }
    static let admission=Admission()
    private let lock=NSRecursiveLock();private var epoch=0
    enum Disposition:Equatable {case compose,endBoundary,invalid}
    /// Visible intervals remain half-open. AVPlayer can prefetch exactly the item
    /// endpoint; it has no visible frame there. Cancel only this exact terminal
    /// request, never shift a time or publish the last image outside its interval.
    static func disposition(time:CMTime,range:CMTimeRange,projectEnd:CMTime)->Disposition {
        guard time.isNumeric,projectEnd.isNumeric,projectEnd > .zero else{return .invalid}
        if range.containsTime(time){return .compose}
        if CMTimeCompare(time,projectEnd)==0,CMTimeCompare(range.end,projectEnd)==0{return .endBoundary}
        return .invalid
    }
    func renderContextChanged(_ newRenderContext:AVVideoCompositionRenderContext) {}
    func cancelAllPendingVideoCompositionRequests() {lock.lock();epoch &+= 1;Self.trace.add(["event":"cancel","epoch":epoch]);lock.unlock()}
    private struct Box:@unchecked Sendable {let request:AVAsynchronousVideoCompositionRequest}
    func startRequest(_ request:AVAsynchronousVideoCompositionRequest) {
        lock.lock();let generation=epoch;lock.unlock()
        guard Self.admission.acquire() else {request.finishCancelledRequest();return}
        let box=Box(request:request)
        Self.trace.add(["event":"request","time":request.compositionTime.seconds,"epoch":generation])
        Self.worker.async { [self] in
            defer{Self.admission.release()}
            func current()->Bool{lock.lock();defer{lock.unlock()};return epoch==generation}
            guard current() else {box.request.finishCancelledRequest();return}
            do {
                guard let i=box.request.videoCompositionInstruction as? ImagePreviewInstruction else {throw InternalImagePreview.error("instruction missing")}
                let inRange=i.timeRange.containsTime(box.request.compositionTime)
                let carrierPresent=box.request.sourceFrame(byTrackID:i.carrier) != nil
                Self.trace.add(["event":"boundary-observation","time":box.request.compositionTime.seconds,"rangeStart":i.timeRange.start.seconds,"rangeEnd":i.timeRange.end.seconds,"inRange":inRange,"carrierPresent":carrierPresent,"epoch":generation])
                if Self.disposition(time:box.request.compositionTime,range:i.timeRange,projectEnd:i.projectEnd) == .endBoundary {
                    lock.lock();defer{lock.unlock()}
                    Self.trace.add(["event":"end-boundary-cancelled","time":box.request.compositionTime.seconds,"projectEnd":i.projectEnd.seconds,"epoch":generation])
                    box.request.finishCancelledRequest();return
                }
                guard inRange,carrierPresent else {throw InternalImagePreview.error("carrier time/source missing")}
                Self.trace.add(["event":"render-start","time":box.request.compositionTime.seconds,"rangeStart":i.timeRange.start.seconds,"rangeEnd":i.timeRange.end.seconds,"layers":i.layers.count,"epoch":generation])
                let result=try i.renderer.render(i.layers,source:{box.request.sourceFrame(byTrackID:$0)})
                lock.lock();defer{lock.unlock()}
                guard epoch==generation else {box.request.finishCancelledRequest();return}
                Self.trace.add(["event":"publish","time":box.request.compositionTime.seconds,"epoch":generation])
                box.request.finish(withComposedVideoFrame:result)
            } catch {Self.trace.add(["event":"error","time":box.request.compositionTime.seconds,"epoch":generation,"error":String(describing:error)]);lock.lock();defer{lock.unlock()};if epoch==generation{box.request.finish(with:error)}else{box.request.finishCancelledRequest()}}
        }
    }
}
