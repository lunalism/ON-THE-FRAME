// SP-4A-01 generated-media integration check. See docs/diagnostics/SP-4A-01-SPECTRUM-EXPORT.md.
import AVFoundation
import CoreGraphics
import Foundation
import CryptoKit
@testable import OnTheFrameEngine

func require(_ ok: Bool, _ message: String) throws { if !ok { throw NSError(domain: message, code: 1) } }
func waitIdle() async throws {
 let end=Date().addingTimeInterval(5)
 while !SpectrumExportFrames.isIdleForTest && Date()<end {try await Task.sleep(nanoseconds:10_000_000)}
 try require(SpectrumExportFrames.isIdleForTest,"previous worker drained and scopes released")
}
func digest(_ u: URL) throws -> String { SHA256.hash(data: try Data(contentsOf:u)).map { String(format:"%02x",$0) }.joined() }
let samples: Set<Int> = [0,1,30,60,119,120,121,150,180,239,240,241,270,300,359]
func plane(_ pb: CVPixelBuffer, _ index: Int = 0) -> [UInt8] {
 CVPixelBufferLockBaseAddress(pb,.readOnly); defer { CVPixelBufferUnlockBaseAddress(pb,.readOnly) }
 let b=CVPixelBufferGetBaseAddressOfPlane(pb,index)!.assumingMemoryBound(to:UInt8.self), stride=CVPixelBufferGetBytesPerRowOfPlane(pb,index)
 let height = index == 0 ? 1080 : 540
 var a=[UInt8](repeating:0,count:1920*height)
 for y in 0..<height { _ = a.withUnsafeMutableBufferPointer { memcpy($0.baseAddress!+y*1920,b+y*stride,1920) } }
 return a
}
final class TempCapture: @unchecked Sendable {
 let lock=NSLock(); var urls:[URL]=[]
 func add(_ url:URL) { lock.withLock {urls.append(url)} }
 func verify() throws { try lock.withLock { for url in urls {try require(!FileManager.default.fileExists(atPath:url.path),"temporary output removed: \(url.path)")} } }
}
final class Capture: @unchecked Sendable {
 let lock=NSLock();var bands:[Int:[Float]]=[:], rasters:[Int:SpectrumRenderedFrame]=[:], luma:[Int:[UInt8]]=[:], base:[Int:[UInt8]]=[:];var chroma:[Int:[UInt8]]=[:];var frames:[Int]=[],peakPCM=0
 func prepared(_ k:Int,_ b:[Float],_ r:SpectrumRenderedFrame?,_ bytes:Int) { lock.withLock { frames.append(k);peakPCM=max(peakPCM,bytes);if samples.contains(k) {bands[k]=b;rasters[k]=r} } }
 func composed(_ k:Int,_ src:CVPixelBuffer,_ out:CVPixelBuffer) { if samples.contains(k) {let a=plane(src),b=plane(out);lock.withLock {base[k]=a;luma[k]=b;chroma[k]=plane(out,1)}} }
}
func generate(_ url:URL) async throws {
 let writer=try AVAssetWriter(outputURL:url,fileType:.mp4)
 let input=AVAssetWriterInput(mediaType:.video,outputSettings:SubtitleExporter.videoSettings)
 let ad=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,kCVPixelBufferWidthKey as String:1920,kCVPixelBufferHeightKey as String:1080])
 writer.add(input);try require(writer.startWriting(),"fixture writer start");writer.startSession(atSourceTime:.zero)
 for k in 0..<360 {
  while !input.isReadyForMoreMediaData {try await Task.sleep(nanoseconds:1_000_000)}
  var b:CVPixelBuffer?;CVPixelBufferPoolCreatePixelBuffer(nil,ad.pixelBufferPool!,&b);let pb=b!
  CVPixelBufferLockBaseAddress(pb,[])
  for p in 0..<2 { let ptr=CVPixelBufferGetBaseAddressOfPlane(pb,p)!;memset(ptr,p==0 ? 48:128,CVPixelBufferGetBytesPerRowOfPlane(pb,p)*CVPixelBufferGetHeightOfPlane(pb,p)) }
  let ptr=CVPixelBufferGetBaseAddressOfPlane(pb,0)!.assumingMemoryBound(to:UInt8.self), stride=CVPixelBufferGetBytesPerRowOfPlane(pb,0)
  for bit in 0..<9 {for y in 40..<80 { for x in (40+bit*40)..<(70+bit*40) {ptr[y*stride+x]=(k&(1<<bit)) != 0 ? 220:70} }}
  CVPixelBufferUnlockBaseAddress(pb,[])
  try require(ad.append(pb,withPresentationTime:CMTime(value:Int64(k),timescale:30)),"fixture append")
 }
 input.markAsFinished();writer.endSession(atSourceTime:CMTime(value:12,timescale:1));await writer.finishWriting();try require(writer.status == .completed,"fixture finish")
}
func decodeAudio(_ asset:AVAsset, mix:AVAudioMix?=nil) async throws -> [Float] {
 let r=try AVAssetReader(asset:asset);let tracks=try await asset.loadTracks(withMediaType:.audio)
 let o=AVAssetReaderAudioMixOutput(audioTracks:tracks,audioSettings:SubtitleExporter.pcmSettings);o.audioMix=mix;r.add(o);try require(r.startReading(),"audio start")
 var pcm:[Float]=[]
 while let sb=o.copyNextSampleBuffer() {
  guard let block=CMSampleBufferGetDataBuffer(sb) else {throw NSError(domain:"PCM block",code:1)}
  let n=CMBlockBufferGetDataLength(block);var bytes=[UInt8](repeating:0,count:n)
  CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:n,destination:&bytes)
  bytes.withUnsafeBytes {raw in pcm.append(contentsOf:raw.bindMemory(to:Float.self))}
 }
 try require(r.status == .completed,"audio full decode");return pcm
}
@main struct Harness {
 static func main() async {
 let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
 var report:[String:Any]=[:]
 do {
  let video=root.appendingPathComponent("video.mp4"), wav=root.appendingPathComponent("selected.wav")
  if !FileManager.default.fileExists(atPath:video.path) {try await generate(video)}
  let v=try await MediaProbe.inspect(video),a=try await MediaProbe.inspect(wav);let media=[v.id:v,a.id:a]
  let sl=UUID(),tl=UUID(),ac=Clip(mediaID:a.id,start:0,sourceIn:30,length:360,lane:Lane.audioID)
  var style=SpectrumItemStyle.provisionalDefault;style.sides = .above;style.startYMilli=600000;style.endYMilli=600000;style.maxHeightMilli=420000;style.red=255;style.green=195;style.blue=50;style.alpha=192
  var subStyle=SubtitleStyle.default;subStyle.yMilli=500000;subStyle.sizeTenths=640
  let subs=(0..<3).map {SubtitleItem(lane:tl,start:$0*120,length:120,text:["SLOW","FAST","MEDIUM"][$0],style:subStyle)}
  let sp=SpectrumItem(lane:sl,start:0,length:360,sourceKey:ac.lineageKey,style:style)
  let t=Timeline(clips:[Clip(mediaID:v.id,start:0,sourceIn:0,length:360,lane:Lane.videoID)],audioClips:[ac],subtitles:subs,spectra:[sp],lanes:[Lane(id:tl,kind:.subtitle,name:"Sub"),Lane(id:sl,kind:.spectrum,name:"SP")]+Lane.defaults,media:[MediaRef(v),MediaRef(a)],mediaFrames:[v.id:v.frameCount,a.id:a.frameCount],mediaHasAudio:[v.id:v.hasAudio,a.id:a.hasAudio],durationFrames:360)
  try require(t.isValid,"timeline valid")
  let project=root.appendingPathComponent("fixture.ontheframe");try ProjectFile.encode(t,projectID:UUID(),settings:.m1,bookmarks:[:],projectURL:project).write(to:project)
  let identities=[video:try digest(video),wav:try digest(wav),project:try digest(project)]
  let plan=try await CompositionPlanner.plan(t,media:media,settings:.m1)
  let gate=root.appendingPathComponent("gate.mp4")
  let denied=await ExportService.export(plan,to:.fromSavePanel(gate),sources:Array(media.values),progress:{_ in})
  if case .failed = denied {} else {throw NSError(domain:"normal spectrum gate",code:1)}
  try require(!FileManager.default.fileExists(atPath:gate.path),"normal spectrum remains gated");report["normalGate"]=String(describing:denied)
  let controls=SpectrumExportControls(stepTimeout:10,jobTimeout:120)
  let off=await ExportService.exportSpectrumSlice(t,media:media,enabled:false,to:.fromSavePanel(gate),controls:controls)
  if case .failed = off {} else {throw NSError(domain:"disabled spectrum gate",code:1)}
  try require(!FileManager.default.fileExists(atPath:gate.path),"internal disabled gate");report["disabledGate"]=String(describing:off)
  let noSource=try t.settingSpectrumSource(sp.id,nil)
  for unsupported in [noSource,t.rebuilt(video:[]),t.rebuilt(spectra:[sp,sp.with(id:UUID())])] {
   let rejected=await ExportService.exportSpectrumSlice(unsupported,media:media,enabled:true,to:.fromSavePanel(gate),controls:controls)
   if case .failed = rejected {} else {throw NSError(domain:"unsupported route accepted",code:1)}
   try require(!FileManager.default.fileExists(atPath:gate.path),"unsupported route touched target")
  }
  let imageOff=await ExportService.exportImages(t,media:media,enabled:false,to:.fromSavePanel(gate),progress:{_ in})
  if case .failed = imageOff {} else {throw NSError(domain:"image gate changed",code:1)}
  report["unsupportedGates"]="missing source, pure audio, multiple spectra, image gate off rejected"
  let cap=Capture();var captureControls=controls;captureControls.prepared={cap.prepared($0,$1,$2,$3)};captureControls.composed={cap.composed($0,$1,$2)}
  let output=root.appendingPathComponent("spectrum.mp4")
  let result=await ExportService.exportSpectrumSlice(t,media:media,enabled:true,to:.fromSavePanel(output),controls:captureControls)
  report["export"]=String(describing:result);try require(result == .completed(output),"spectrum export completion")
  try require(cap.frames == Array(0..<360),"prepared exact ordered frames");report["peakPCMBytes"]=cap.peakPCM
  let outAsset=AVURLAsset(url:output);let tracks=try await outAsset.loadTracks(withMediaType:.video);let audioTracks=try await outAsset.loadTracks(withMediaType:.audio)
  try require(tracks.count==1 && audioTracks.count==1,"output tracks")
  let fd=try await tracks[0].load(.formatDescriptions)[0];try require(CMFormatDescriptionGetMediaSubType(fd)==kCMVideoCodecType_H264,"H264")
  let dimensions=CMVideoFormatDescriptionGetDimensions(fd);try require(dimensions.width==1920 && dimensions.height==1080,"FHD")
  let afd=try await audioTracks[0].load(.formatDescriptions)[0];try require(CMFormatDescriptionGetMediaSubType(afd)==kAudioFormatMPEG4AAC,"AAC")
  let r=try AVAssetReader(asset:outAsset),o=AVAssetReaderTrackOutput(track:tracks[0],outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]);r.add(o);try require(r.startReading(),"video decode start")
  var k=0,maxMean=0.0;var pts:[Double]=[]
  while let sb=o.copyNextSampleBuffer() {
   let time=CMSampleBufferGetPresentationTimeStamp(sb);try require(CMTimeCompare(time,CMTime(value:Int64(k),timescale:30))==0,"ordered exact PTS \(k)");pts.append(time.seconds)
   let pb=CMSampleBufferGetImageBuffer(sb)!,l=plane(pb)
   for bit in 0..<9 {try require(abs(Int(l[60*1920+55+bit*40])-((k&(1<<bit)) != 0 ? 220:70))<=6,"video marker \(k)")}
   if let expected=cap.luma[k] {let mean=zip(l,expected).reduce(0.0){$0+Double(abs(Int($1.0)-Int($1.1)))}/Double(l.count);maxMean=max(maxMean,mean);try require(mean<2,"decoded composite mean \(k)")}
   k+=1
  }
  try require(r.status == .completed && k==360,"full video decode 360")
  let duration=try await tracks[0].load(.timeRange).duration;try require(CMTimeCompare(duration,CMTime(value:12,timescale:1))==0,"duration12")
  report["frames"]=k;report["pts"]=pts;report["maxDecodedLumaMAE"]=maxMean
  // Independent luma blend of spectrum then subtitle, using their premultiplied rasters.
  var maxBlendError=0,maxChromaError=0,overlapPixels=0,inkPixels=0
  for f in samples {
   var expected=cap.base[f]!.map(Double.init)
   var expectedChroma=[Double](repeating:128,count:1920*540)
   func blend(_ image:CGImage,_ rect:CGRect,_ spectrum:Bool) {
    let data=image.dataProvider!.data! as Data
    data.withUnsafeBytes {raw in let p=raw.bindMemory(to:UInt8.self)
     for y in 0..<image.height {for x in 0..<image.width {
      let fx=Int(rect.minX)+x,fy=Int(rect.minY)+y;guard fx>=0 && fx<1920 && fy>=0 && fy<1080 else {continue}
      let i=y*image.bytesPerRow+x*4,alpha=Double(p[i+3])/255;guard alpha>0 else {continue};let q=fy*1920+fx
      if !spectrum && abs(expected[q]-Double(cap.base[f]![q]))>5 {overlapPixels+=1}
      if spectrum {inkPixels+=1}
      let yp=(0.2126*Double(p[i+2])+0.7152*Double(p[i+1])+0.0722*Double(p[i]))/255
      expected[q]=(expected[q]*(1-alpha)+16*alpha+219*yp).rounded()
     }}
     // Independent direct six-tap chroma reference; no production footprint tables.
     let x0=Int(rect.minX),y0=Int(rect.minY)
     let left=max(0,(x0-2)/2),right=min(959,(x0+image.width+2)/2)
     let top=max(0,(y0-2)/2),bottom=min(539,(y0+image.height+2)/2)
     if left<=right && top<=bottom {for cy in top...bottom {for cx in left...right {
      var alpha=0.0,cb=0.0,cr=0.0
      for dy in 0...1 {for dx in -1...1 {
       let x=cx*2+dx-x0,y=cy*2+dy-y0
       guard x>=0 && x<image.width && y>=0 && y<image.height else {continue}
       let i=y*image.bytesPerRow+x*4,w=dx==0 ? 0.25:0.125
       let a=Double(p[i+3])/255,r=Double(p[i+2])/255,g=Double(p[i+1])/255,b=Double(p[i])/255
       let luminance=0.2126*r+0.7152*g+0.0722*b
       alpha+=w*a;cb+=w*(128*a+224*(b-luminance)/1.8556);cr+=w*(128*a+224*(r-luminance)/1.5748)
      }}
      let q=cy*1920+cx*2
      expectedChroma[q]=(expectedChroma[q]*(1-alpha)+cb).rounded()
      expectedChroma[q+1]=(expectedChroma[q+1]*(1-alpha)+cr).rounded()
     }}}
    }
   }
   if let raster=cap.rasters[f] {blend(raster.image,raster.drawRect,true)}
   for sub in subs where sub.visible(atFrame:f) {let raster=SubtitleRenderer.shared.raster(sub);blend(raster.image,raster.drawRect,false)}
   for (a,b) in zip(expected,cap.luma[f]!) {maxBlendError=max(maxBlendError,abs(Int(a)-Int(b)))}
   for (a,b) in zip(expectedChroma,cap.chroma[f]!) {maxChromaError=max(maxChromaError,abs(Int(a)-Int(b)))}
  }
  try require(maxBlendError<=1 && maxChromaError<=1 && overlapPixels>0 && inkPixels>0,"spectrum alpha and subtitle priority")
  report["chromaBlendMaxError"]=maxChromaError;report["lumaBlendMaxError"]=maxBlendError;report["subtitleSpectrumOverlapPixels"]=overlapPixels;report["spectrumInkPixels"]=inkPixels;report["bands"]=Dictionary(uniqueKeysWithValues:cap.bands.map{(String($0.key),$0.value)})
  let pcm=try await decodeAudio(plan.composition,mix:plan.audioMix),aac=try await decodeAudio(outAsset)
  let raw=try Data(contentsOf:wav);let wavPCM=raw.dropFirst(44).withUnsafeBytes {Array($0.bindMemory(to:Int16.self))}
  try require(pcm.count==576000*2,"preencode PCM length")
  var maxPCM=0.0
  for i in pcm.indices {maxPCM=max(maxPCM,abs(Double(pcm[i])-Double(wavPCM[i+48000*2])/32768))}
  try require(maxPCM<0.0001,"trimmed source PCM alignment")
  try require(abs(aac.count-pcm.count)<=2048*2,"AAC length tolerance")
  var rmsError=0.0
  for f in 0..<360 {let range=(f*3200)..<((f+1)*3200);if range.upperBound>aac.count {break};let x=sqrt(range.reduce(0.0){$0+Double(pcm[$1]*pcm[$1])}/3200),y=sqrt(range.reduce(0.0){$0+Double(aac[$1]*aac[$1])}/3200);rmsError=max(rmsError,abs(x-y))}
  try require(rmsError<0.02,"AAC frame RMS alignment")
  report["preencodeMaxPCMError"]=maxPCM;report["AACSampleValues"]=aac.count;report["AACMaxFrameRMSError"]=rmsError
  try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("pre-safety.json"))
  // Existing no-spectrum reader/writer route.
  var plain=plan;plain.spectra=[];let normal=root.appendingPathComponent("normal.mp4")
  let normalResult=await ExportService.export(plain,to:.fromSavePanel(normal),sources:Array(media.values),progress:{_ in});try require(normalResult == .completed(normal),"non-spectrum regression");report["normalExport"]=String(describing:normalResult)
  let normalAsset=AVURLAsset(url:normal)
  let nr=try AVAssetReader(asset:normalAsset)
  let nt=try await normalAsset.loadTracks(withMediaType:.video)[0]
  let no=AVAssetReaderTrackOutput(track:nt,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]);nr.add(no);try require(nr.startReading(),"normal decode")
  var nk=0
  while let sb=no.copyNextSampleBuffer() {try require(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sb),CMTime(value:Int64(nk),timescale:30))==0,"normal PTS");nk+=1}
  try require(nk==360 && nr.status == .completed,"normal full decode");report["normalFrames"]=nk
  // All failure cases start with the same existing successful output; no replacement before success.
  let original=try digest(output)
  let temps=TempCapture()
  var safety:[String:String]=[:]
  let failed=await ExportService.exportSpectrumSlice(t,media:media,enabled:true,to:.fromSavePanel(output),controls:controls,options:.init(failAfterFraction:0.1,onTempDirectory:{temps.add($0)}))
  try require(try digest(output)==original,"injected failure output preservation");safety["injectedWriteFailure"]=String(describing:failed)
  if case .failed = failed {} else { throw NSError(domain:"expected injected failure",code:1) }
  report["postFailureStillDraining"] = !SpectrumExportFrames.isIdleForTest
  try await waitIdle()
  let cancel=Task {await ExportService.exportSpectrumSlice(t,media:media,enabled:true,to:.fromSavePanel(output),controls:controls,options:.init(onTempDirectory:{temps.add($0)}))}
  try await Task.sleep(nanoseconds:150_000_000);cancel.cancel();let cancelled=await cancel.value
  report["cancelOutcome"]=String(describing:cancelled);report["cancelPreserved"]=(try digest(output))==original
  try require(cancelled == .cancelled && (try digest(output))==original,"cancel output protection");safety["cancel"]=String(describing:cancelled)
  try await waitIdle()
  var slow=SpectrumExportControls(stepTimeout:0.1,jobTimeout:120);slow.prepared={k,_,_,_ in if k==0 {Thread.sleep(forTimeInterval:0.3)}}
  let timed=await ExportService.exportSpectrumSlice(t,media:media,enabled:true,to:.fromSavePanel(output),controls:slow,options:.init(onTempDirectory:{temps.add($0)}))
  try require((try digest(output))==original,"timeout output protection");safety["timeout"]=String(describing:timed)
  report["timeoutOutcome"]=String(describing:timed)
  if case .failed = timed {} else { throw NSError(domain:"expected timeout failure",code:1) }
  try await waitIdle()
  let race=root.appendingPathComponent("promotion-race.mp4")
  let promote=await ExportService.exportSpectrumSlice(t,media:media,enabled:true,to:.fromSavePanel(race),controls:controls,options:.init(beforePromotion:{try? Data("sentinel".utf8).write(to:race)},onTempDirectory:{temps.add($0)}))
  try require(try Data(contentsOf:race)==Data("sentinel".utf8),"promotion race protection");safety["promotionFailure"]=String(describing:promote)
  if case .failed = promote {} else { throw NSError(domain:"expected promotion failure",code:1) }
  try await waitIdle()
  let actualWrite=await ExportService.exportSpectrumSlice(t,media:media,enabled:true,to:.fromSavePanel(output),controls:controls,options:.init(onTempDirectory:{temps.add($0);try? FileManager.default.createDirectory(at:$0.appendingPathComponent("output.mp4"),withIntermediateDirectories:false)}))
  try require((try digest(output))==original,"writer initialization failure protection");safety["writerFailure"]=String(describing:actualWrite)
  if case .failed = actualWrite {} else { throw NSError(domain:"expected writer failure",code:1) }
  try await waitIdle()
  let displaced=root.appendingPathComponent("temporarily-missing.wav")
  try FileManager.default.moveItem(at:wav,to:displaced)
  let missing=await ExportService.exportSpectrumSlice(t,media:media,enabled:true,to:.fromSavePanel(output),controls:controls)
  try FileManager.default.moveItem(at:displaced,to:wav)
  if case .failed = missing {} else { throw NSError(domain:"expected invalid source failure",code:1) }
  try require((try digest(output))==original,"invalid source preserved output");safety["invalidSource"]=String(describing:missing)
  try await waitIdle()
  for (u,h) in identities {try require(try digest(u)==h,"fixture identity unchanged")}
  try temps.verify(); report["temporaryDirectoriesRemoved"]=temps.urls.count
  report["safety"]=safety;report["status"]="PASS";report["outputSHA256"]=original
 } catch {report["status"]="FAIL";report["error"]=String(describing:error)}
 try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("result.json"))
 print(report["status"]!,report["error"] ?? "");exit(report["status"] as? String == "PASS" ? 0:1)
 }
}
