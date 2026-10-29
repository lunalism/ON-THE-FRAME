import AVFoundation
import Metal
import Foundation

/// GPU01 test-only. One 2x2 block per thread; no full-frame RGB surface or CPU fallback.
final class GMNV12 {
    let device:MTLDevice, queue:MTLCommandQueue, pipeline:MTLComputePipelineState
    let cache:CVMetalTextureCache, png:MTLTexture, forward:MTLBuffer, inverse:MTLBuffer
    let leases=GMLeaseBook()
    let setup:[String:Any]
    static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    float lut(float v, device const float *t) {
        float p=clamp(v,0.0f,1.0f)*4096.0f;
        uint i=min(4095u,uint(p));float a=p-float(i);
        return t[i]*(1.0f-a)+t[i+1]*a;
    }
    float q(float v) { return clamp(round(v),0.0f,255.0f)/255.0f; }
    kernel void compose(texture2d<float,access::read> by [[texture(0)]],
        texture2d<float,access::read> bc [[texture(1)]],
        texture2d<float,access::read> ty [[texture(2)]],
        texture2d<float,access::read> tc [[texture(3)]],
        texture2d<float,access::read> png [[texture(4)]],
        texture2d<float,access::write> oy [[texture(5)]],
        texture2d<float,access::write> oc [[texture(6)]],
        device const float *f [[buffer(0)]], device const float *inv [[buffer(1)]],
        constant uint &phase [[buffer(2)]], uint2 id [[thread_position_in_grid]]) {
        if(id.x>=960 || id.y>=540)return;
        uint2 p=id*2;bool top=phase>=2 && phase<4 && p.x>=960 && p.y>=540;
        if(top || phase==0 || phase==5) {
            uint2 s=top ? p-uint2(960,540):p;
            for(uint dy=0;dy<2;dy++)for(uint dx=0;dx<2;dx++) {
                float y=top ? ty.read(s+uint2(dx,dy)).r:by.read(s+uint2(dx,dy)).r;
                oy.write(float4(y,0,0,1),p+uint2(dx,dy));
            }
            float2 c=top ? tc.read(s/2).rg:bc.read(s/2).rg;
            oc.write(float4(c,0,1),id);return;
        }
        float2 codes=round(bc.read(id).rg*255.0f);
        float cb=(codes.x-128.0f)/224.0f,cr=(codes.y-128.0f)/224.0f;
        float sumCb=0,sumCr=0;
        for(uint dy=0;dy<2;dy++)for(uint dx=0;dx<2;dx++) {
            uint2 at=p+uint2(dx,dy);float yy=(round(by.read(at).r*255.0f)-16.0f)/219.0f;
            float4 im=png.read(at);float remain=1.0f-im.a;
            float r=lut(im.r+remain*lut(yy+1.5748f*cr,f),inv);
            float g=lut(im.g+remain*lut(yy-0.187324f*cb-0.468124f*cr,f),inv);
            float b=lut(im.b+remain*lut(yy+1.8556f*cb,f),inv);
            float l=0.2126f*r+0.7152f*g+0.0722f*b;
            oy.write(float4(q(16.0f+219.0f*l),0,0,1),at);
            if(dx==0){sumCb+=(b-l)/1.8556f;sumCr+=(r-l)/1.5748f;}
        }
        oc.write(float4(q(128.0f+112.0f*sumCb),q(128.0f+112.0f*sumCr),0,1),id);
    }
    """
    init(image:IBImage, transfer:IBTransfer)throws {
        let start=IBPerfClock.now(process:true)
        guard let d=MTLCreateSystemDefaultDevice(),let queue=d.makeCommandQueue() else{throw IBContract.error("GPU01 Metal unavailable",code:300)}
        device=d;self.queue=queue
        let options=MTLCompileOptions();options.fastMathEnabled=false
        let lib=try d.makeLibrary(source:Self.shader,options:options)
        guard let function=lib.makeFunction(name:"compose") else{throw IBContract.error("GPU01 kernel missing",code:300)}
        pipeline=try d.makeComputePipelineState(function:function)
        var c:CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil,nil,d,nil,&c)==kCVReturnSuccess,let c else{throw IBContract.error("GPU01 texture cache",code:300)};cache=c
        let resources=IBPerfClock.now(process:true),desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:1920,height:1080,mipmapped:false)
        desc.storageMode = .shared;desc.usage = .shaderRead
        guard let tex=d.makeTexture(descriptor:desc),image.rgba.count==1920*1080*4 else{throw IBContract.error("GPU01 PNG texture",code:300)};png=tex
        guard let f=transfer.toSRGB.withUnsafeBytes({d.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)}),let i=transfer.to709.withUnsafeBytes({d.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)}) else{throw IBContract.error("GPU01 LUT buffers",code:300)}
        forward=f;inverse=i
        let upload=IBPerfClock.now(process:true)
        image.rgba.withUnsafeBytes{tex.replace(region:MTLRegionMake2D(0,0,1920,1080),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:1920*4)}
        let end=IBPerfClock.now(process:true)
        setup=["device":d.name,"unifiedMemory":d.hasUnifiedMemory,"pipelineAndCache":IBPerfClock.span(start,resources),"resourceCreationAndLUTCopy":IBPerfClock.span(resources,upload),"PNGSharedUpload":IBPerfClock.span(upload,end),"total":IBPerfClock.span(start,end),"PNGAllocatedBytes":tex.allocatedSize,"LUTAllocatedBytes":f.allocatedSize+i.allocatedSize,"deviceCurrentAllocatedBytes":d.currentAllocatedSize,"fastMath":false]
    }
    static func allocate()throws->CVPixelBuffer {
        var pb:CVPixelBuffer?
        let attrs=[kCVPixelBufferIOSurfacePropertiesKey:[:],kCVPixelBufferMetalCompatibilityKey:true] as CFDictionary
        guard CVPixelBufferCreate(nil,1920,1080,IBContract.format,attrs,&pb)==kCVReturnSuccess,let pb else{throw IBContract.error("GPU01 output NV12 allocation",code:300)};return pb
    }
    func views(_ pb:CVPixelBuffer,write:Bool)throws->([CVMetalTexture],[MTLTexture]) {
        try IBContract.validate(pb)
        var refs=[CVMetalTexture](),textures=[MTLTexture]()
        for plane in 0..<2 {
            var ref:CVMetalTexture?
            let usage:MTLTextureUsage=write ? .shaderWrite:.shaderRead
            let attrs=[kCVMetalTextureUsage:usage.rawValue] as CFDictionary
            let status=CVMetalTextureCacheCreateTextureFromImage(nil,cache,pb,attrs,plane==0 ? .r8Unorm:.rg8Unorm,plane==0 ? 1920:960,plane==0 ? 1080:540,plane,&ref)
            guard status==kCVReturnSuccess,let ref,let tex=CVMetalTextureGetTexture(ref) else{throw IBContract.error("GPU01 unsupported NV12 Metal interop plane\(plane) status\(status)",code:300)}
            refs.append(ref);textures.append(tex)
        }
        return (refs,textures)
    }
    func render(bottom:CVPixelBuffer,top:CVPixelBuffer?,phase:Int)throws->(CVPixelBuffer,[String:Any]) {
        guard (0..<6).contains(phase),!((phase==2 || phase==3) && top==nil) else{throw IBContract.error("GPU01 phase/top",code:200)}
        let start=IBPerfClock.now(process:true),out=try Self.allocate();IBContract.tag(out)
        let allocated=IBPerfClock.now(process:true),b=try views(bottom,write:false),t=try views(top ?? bottom,write:false),o=try views(out,write:true),mapped=IBPerfClock.now(process:true)
        guard let cmd=queue.makeCommandBuffer(),let encoder=cmd.makeComputeCommandEncoder() else{throw IBContract.error("GPU01 encoding",code:300)}
        encoder.setComputePipelineState(pipeline)
        for (i,tex) in (b.1+t.1+[png]+o.1).enumerated(){encoder.setTexture(tex,index:i)}
        encoder.setBuffer(forward,offset:0,index:0);encoder.setBuffer(inverse,offset:0,index:1)
        var phaseValue=UInt32(phase);encoder.setBytes(&phaseValue,length:4,index:2)
        encoder.dispatchThreads(MTLSize(width:960,height:540,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:8,depth:1));encoder.endEncoding()
        let encoded=IBPerfClock.now(process:true),done=DispatchSemaphore(value:0)
        guard let lease=leases.admit([cmd,b,t,o,bottom,top as Any,out,cache,png,forward,inverse,pipeline,queue,device],notify:{_ in}) else{throw IBContract.error("GPU02A admission stopped/full",code:300)}
        guard leases.submit(lease) else{leases.terminate(lease,.failed);throw IBContract.error("GPU02A active capacity busy",code:300)}
        let owner=leases
        cmd.addCompletedHandler{c in owner.observedCompletion(lease,failed:c.status != .completed);done.signal()};cmd.commit();let submitted=IBPerfClock.now(process:true)
        guard done.wait(timeout:.now()+10) == .success else{leases.terminate(lease,.timedOut);leases.quarantineUnobserved();throw IBContract.error("GPU01 command completion timeout; quarantined until observed completion",code:300)}
        let completed=IBPerfClock.now(process:true)
        guard cmd.status == .completed,cmd.error==nil else{throw cmd.error ?? IBContract.error("GPU01 command failed",code:300)}
        // Keep source/output CVMetalTexture wrappers alive through completed command execution.
        withExtendedLifetime((b,t,o,bottom,top)){ }
        CVMetalTextureCacheFlush(cache,0)
        let delivered=IBPerfClock.now(process:true)
        return (out,["allocationAndTag":IBPerfClock.span(start,allocated),"zeroCopyPlaneViews":IBPerfClock.span(allocated,mapped),"encode":IBPerfClock.span(mapped,encoded),"submission":IBPerfClock.span(encoded,submitted),"completionWait":IBPerfClock.span(submitted,completed),"deliveryAndCacheFlush":IBPerfClock.span(completed,delivered),"full":IBPerfClock.span(start,delivered),"GPUSeconds":cmd.gpuEndTime-cmd.gpuStartTime,"GPUStart":cmd.gpuStartTime,"GPUEnd":cmd.gpuEndTime,"outputPTS":"\(phase)/30 (test sidecar; not AV callback)","outputIOSurface":CVPixelBufferGetIOSurface(out) != nil,"deviceCurrentAllocatedBytes":device.currentAllocatedSize,"mappedTextureAllocatedBytes":(b.1+t.1+o.1).reduce(0){$0+$1.allocatedSize},"readback":"none; delivered shared NV12 after completion; CPU QA lock/read outside timer"])
    }
}
