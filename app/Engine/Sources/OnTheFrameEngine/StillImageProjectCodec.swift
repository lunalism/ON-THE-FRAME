import Foundation

extension StillImageDescriptor.Encoding: Codable {}

/// Internal opt-in codec. Production ProjectFile.currentVersion remains 8.
enum StillImageProjectCodec {
    typealias Model = StillImageProjectModel
    private struct Entry: Codable {
        var ref: Reference
        var relativePath: String?
        var bookmark: Data?
    }
    private struct Reference: Codable {
        let value: Model.MediaReference
        struct Key: CodingKey {
            let stringValue: String
            let intValue: Int? = nil
            init(_ s: String) { stringValue=s }
            init?(stringValue: String) { self.init(stringValue) }
            init?(intValue: Int) { return nil }
        }
        init(_ value: Model.MediaReference) { self.value=value }
        init(from decoder: Decoder) throws {
            let c=try decoder.container(keyedBy:Key.self)
            let kind=try c.decode(Model.MediaKind.self,forKey:Key("kind"))
            let common:Set<String>=["id","name","path","size","modifiedNs","kind"]
            let temporal:Set<String>=["frameCount","hasAudio","codec","width","height","hasVideo","sampleRate","sampleCount","channels"]
            let allowed=kind == .stillImage ? common.union(["image"]) : common.union(temporal)
            try Model.require(Set(c.allKeys.map(\.stringValue)).isSubset(of:allowed), "contradictory/unknown media fields")
            if kind == .stillImage {
                let imageDecoder=try c.superDecoder(forKey:Key("image"))
                let imageKeys=try imageDecoder.container(keyedBy:Key.self)
                let allowedImage:Set<String>=["contractVersion","encoding","width","height","orientation","componentBitDepth","encodedSampleBitDepth","colorModel","profileDisposition","profileSHA256","alphaCapability"]
                try Model.require(Set(imageKeys.allKeys.map(\.stringValue)).isSubset(of:allowedImage), "image temporal/private fields")
                let info=try Model.ImageInfo(from:imageDecoder)
                value = .stillImage(.init(id:try c.decode(UUID.self,forKey:Key("id")),name:try c.decode(String.self,forKey:Key("name")),path:try c.decode(String.self,forKey:Key("path")),size:try c.decode(Int64.self,forKey:Key("size")),modifiedNs:try c.decode(Int64.self,forKey:Key("modifiedNs")),image:info))
            } else {
                _ = try c.decode(Bool.self,forKey:Key("hasVideo"))
                let r=try MediaRef(from:decoder)
                value = kind == .video ? .video(r) : .audio(r)
            }
        }
        func encode(to encoder: Encoder) throws {
            var c=encoder.container(keyedBy:Key.self)
            try c.encode(value.kind,forKey:Key("kind"))
            if let r=value.temporal { try r.encode(to:encoder) }
            else if let r=value.still {
                try c.encode(r.id,forKey:Key("id"));try c.encode(r.name,forKey:Key("name"));try c.encode(r.path,forKey:Key("path"))
                try c.encode(r.size,forKey:Key("size"));try c.encode(r.modifiedNs,forKey:Key("modifiedNs"));try c.encode(r.image,forKey:Key("image"))
            }
        }
    }
    private struct Document: Codable {
        let format: String
        let version: Int
        let projectID: UUID
        let settings: ProjectFile.Settings
        let durationFrames: Int
        let lanes: [Lane]
        let media: [Entry]
        let videoClips: [Clip]
        let audioClips: [Clip]
        let subtitles: [SubtitleItem]?
        let spectra: [SpectrumItem]?
        init(_ p: Model.Project, projectURL: URL?) {
            format=ProjectFile.format;version=9;projectID=p.projectID;settings=p.settings;durationFrames=p.durationFrames;lanes=p.lanes
            media=p.media.map { e in
                let relative=projectURL.map { ProjectFile.relative(URL(fileURLWithPath:e.ref.path),from:$0.deletingLastPathComponent().standardizedFileURL) } ?? e.relativePath
                return Entry(ref:Reference(e.ref),relativePath:relative,bookmark:e.bookmark)
            }
            videoClips=p.videoClips;audioClips=p.audioClips;subtitles=p.subtitles;spectra=p.spectra
        }
        var project: Model.Project {
            var p=Model.Project(.init(format:format,version:8,projectID:projectID,settings:settings,durationFrames:durationFrames,lanes:lanes,media:[],videoClips:videoClips,audioClips:audioClips,subtitles:subtitles,spectra:spectra))
            p.media=media.map {.init(ref:$0.ref.value,relativePath:$0.relativePath,bookmark:$0.bookmark)};return p
        }
    }
    private struct Header: Decodable { let format: String; let version: Int }
    static func version(for project: Model.Project) throws -> Int {
        try project.validate()
        if project.media.contains(where:{$0.ref.kind == .stillImage}) {return 9}
        let (timeline,_)=try ProjectFile.decode(JSONEncoder().encode(project.temporalDocument()))
        return ProjectFile.version(for:timeline)
    }
    static func encode(_ project: Model.Project, projectURL: URL? = nil) throws -> Data {
        let version=try version(for:project)
        if version < 9 {
            let (t,_)=try ProjectFile.decode(JSONEncoder().encode(project.temporalDocument()))
            let settings=RenderSettings(width:project.settings.width,height:project.settings.height,fps:Int32(project.settings.fps))
            let bookmarks=Dictionary(uniqueKeysWithValues:project.media.compactMap {e in e.bookmark.map {(e.ref.id,$0)} })
            let data = try ProjectFile.encode(t,projectID:project.projectID,settings:settings,bookmarks:bookmarks,projectURL:projectURL)
            guard projectURL == nil else { return data }
            // Without Save As, retain stored hints; the production writer has no hint input.
            var document = try JSONDecoder().decode(ProjectFile.Document.self,from:data)
            let hints = Dictionary(uniqueKeysWithValues:project.media.map { ($0.ref.id,$0.relativePath) })
            for i in document.media.indices { document.media[i].relativePath = hints[document.media[i].ref.id] ?? nil }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
            return try encoder.encode(document)
        }
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        return try encoder.encode(Document(project,projectURL:projectURL))
    }
    static func decode(_ data: Data) throws -> Model.Project {
        let header=try JSONDecoder().decode(Header.self,from:data)
        try Model.require(header.format == ProjectFile.format,"project format")
        if header.version <= 8 {
            // Format-9 payload must never disappear through the permissive legacy decoder.
            if let raw = try JSONSerialization.jsonObject(with:data) as? [String:Any],
               let entries = raw["media"] as? [[String:Any]] {
                for entry in entries {
                    if let ref = entry["ref"] as? [String:Any] {
                        try Model.require(ref["kind"] == nil && ref["image"] == nil, "declared media kind/image requires format 9")
                    }
                }
            }
            let (timeline,doc)=try ProjectFile.decode(data)
            var project = Model.Project(doc)
            // Use the original reader's semantics (format-1 lane order and lane-less clips).
            project.lanes = timeline.lanes
            project.videoClips = timeline.clips; project.audioClips = timeline.audioClips
            return project
        }
        try Model.require(header.version == 9,"unsupported project version")
        // Check raw image-clip fields before Clip normalizes default audio/origin values.
        guard let raw=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              let entries=raw["media"] as? [[String:Any]],let visual=raw["videoClips"] as? [[String:Any]] else {throw Model.Failure.invalid("document structure")}
        let allowedRoot:Set<String>=["format","version","projectID","settings","durationFrames","lanes","media","videoClips","audioClips","subtitles","spectra"]
        try Model.require(Set(raw.keys).isSubset(of:allowedRoot),"unknown document content")
        func keys(_ value: Any?, _ allowed: Set<String>) throws {
            guard let value, !(value is NSNull) else {return}
            guard let object=value as? [String:Any] else {throw Model.Failure.invalid("object type")}
            try Model.require(Set(object.keys).isSubset(of:allowed), "unknown nested content")
        }
        try keys(raw["settings"],["width","height","fps"])
        for lane in raw["lanes"] as? [[String:Any]] ?? [] {try keys(lane,["id","kind","name","muted","volumePercent"])}
        for c in visual + (raw["audioClips"] as? [[String:Any]] ?? []) {
            try keys(c,["id","mediaID","start","sourceIn","length","link","lane","transform","audio","origin"])
            try keys(c["transform"],["scaleMicro","offsetXMilli","offsetYMilli","scalePermille","offsetX","offsetY"])
            try keys(c["audio"],["volumePercent","muted","fadeIn","fadeOut"])
            if let audio=c["audio"] as? [String:Any] {for key in ["fadeIn","fadeOut"] {try keys(audio[key],["length","offset"])}}
        }
        for sub in raw["subtitles"] as? [[String:Any]] ?? [] {
            try keys(sub,["id","lane","start","length","text","style"])
            try keys(sub["style"],["fontName","sizeTenths","red","green","blue","alpha","alignment","xMilli","yMilli","outline","shadow","background"])
            if let style=sub["style"] as? [String:Any] {
                let color:Set<String>=["enabled","red","green","blue","alpha"]
                try keys(style["outline"],color.union(["widthTenths"]))
                try keys(style["shadow"],color.union(["offsetXTenths","offsetYTenths","blurTenths"]))
                try keys(style["background"],color.union(["padXTenths","padYTenths","radiusTenths"]))
            }
        }
        for spectrum in raw["spectra"] as? [[String:Any]] ?? [] {
            try keys(spectrum,["id","lane","start","length","sourceKey","style"])
            try keys(spectrum["style"],["mode","sides","startXMilli","startYMilli","endXMilli","endYMilli","maxHeightMilli","thicknessMilli","red","green","blue","alpha","bands","lowHz","highHz","windowMs","offsetMs","floorDB"])
        }
        let images=Set(entries.compactMap {e -> UUID? in
            guard let ref=e["ref"] as? [String:Any],ref["kind"] as? String == "stillImage" else {return nil};return (ref["id"] as? String).flatMap(UUID.init(uuidString:))
        })
        for e in entries {try Model.require(Set(e.keys).isSubset(of:["ref","relativePath","bookmark"]),"unknown media entry")}
        for c in visual where (c["mediaID"] as? String).flatMap(UUID.init(uuidString:)).map(images.contains) == true {
            for key in ["audio","origin","link"] {try Model.require(c[key] == nil || c[key] is NSNull,"image audio/source lineage")}
        }
        let result=try JSONDecoder().decode(Document.self,from:data).project
        try result.validate()
        return result
    }
}
