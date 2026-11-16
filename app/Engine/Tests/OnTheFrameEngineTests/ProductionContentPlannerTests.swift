import XCTest
import AVFoundation
@testable import OnTheFrameEngine

final class ProductionContentPlannerTests: XCTestCase {
    func testTemporalStackCullingAndSourceOffsetsRemainUnchanged() throws {
        let id = UUID(), upper = UUID()
        let asset = MediaAsset(id:id,url:URL(fileURLWithPath:"/generated/video.mp4"),name:"video",frameCount:300,
            timing:SourceTiming(sampleCount:300,isVariable:false,frameDurationValue:1,frameDurationTimescale:30,averageFPS:30,minInterval:1.0/30,maxInterval:1.0/30),
            naturalSize:CGSize(width:1920,height:1080),displaySize:CGSize(width:1920,height:1080),preferredTransform:.identity,
            hasAudio:false,codec:"avc1",identity:FileIdentity(device:1,inode:1,size:100,modifiedNs:1))
        let top=Lane(id:upper,kind:.video,name:"top")
        let a=Clip(mediaID:id,start:0,sourceIn:7,length:20,lane:upper)
        // A missing lower source is safely culled for legacy video. Image adapters reject first.
        let b=Clip(mediaID:UUID(),start:0,sourceIn:0,length:10,lane:Lane.videoID)
        let t=Timeline(clips:[a,b],lanes:[top]+Lane.defaults,media:[MediaRef(asset)],mediaFrames:[id:300])
        let size=CGSize(width:1920,height:1080), content=ProductionContent(t)
        XCTAssertEqual(try CompositionPlanner.layerStack(content,from:0,to:10,media:[id:asset],render:size),[a])
        let segments=try CompositionPlanner.layeredSegments(content,media:[id:asset],render:size)
        XCTAssertEqual(segments,try CompositionPlanner.layeredSegments(t,media:[id:asset],render:size))
        XCTAssertEqual(segments.count,1)
        XCTAssertEqual(segments[0].layers[0].sourceIn,7)
        XCTAssertEqual(segments[0].end,20)
    }
}
