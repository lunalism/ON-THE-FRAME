// SP-4A-04: invoke only with a NEW disposable fixture directory and one case name.
import AVFoundation
import Foundation
import CryptoKit
@testable import OnTheFrameEngine

func demand(_ ok:Bool,_ message:String) throws {if !ok {throw NSError(domain:message,code:1)}}
func sha(_ url:URL) throws -> String {SHA256.hash(data:try Data(contentsOf:url)).map{String(format:"%02x",$0)}.joined()}
final class Signal: @unchecked Sendable {
 let lock=NSLock();private var flag=false;private var pausedFrame:Int?;private var paths:[URL]=[]
 func set(_ frame:Int? = nil) {lock.withLock {flag=true;pausedFrame=frame}}
 var frame:Int? {lock.withLock {pausedFrame}}
 var entered:Bool {lock.withLock {flag}}
 func temp(_ url:URL) {lock.withLock {paths.append(url)}}
 var temps:[URL] {lock.withLock {paths}}
}
actor Hold {
 let signal:Signal;var open=false;var continuation:CheckedContinuation<Void,Never>?
 init(_ signal:Signal) {self.signal=signal}
 func arrive() async {signal.set();if !open {await withCheckedContinuation {continuation=$0}}}
 func release() {open=true;continuation?.resume();continuation=nil}
}
func idle() async throws {
 let deadline=ProcessInfo.processInfo.systemUptime+5
 while !SpectrumExportFrames.isIdleForTest && ProcessInfo.processInfo.systemUptime<deadline {try await Task.sleep(nanoseconds:10_000_000)}
 try demand(SpectrumExportFrames.isIdleForTest,"worker did not drain")
}
// Exercise actual native finish/cancel calls as well as the deterministic export checkpoint.
func nativeFinishRaces(_ root:URL) async throws -> [String:Int] {
 var counts:[String:Int]=[:]
 for index in 0..<12 {
  let writer=try AVAssetWriter(outputURL:root.appendingPathComponent("native-\(index).mp4"),fileType:.mp4)
  let input=AVAssetWriterInput(mediaType:.video,outputSettings:SubtitleExporter.videoSettings)
  let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,kCVPixelBufferWidthKey as String:1920,kCVPixelBufferHeightKey as String:1080])
  writer.add(input);try demand(writer.startWriting(),"native writer start");writer.startSession(atSourceTime:.zero)
  let limit=ProcessInfo.processInfo.systemUptime+3
  while !input.isReadyForMoreMediaData && ProcessInfo.processInfo.systemUptime<limit {try await Task.sleep(nanoseconds:1_000_000)}
  try demand(input.isReadyForMoreMediaData,"native writer ready")
  var buffer:CVPixelBuffer?;try demand(CVPixelBufferPoolCreatePixelBuffer(nil,adaptor.pixelBufferPool!,&buffer)==kCVReturnSuccess,"native buffer")
  let pb=buffer!;CVPixelBufferLockBaseAddress(pb,[])
  for plane in 0..<2 {memset(CVPixelBufferGetBaseAddressOfPlane(pb,plane)!,plane==0 ? 48:128,CVPixelBufferGetBytesPerRowOfPlane(pb,plane)*CVPixelBufferGetHeightOfPlane(pb,plane))}
  CVPixelBufferUnlockBaseAddress(pb,[])
  try demand(adaptor.append(pb,withPresentationTime:.zero),"native append")
  input.markAsFinished();writer.endSession(atSourceTime:CMTime(value:1,timescale:30))
  let box=SubtitleExporter.WriterFinalization(writer:writer)
  switch index%3 {
  case 0:box.cancel();await box.finish();try demand(writer.status == .cancelled,"cancel before finish")
  case 1:
   let finish=Task {await box.finish()};await Task.yield();box.cancel();await finish.value
   try demand(writer.status == .completed || writer.status == .cancelled,"racing terminal status")
  default:await box.finish();box.cancel();try demand(writer.status == .completed,"cancel after completed")
  }
  counts["order\(index%3)-status\(writer.status.rawValue)",default:0]+=1
 }
 return counts
}
@main struct SafetyCheck {
 static func main() async {
 let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true),name=CommandLine.arguments[2]
 var report:[String:Any]=["case":name]
 if name == "native-finish-races" {
  do {
   let dest=root.appendingPathComponent("existing.mp4"),before=try sha(dest)
   report["destinationBefore"]=before;report["races"]=try await nativeFinishRaces(root)
   report["destinationAfter"]=try sha(dest);try demand(try sha(dest)==before,"native race touched destination")
   report["status"]="PASS"
  } catch {report["status"]="FAIL";report["error"]=String(describing:error)}
  try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("result.json"))
  print(name,report["status"]!);exit(report["status"] as? String == "PASS" ? 0:1)
 }
 do {
  let video=root.appendingPathComponent("video.mp4"),wav=root.appendingPathComponent("selected.wav"),dest=root.appendingPathComponent("existing.mp4")
  let project=root.appendingPathComponent("fixture.ontheframe")
  try demand(!FileManager.default.fileExists(atPath:project.path),"requires a fresh disposable directory")
  let v=try await MediaProbe.inspect(video),a=try await MediaProbe.inspect(wav),media=[v.id:v,a.id:a]
  let sl=UUID(),tl=UUID(),ac=Clip(mediaID:a.id,start:0,sourceIn:30,length:360,lane:Lane.audioID)
  var style=SpectrumItemStyle.provisionalDefault;style.sides = .above;style.startYMilli=600000;style.endYMilli=600000;style.maxHeightMilli=420000;style.red=255;style.green=195;style.blue=50;style.alpha=192
  var subStyle=SubtitleStyle.default;subStyle.yMilli=500000;subStyle.sizeTenths=640
  let subs=(0..<3).map {SubtitleItem(lane:tl,start:$0*120,length:120,text:["SLOW","FAST","MEDIUM"][$0],style:subStyle)}
  let sp=SpectrumItem(lane:sl,start:0,length:360,sourceKey:ac.lineageKey,style:style)
  let timeline=Timeline(clips:[Clip(mediaID:v.id,start:0,sourceIn:0,length:360,lane:Lane.videoID)],audioClips:[ac],subtitles:subs,spectra:[sp],lanes:[Lane(id:tl,kind:.subtitle,name:"Sub"),Lane(id:sl,kind:.spectrum,name:"SP")]+Lane.defaults,media:[MediaRef(v),MediaRef(a)],mediaFrames:[v.id:v.frameCount,a.id:a.frameCount],mediaHasAudio:[v.id:v.hasAudio,a.id:a.hasAudio],durationFrames:360)
  try ProjectFile.encode(timeline,projectID:UUID(),settings:.m1,bookmarks:[:],projectURL:project).write(to:project)
  let before=try sha(dest),sourceHash=try sha(wav),videoHash=try sha(video),projectHash=try sha(project)
  report["destinationBefore"]=before
  try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("before.json"))
  let signal=Signal(),temps=Signal();let hold=Hold(signal)
  let checkpoint:SpectrumExportCheckpoint?
  switch name {
  case "cancel-before-finalization":checkpoint = .beforeFinalization
  case "cancel-finalization-pending":checkpoint = .finalizationPending
  case "cancel-after-finalization":checkpoint = .afterFinalization
  case "cancel-promotion-preparation","replace-before-promotion":checkpoint = .promotionPreparation
  case "cancel-after-promotion":checkpoint = .promoted
  case "replace-processing","disappear-processing":checkpoint = .framePreparation(8)
  case "replace-pending-fft":checkpoint = .analysis(8)
  case "analysis-stall","cancel-analysis-stall","cancel-analysis-stall-retry":checkpoint = .analysis(0)
  case "frame-stall":checkpoint = .framePreparation(0)
  case "writer-stall","cancel-writer-stall","writer-stall-after-progress","cancel-writer-stall-after-progress","replace-before-preparation","disappear-before-preparation","source-destination":checkpoint=nil
  default:throw NSError(domain:"unknown case",code:1)
  }
  let isStall=name.contains("stall"),isWriter=name.contains("writer-stall")
  var controls=SpectrumExportControls(stepTimeout:isStall && !isWriter ? 0.1:10,jobTimeout:isWriter ? (name.hasSuffix("after-progress") ? 2:1):120)
  controls.checkpoint={point in if point==checkpoint {await hold.arrive()}}
  if isWriter {controls.pausesWriter={frame in
   if name.hasSuffix("after-progress") && frame<8 {return false}
   signal.set(frame);return true
  }}
  let displaced=root.appendingPathComponent("original-preserved.wav")
  func changeSource() throws {
   try FileManager.default.moveItem(at:wav,to:displaced)
   if name.hasPrefix("replace") {try FileManager.default.copyItem(at:displaced,to:wav)}
  }
  func restoreSource() throws {
   if FileManager.default.fileExists(atPath:displaced.path) {
    if FileManager.default.fileExists(atPath:wav.path) {try FileManager.default.moveItem(at:wav,to:root.appendingPathComponent("replacement-preserved.wav"))}
    try FileManager.default.moveItem(at:displaced,to:wav)
   }
  }
  if name.hasSuffix("before-preparation") {try changeSource()}
  let destination=name == "source-destination" ? wav:dest
  let task=Task {await ExportService.exportSpectrumSlice(timeline,media:media,enabled:true,to:.fromSavePanel(destination),controls:controls,options:.init(onTempDirectory:{url in temps.temp(url);try? Data(url.path.utf8).write(to:root.appendingPathComponent("owned-temp-path.txt"))}))}
  if checkpoint != nil || isWriter {
   let deadline=ProcessInfo.processInfo.systemUptime+100
   while !signal.entered && ProcessInfo.processInfo.systemUptime<deadline {try await Task.sleep(nanoseconds:5_000_000)}
   try demand(signal.entered,"checkpoint was not reached")
  }
  if let paused=signal.frame {report["writerPauseFrame"]=paused}
  let transitionStart=ProcessInfo.processInfo.systemUptime
  if name.hasPrefix("cancel") {task.cancel()}
  if name=="replace-processing" || name=="disappear-processing" || name=="replace-pending-fft" || name=="replace-before-promotion" {try changeSource()}
  // For analysis/frame stalls keep the non-cooperative worker pending through the outcome.
  if !isStall {await hold.release()}
  let result=await task.value
  report["outcome"]=String(describing:result);report["transitionSeconds"]=ProcessInfo.processInfo.systemUptime-transitionStart
  report["destinationAfter"]=try sha(dest);report["temps"]=temps.temps.map(\.lastPathComponent)
  if isStall && !isWriter {
   report["slotHeldUntilDrain"] = !SpectrumExportFrames.isIdleForTest
   try demand(!SpectrumExportFrames.isIdleForTest,"slot released while worker pending")
   let refused=await ExportService.exportSpectrumSlice(timeline,media:media,enabled:true,to:.fromSavePanel(dest),controls:.init(stepTimeout:10,jobTimeout:120))
   if case .failed = refused {} else {throw NSError(domain:"overlapping retry accepted",code:1)}
   report["retryWhileDraining"]=String(describing:refused)
  }
  await hold.release();try await idle();try restoreSource()
  if name=="cancel-after-promotion" {try demand(result == .completed(dest),"irreversible promotion must remain completed")}
  else {
   try demand(try sha(dest)==before,"destination changed on failure/cancellation")
   if name.hasPrefix("cancel") {try demand(result == .cancelled,"cancellation not acknowledged")}
   else {if case .failed = result {} else {throw NSError(domain:"failure not reported",code:1)}}
  }
  if isStall {try demand(ProcessInfo.processInfo.systemUptime-transitionStart<3,"stall transition exceeded bound")}
  for url in temps.temps {try demand(!FileManager.default.fileExists(atPath:url.path),"owned temp remained")}
  try demand(try sha(wav)==sourceHash && sha(video)==videoHash && sha(project)==projectHash,"fixture not restored")
  try demand(FileIdentity.of(wav)==a.identity,"original source identity not restored")
  if name == "cancel-analysis-stall-retry" {
   let retryURL=root.appendingPathComponent("retry.mp4")
   let retry=await ExportService.exportSpectrumSlice(timeline,media:media,enabled:true,to:.fromSavePanel(retryURL),controls:.init(stepTimeout:10,jobTimeout:120),options:.init(onTempDirectory:{temps.temp($0)}))
   try demand(retry == .completed(retryURL),"retry after drain failed")
   let asset=AVURLAsset(url:retryURL),reader=try AVAssetReader(asset:asset)
   let track=try await asset.loadTracks(withMediaType:.video)[0]
   let output=AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
   reader.add(output);try demand(reader.startReading(),"retry reader start")
   var count=0
   while let sample=output.copyNextSampleBuffer() {try demand(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample),CMTime(value:Int64(count),timescale:30))==0,"retry PTS");count+=1}
   try demand(count==360 && reader.status == .completed,"retry full decode")
   try await idle()
   for url in temps.temps {try demand(!FileManager.default.fileExists(atPath:url.path),"retry temp remained")}
   try demand(try sha(dest)==before,"retry touched previous output")
   report["retryFrames"]=count;report["retryOutcome"]=String(describing:retry)
  }
  report["workerIdle"]=true;report["temporaryDirectoriesRemoved"]=temps.temps.count;report["sourceRestored"]=true;report["status"]="PASS"
 } catch {report["status"]="FAIL";report["error"]=String(describing:error)}
 try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("result.json"))
 print(name,report["status"]!,report["error"] ?? "")
 exit(report["status"] as? String == "PASS" ? 0:1)
 }
}
