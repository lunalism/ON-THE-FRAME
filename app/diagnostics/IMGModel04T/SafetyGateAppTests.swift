import AppKit
import ImageIO
@testable import OnTheFrameEngine

/// Standalone executable using the real app sources, not a ProjectStore mock.
@main struct SafetyGateAppTests {
    struct Failure: Error { let message: String }
    @MainActor static func main() async {
        do {
            try check(Thread.isMainThread,"AppKit host initialization requires the main thread")
            let application = NSApplication.shared
            try check(NSApp === application,"AppKit shared application was not installed")
            print("HOST: NSApplication initialized on main thread")
            try await run(); print("APP SAFETY: 5 PASS, 0 FAIL, 0 SKIP"); exit(0)
        }
        catch { print("APP SAFETY FAIL: \(error)"); exit(1) }
    }
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message:message) }
    }
    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath:CommandLine.arguments[1])
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let url = root.appendingPathComponent("generated.png")
        let cg = CGContext(data:nil,width:2,height:2,bitsPerComponent:8,bytesPerRow:8,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
        let dst = CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil)!
        CGImageDestinationAddImage(dst,cg,nil)
        try check(CGImageDestinationFinalize(dst),"fixture")
        let image = try await StillImageProjectModel.ValidatedImage.inspect(url)
        let imageID=UUID()
        let unused=try Timeline().registeringImage(image,id:imageID)
        let operational=try unused.inserting(media:imageID)
        let unsupported=ProductionContent(operational)
        let preview = InteractivePreview()
        var published=0, errors=0, replies:[Bool]=[]
        preview.onItems={_ in published += 1}
        preview.onUnsupported={_ in errors += 1}
        preview.begin(Timeline(),frame:0,media:[:],settings:.m1)
        preview.request(Timeline()) { replies.append($0) }
        try check(published == 1 && replies == [true],"legacy preview")
        print("PASS 1 legacy preview")

        preview.seedSafetyCache(cg)
        try check(preview.safetyCacheCount == 1,"seed")
        preview.begin(operational,frame:0,media:[:],settings:.m1)
        try check(!preview.isActive && errors == 1 && published == 1 && preview.safetyCacheCount == 0,"begin/cache guard")
        print("PASS 2 unsupported begin before decode; cache cleared")

        do { _ = try preview.drawList(unsupported); throw Failure(message:"drawList swallowed error") }
        catch is ProductionContent.Unsupported { }
        try check(errors == 2 && published == 1,"drawList callback")
        try check(preview.drawList(operational) == nil && errors == 3,"legacy drawList must report exactly once")
        print("PASS 3 drawList typed error propagation")

        // Force an asynchronous prefetch task with no source asset. Cancel before it runs.
        // This exercises publication invalidation, not a real AVFoundation decode race.
        let id=UUID(), clip=Clip(mediaID:id,start:0,sourceIn:0,length:1,lane:Lane.videoID)
        let legacy=Timeline(clips:[clip],mediaFrames:[id:1])
        preview.begin(legacy,frame:0,media:[:],settings:.m1)
        var oldReplies:[Bool]=[], newReplies:[Bool]=[]
        preview.request(legacy) { oldReplies.append($0) }
        preview.request(unsupported) { newReplies.append($0) }
        for _ in 0..<5 { await Task.yield() }
        try check(oldReplies == [false] && newReplies == [false] && published == 1 && !preview.isActive,"stale completion")
        preview.request(Timeline()) { newReplies.append($0) }
        try check(newReplies == [false,false] && published == 1,"inactive stale output")
        print("PASS 4 exactly-once pending rejection; stale task cannot publish")

        try check(Thread.isMainThread && NSApp != nil,"ProjectStore requires initialized main-thread AppKit host")
        let store=ProjectStore()
        store.commit({ try $0.renamingLane(Lane.videoID,to:"Generated safety fixture") },focus:nil,rebuild:false)
        try check(store.isDirty && store.timeline != Timeline(),"nondefault valid project fixture")
        let before=store.timeline, saved=store.savedTimeline, projectID=store.projectID
        let bookmarkID=UUID(); store.bookmarks[bookmarkID]=Data([1,2,3])
        let generation=store.generation, undoDepth=store.history.undoDepth
        store.commit({ _ in operational },focus:nil,rebuild:false)
        try check(store.timeline == before && store.projectID == projectID && store.isDirty && store.history.undoDepth == undoDepth,"unsupported commit replaced valid project")
        store.commitLane({ _ in unused })
        try check(store.timeline == before && store.history.undoDepth == undoDepth,"unused image lane commit replaced valid project")
        try check(store.supportedProductionTimeline(ProductionContent(unused)) == nil,"unused operational image admitted")
        store.interactive.seedSafetyCache(cg)
        try check(store.supportedProductionTimeline(unsupported) == nil,"store accepted")
        try check(store.timeline == before && store.savedTimeline == saved && store.projectID == projectID,"project replaced")
        try check(store.bookmarks[bookmarkID] == Data([1,2,3]) && store.generation > generation,"state/generation")
        try check(store.statusMessage?.isEmpty == false && store.interactive.safetyCacheCount == 0,"diagnostic/cache")
        try check(store.supportedProductionTimeline(ProductionContent(before)) == before,"legacy store rejected")
        // Real InteractivePreview callback is connected to the store error path.
        let nextGeneration=store.generation
        try check(!store.interactive.begin(unsupported,frame:0,media:[:],settings:.m1),"store preview admitted")
        try check(store.generation > nextGeneration && store.timeline == before,"callback propagation")
        print("PASS 5 real ProjectStore preserves state and invalidates async generations")
    }
}
