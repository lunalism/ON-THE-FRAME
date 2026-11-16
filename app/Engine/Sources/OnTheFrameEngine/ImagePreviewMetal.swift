import AVFoundation
import Metal

/// Preview-only generalized layer adapter. Retains the experimental 709 ICC/sRGB
/// component-LUT and left-sited 420 quantization methodology. All GPU waits are on
/// the compositor worker; a submitted command owns its wrappers until completion.
final class ImagePreviewMetal:@unchecked Sendable {
    let device:MTLDevice,queue:MTLCommandQueue,pipeline:MTLComputePipelineState,cache:CVMetalTextureCache
    let forward:MTLBuffer,inverse:MTLBuffer,dummy:MTLTexture
    private let lock=NSLock();private var quarantined=false
    final class Ownership:@unchecked Sendable {
        private let lock=NSLock();private var active=0,resources=0
        func acquire(_ n:Int){lock.lock();active+=1;resources+=n;lock.unlock()}
        func retire(_ n:Int){lock.lock();active-=1;resources-=n;lock.unlock()}
        var counts:(active:Int,resources:Int){lock.lock();defer{lock.unlock()};return(active,resources)}
    }
    static let ownership=Ownership()
    private static let tags:[String:String]=[
        kCVImageBufferColorPrimariesKey as String:kCVImageBufferColorPrimaries_ITU_R_709_2 as String,
        kCVImageBufferTransferFunctionKey as String:kCVImageBufferTransferFunction_ITU_R_709_2 as String,
        kCVImageBufferYCbCrMatrixKey as String:kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String,
        kCVImageBufferChromaLocationTopFieldKey as String:kCVImageBufferChromaLocation_Left as String]
    private static let shader="""
    #include <metal_stdlib>
    using namespace metal;
    struct Layer {float4 m;float4 p;};
    float lut(float v,device const float *t){float p=clamp(v,0.0f,1.0f)*4096.0f;uint i=min(4095u,uint(p));return mix(t[i],t[i+1],p-float(i));}
    float code(float v){return clamp(round(v),0.0f,255.0f)/255.0f;}
    kernel void compose(array<texture2d<float,access::sample>,16> inputs [[texture(0)]],
      texture2d<float,access::write> oy [[texture(16)]],texture2d<float,access::write> oc [[texture(17)]],
      device const float *f [[buffer(0)]],device const float *inv [[buffer(1)]],
      constant Layer *layers [[buffer(2)]],constant uint &count [[buffer(3)]],uint2 id [[thread_position_in_grid]]) {
        if(id.x>=960 || id.y>=540)return;
        constexpr sampler pixel(coord::pixel,address::clamp_to_edge,filter::linear);
        float sumCb=0,sumCr=0;int chromaIndex[2]={-1,-1};float2 chromaCodes[2];
        for(uint dy=0;dy<2;dy++)for(uint dx=0;dx<2;dx++) {
            float2 at=float2(id*2+uint2(dx,dy))+0.5f;float3 rgb=0;int pure=-1;float pureY=16.0f;float2 pureChroma=128.0f;
            for(uint n=0;n<count;n++) {
                Layer l=layers[n];float2 p=float2(l.m.x*at.x+l.m.z*at.y+l.p.x,l.m.y*at.x+l.m.w*at.y+l.p.y);
                if(p.x<0 || p.y<0 || p.x>=float(inputs[n*2].get_width()) || p.y>=float(inputs[n*2].get_height()))continue;
                if(l.p.z>0.5f){float4 im=inputs[n*2].sample(pixel,p);rgb=im.rgb+(1-im.a)*rgb;if(im.a>0)pure=-1;}
                else {
                    float sourceY=round(inputs[n*2].sample(pixel,p).r*255);float y=(sourceY-16)/219;
                    float2 c=(round(inputs[n*2+1].read(uint2(p)/2).rg*255)-128)/224;
                    rgb=float3(lut(y+1.5748f*c.y,f),lut(y-0.187324f*c.x-0.468124f*c.y,f),lut(y+1.8556f*c.x,f));
                    pure=-1;if(l.m.x==1 && l.m.y==0 && l.m.z==0 && l.m.w==1 && fmod(l.p.x,2.0f)==0 && fmod(l.p.y,2.0f)==0){pure=int(n);pureY=sourceY;pureChroma=round(inputs[n*2+1].read(uint2(p)/2).rg*255);}
                }
            }
            float3 v=float3(lut(rgb.r,inv),lut(rgb.g,inv),lut(rgb.b,inv));float y=dot(v,float3(0.2126f,0.7152f,0.0722f));
            oy.write(float4(pure>=0 ? pureY/255.0f:code(16+219*y),0,0,1),id*2+uint2(dx,dy));
            if(dx==0){chromaIndex[dy]=pure;chromaCodes[dy]=pureChroma;sumCb+=(v.b-y)/1.8556f;sumCr+=(v.r-y)/1.5748f;}
        }
        float2 uv=chromaIndex[0]>=0 && chromaIndex[0]==chromaIndex[1] ? chromaCodes[0]/255.0f:float2(code(128+112*sumCb),code(128+112*sumCr));
        oc.write(float4(uv,0,1),id);
    }
    """
    init() throws {
        guard let d=MTLCreateSystemDefaultDevice(),let q=d.makeCommandQueue() else {throw InternalImagePreview.error("Metal unavailable")}
        device=d;queue=q
        let opts=MTLCompileOptions();opts.mathMode = .safe
        let lib=try d.makeLibrary(source:Self.shader,options:opts)
        guard let fn=lib.makeFunction(name:"compose") else {throw InternalImagePreview.error("Metal kernel")}
        pipeline=try d.makeComputePipelineState(function:fn)
        var c:CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil,nil,d,nil,&c)==kCVReturnSuccess,let c else {throw InternalImagePreview.error("Metal texture cache")};cache=c
        guard let p=CVImageBufferCreateColorSpaceFromAttachments(Self.tags as CFDictionary)?.takeRetainedValue(),let srgb=CGColorSpace(name:CGColorSpace.sRGB) else {throw InternalImagePreview.error("709/sRGB profile")}
        let f=try Self.ramp(from:p,to:srgb),i=try Self.ramp(from:srgb,to:p)
        guard let fb=f.withUnsafeBytes({d.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)}),let ib=i.withUnsafeBytes({d.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)}) else {throw InternalImagePreview.error("ICC LUT allocation")}
        forward=fb;inverse=ib
        let desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:1,height:1,mipmapped:false);desc.storageMode = .shared;desc.usage = .shaderRead
        guard let blank=d.makeTexture(descriptor:desc) else {throw InternalImagePreview.error("empty texture")};dummy=blank
        var zero:UInt32=0;blank.replace(region:MTLRegionMake2D(0,0,1,1),mipmapLevel:0,withBytes:&zero,bytesPerRow:4)
    }
    private static func ramp(from:CGColorSpace,to:CGColorSpace) throws -> [Float] {
        let n=4097;var samples=[UInt16](repeating:65535,count:n*4)
        for k in 0..<n {let v=UInt16((Double(k)*65535/Double(n-1)).rounded());samples[k*4]=v;samples[k*4+1]=v;samples[k*4+2]=v}
        let data=samples.withUnsafeBytes{Data($0)}
        guard let provider=CGDataProvider(data:data as CFData),
              let image=CGImage(width:n,height:1,bitsPerComponent:16,bitsPerPixel:64,bytesPerRow:n*8,space:from,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder16Little.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.relativeColorimetric),
              let c=CGContext(data:nil,width:n,height:1,bitsPerComponent:32,bytesPerRow:n*16,space:to,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.floatComponents.rawValue|CGBitmapInfo.byteOrder32Little.rawValue),let ptr=c.data else {throw InternalImagePreview.error("ICC transfer ramp")}
        c.interpolationQuality = .none;c.draw(image,in:CGRect(x:0,y:0,width:n,height:1))
        let values=ptr.assumingMemoryBound(to:Float.self);return (0..<n).map{values[$0*4]}
    }
    func upload(width:Int,height:Int,bytes:UnsafeRawPointer) throws -> MTLTexture {
        let desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:width,height:height,mipmapped:false);desc.storageMode = .shared;desc.usage = .shaderRead
        guard let t=device.makeTexture(descriptor:desc) else {throw InternalImagePreview.error("image texture budget")}
        t.replace(region:MTLRegionMake2D(0,0,width,height),mipmapLevel:0,withBytes:bytes,bytesPerRow:width*4);return t
    }
    private func views(_ pb:CVPixelBuffer,write:Bool) throws -> ([CVMetalTexture],[MTLTexture]) {
        guard CVPixelBufferGetPixelFormatType(pb)==kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,CVPixelBufferGetPlaneCount(pb)==2 else {throw InternalImagePreview.error("unsupported video pixel format")}
        if !write {
            for (key,value) in Self.tags {guard CVBufferCopyAttachment(pb,key as CFString,nil) as? String==value else {throw InternalImagePreview.error("unsupported video color attachment: \(key)")}}
        }
        var refs=[CVMetalTexture](),textures=[MTLTexture]()
        for plane in 0..<2 {
            var ref:CVMetalTexture?
            let attrs=[kCVMetalTextureUsage:(write ? MTLTextureUsage.shaderWrite:MTLTextureUsage.shaderRead).rawValue] as CFDictionary
            let status=CVMetalTextureCacheCreateTextureFromImage(nil,cache,pb,attrs,plane==0 ? .r8Unorm:.rg8Unorm,CVPixelBufferGetWidthOfPlane(pb,plane),CVPixelBufferGetHeightOfPlane(pb,plane),plane,&ref)
            guard status==kCVReturnSuccess,let ref,let texture=CVMetalTextureGetTexture(ref) else {throw InternalImagePreview.error("NV12 Metal interop")}
            refs.append(ref);textures.append(texture)
        };return(refs,textures)
    }
    private final class GPUResources:@unchecked Sendable {let values:[Any];init(_ values:[Any]){self.values=values}}
    private struct LayerParameters {var m:SIMD4<Float>,p:SIMD4<Float>}
    func render(_ layers:[ImagePreviewInstruction.Layer],source:(CMPersistentTrackID)->CVPixelBuffer?) throws -> CVPixelBuffer {
        lock.lock();let stopped=quarantined;lock.unlock()
        guard !stopped,layers.count<=8 else {throw InternalImagePreview.error("renderer quarantined/full")}
        var pb:CVPixelBuffer?
        guard CVPixelBufferCreate(nil,1920,1080,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,[kCVPixelBufferMetalCompatibilityKey:true,kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&pb)==kCVReturnSuccess,let out=pb else {throw InternalImagePreview.error("NV12 allocation")}
        for (key,value) in Self.tags {CVBufferSetAttachment(out,key as CFString,value as CFTypeRef,.shouldPropagate)}
        let output=try views(out,write:true)
        var textures=[MTLTexture](repeating:dummy,count:16),parameters=[LayerParameters](),resources:[Any]=[out,output,cache,forward,inverse,pipeline,queue,device]
        for (n,l) in layers.enumerated() {
            let a=l.inverse
            parameters.append(.init(m:SIMD4(Float(a.a),Float(a.b),Float(a.c),Float(a.d)),p:SIMD4(Float(a.tx),Float(a.ty),l.image == nil ? 0:1,0)))
            if let image=l.image {textures[n*2]=image;resources.append(image)}
            else {
                guard let id=l.track,let frame=source(id) else {throw InternalImagePreview.error("required visual video source missing")}
                let pair=try views(frame,write:false);textures[n*2]=pair.1[0];textures[n*2+1]=pair.1[1];resources.append(contentsOf:[frame,pair])
            }
        }
        if parameters.isEmpty {parameters.append(.init(m:.zero,p:.zero))}
        guard let cmd=queue.makeCommandBuffer(),let encoder=cmd.makeComputeCommandEncoder() else {throw InternalImagePreview.error("Metal command encoding")}
        encoder.setComputePipelineState(pipeline)
        for (n,t) in textures.enumerated(){encoder.setTexture(t,index:n)}
        encoder.setTexture(output.1[0],index:16);encoder.setTexture(output.1[1],index:17)
        encoder.setBuffer(forward,offset:0,index:0);encoder.setBuffer(inverse,offset:0,index:1)
        parameters.withUnsafeBytes{encoder.setBytes($0.baseAddress!,length:$0.count,index:2)}
        var count=UInt32(layers.count);encoder.setBytes(&count,length:4,index:3)
        encoder.dispatchThreads(MTLSize(width:960,height:540,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:8,depth:1));encoder.endEncoding()
        let done=DispatchSemaphore(value:0)
        // The callback capture, not a timeout or logical cancel, owns retirement.
        let retained=GPUResources(resources)
        Self.ownership.acquire(resources.count)
        cmd.addCompletedHandler{_ in withExtendedLifetime(retained){};Self.ownership.retire(retained.values.count);done.signal()};cmd.commit()
        guard done.wait(timeout:.now()+10) == .success else {lock.lock();quarantined=true;lock.unlock();throw InternalImagePreview.error("GPU completion timeout; retained until observed completion")}
        guard cmd.status == .completed,cmd.error==nil else {throw cmd.error ?? InternalImagePreview.error("GPU command failed")}
        CVMetalTextureCacheFlush(cache,0)
        return out
    }
}
