#if DEBUG
import AppKit
import AVFoundation
import OnTheFrameEngine

/// 스펙트럼 프리뷰 타이밍 실험(SP-0, Debug 전용, 2026-10-24, docs/SPECTRUM-DESIGN.md §10). 제품 경로가 아니다(일반 실행·Release에 없음).
/// - 자동: `open -g -n -W -a OnTheFrame.app <폴더> --args -OTFSpectrumPreviewTest` → <폴더>/spectrum-preview-result.json
/// - 소유자 수동 확인: `... --args -OTFSpectrumPreviewManual`(창을 닫을 때까지 그대로, 아래 표시를 눈으로 본다)
///
/// 제안 방식(설계 §3.2): 프리뷰 보기의 디스플레이 링크 콜백마다 그릴 프레임 k를 고른다.
/// - 재생 중(속도 ≠ 0)이고 진행 중인 탐색이 없으면: 항목에 붙인 비디오 출력의 itemTime(forHostTime: targetTimestamp) → RenderSettings.frame(containing:)
/// - 그 밖(멈춤·탐색 중·탐색 뒤): 화면에 나온 것으로 아는 프레임(자막 시간 창과 같은 값: 완료한 마지막 탐색 또는 멈춘 재생 헤드)
/// 그 프레임의 분석 값이 있으면 그 프레임 그림을, 없으면 비운다(틀린 그림을 보이지 않음). 분석은 뒤 차례 큐(시제품 분석기, 같은 원본 파일).
/// 늦게 끝난 분석은 캐시에 넣을 뿐 그림을 바꾸지 않는다 — 그림은 콜백이 지금 고른 프레임으로만 바꾼다. 세션(항목 회차)이 바뀌면 캐시를 비우고 이전 세션 결과는 버린다.
///
/// 관찰(무엇이 "실제 표시"인가):
/// - 멈춤: AVPlayerLayer.displayedPixelBuffer() = 이 층이 지금 표시하는 버퍼(Apple 헤더: 멈춤에서만 돌려줌). 그 화면 코드(원본 프레임 번호)와
///   그 콜백에서 스펙트럼 층에 넣은 프레임을 비교한다 — 실제 표시 비교.
/// - 재생: displayedPixelBuffer는 nil이다. 같은 항목 시각의 비디오 출력 버퍼 코드와 비교한다 — 대리 비교(층이 실제로 그 버퍼를 그 순간 보였는지는 모름).
///   화면 캡처는 쓰지 않는다(화면 기록 권한을 바꾸지 않음). 재생 중 실제 표시 일치는 소유자 눈 확인(움직이는 흰 상자와 빨간 테두리)으로만 본다.
@MainActor
final class SpectrumPreviewProbe: NSObject {
    let store: ProjectStore, view: PlayerNSView
    let hostLayer = CALayer(), canvas = CALayer(), spectrum = CALayer(), marker = CALayer(), label = CATextLayer()
    var output: AVPlayerItemVideoOutput?, outputItem: AVPlayerItem?
    private var link: CADisplayLink?
    var style: ProtoSpectrumStyle = { var s = ProtoSpectrumStyle(); s.start = CGPoint(x: 192, y: 960); s.end = CGPoint(x: 1728, y: 960)
        s.maxHeight = 200; s.sides = .above; s.rgba = (0.3, 0.9, 1, 1); return s }()
    // 분석(뒤 큐, 한 번에 하나)
    private(set) var session = 0
    private var analyzer: ProtoAnalyzer?, pieces: [ProtoPiece] = [], duration = 0
    private var cache: [Int: [Float]] = [:], lru: [Int] = []
    let cacheLimit = 600, maxQueued = 8
    private var queued: [Int] = [], inFlight: (k: Int, session: Int)?
    var delayForFrame: [Int: Double] = [:]   // 시험 주입: 그 프레임 분석을 늦춤(초)
    private(set) var analyzed = 0, staleDropped = 0, droppedQueued = 0, peakQueued = 0, lateCompletions: [(k: Int, session: Int, ms: Int)] = []
    private static let queue = DispatchQueue(label: "dev.ontheframe.spectrum-proto", qos: .userInitiated)
    // 표시 상태
    private(set) var shownK: Int?, shownBands: [Float]?, shownImageBytes = 0, desired = 0
    private(set) var ticks = 0, blankTicks = 0
    // 기록
    struct Sample: Codable { let phase: String; let ms: Int; let playing: Bool; let pendingSeek: Bool; let desired: Int; let shown: Int?
        let expectedSrc: Int?; let outputSrc: Int?; let layerSrc: Int?; let footprintMB: Double
        /// 재생 시작(속도 0 → ≠ 0) 뒤 ms, 비디오 출력에서 마지막으로 새 버퍼를 받은 뒤 ms(대리 값이 오래됐는지)
        let sincePlayMs: Int?; let outputAgeMs: Int? }
    var recording = false, phase = ""
    private(set) var samples: [Sample] = []
    private var lastOutputSrc: Int?, lastOutputMs = 0, playStartMs: Int?
    let t0 = CACurrentMediaTime()
    var ms: Int { Int((CACurrentMediaTime() - t0) * 1000) }
    /// 원본 fixture(2026-10-24 멈춤 맞춤 확대): 화면 코드 ID와 타임라인 단위(q/30 s) → 원본 프레임. 기본 otf-TA(30 fps, 1:1).
    var source = ReconcileSource.ta

    init(store: ProjectStore, view: PlayerNSView) {
        self.store = store; self.view = view
        super.init()
        for l in [hostLayer, canvas, spectrum, marker, label] as [CALayer] { l.actions = PlayerNSView.noActions }
        canvas.anchorPoint = .zero; canvas.masksToBounds = true
        marker.borderColor = NSColor.systemRed.cgColor; marker.borderWidth = Self.markerBorder; marker.isHidden = true
        label.fontSize = 36; label.foregroundColor = NSColor.systemRed.cgColor; label.contentsScale = 2
        label.frame = CGRect(x: 1180, y: 1080 - 300 - 48, width: 700, height: 48)   // 영상의 "TA  f=…" 글(위에서 약 115~160 px) 아래
        canvas.addSublayer(spectrum); canvas.addSublayer(marker); canvas.addSublayer(label)
        hostLayer.addSublayer(canvas)
        view.layer?.insertSublayer(hostLayer, below: view.subtitleHost)   // 영상 < 스펙트럼 < 자막
    }
    func start() {
        let l = view.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common); link = l
    }
    func stop() { link?.invalidate(); link = nil; hostLayer.removeFromSuperlayer() }

    /// 새 항목(세션): 비디오 출력·조각·분석기를 바꾸고 캐시를 비운다. 진행 중 분석은 끝나도 버린다.
    func newSession(item: AVPlayerItem?, output o: AVPlayerItemVideoOutput?, timeline t: Timeline, media: MediaAsset) {
        session += 1; output = o; outputItem = item
        cache = [:]; lru = []; queued = []
        duration = t.durationFrames
        let lanes = Dictionary(uniqueKeysWithValues: t.lanes.map { ($0.id, $0) })
        pieces = t.audioClips.compactMap { c in   // 소리 클립(clips는 영상 클립)
            guard let ln = lanes[c.lane ?? UUID()], ln.kind == .audio else { return nil }
            return ProtoPiece(start: c.start, length: c.length, sourceIn: c.sourceIn, audio: c.audio ?? .default, laneGain: ln.muted ? 0 : Double(ln.volumePercent) / 100)
        }
        analyzer = ProtoAnalyzer(source: ProtoPCMSource(url: media.url))
        setShown(nil, nil)
    }
    func clearCache() { cache = [:]; lru = [] }
    var pieceCount: Int { pieces.count }
    func cached(_ k: Int) -> [Float]? { cache[k] }
    var cacheBytes: Int { cache.count * 64 * 4 }
    var pendingCount: Int { queued.count + (inFlight == nil ? 0 : 1) }
    var chunkBytesEstimate: Int { (analyzer?.cacheChunks ?? 0) * 2 * 8 * 48_000 * 4 }   // 상한(덩어리 4개 × 2채널 × 8초 × 4바이트)

    func request(_ k: Int) {
        guard k >= 0, k < max(1, duration), cache[k] == nil, inFlight?.k != k || inFlight?.session != session, !queued.contains(k) else { return }
        queued.append(k)
        while queued.count > maxQueued {   // 고른 프레임에서 가장 먼 요청을 버림
            let worst = queued.indices.max { abs(queued[$0] - desired) < abs(queued[$1] - desired) }!
            queued.remove(at: worst); droppedQueued += 1
        }
        peakQueued = max(peakQueued, queued.count)
        pump()
    }
    private func pump() {
        guard inFlight == nil, let i = queued.indices.min(by: { abs(queued[$0] - desired) < abs(queued[$1] - desired) }), let a = analyzer else { return }
        let k = queued.remove(at: i), s = session, p = pieces, delay = delayForFrame[k]
        inFlight = (k, s)
        let an = a
        Self.queue.async {
            if let delay { Thread.sleep(forTimeInterval: delay) }
            let v = try? an.bands(frame: k, pieces: p)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.finished(k, s, v) } }
        }
    }
    private func finished(_ k: Int, _ s: Int, _ v: [Float]?) {
        inFlight = nil
        analyzed += 1
        if s != session { staleDropped += 1 }
        else if let v {
            cache[k] = v; lru.append(k)
            while lru.count > cacheLimit { cache[lru.removeFirst()] = nil }
            if k != desired { lateCompletions.append((k, s, ms)) }   // 고른 프레임이 이미 바뀜: 캐시에만 넣는다
        }
        pump()
    }

    private func setShown(_ k: Int?, _ v: [Float]?) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if k != nil, let v, let r = ProtoSpectrumRenderer.renderBounded(v, style: style, canvas: CGSize(width: 1920, height: 1080)) {
            spectrum.contents = r.image
            spectrum.frame = CGRect(x: r.rect.minX, y: 1080 - r.rect.maxY, width: r.rect.width, height: r.rect.height)
            shownImageBytes = r.image.bytesPerRow * r.image.height
        } else { spectrum.contents = nil; shownImageBytes = 0 }
        if let k, v != nil, source.hasCode, let src = expectedSource(k) {
            marker.isHidden = false
            marker.frame = Self.markerFrame(src: src)
            label.string = "spectrum k=\(k) src=\(src)"
        } else if !source.hasCode { marker.isHidden = true; label.string = k.map { "spectrum k=\($0) (실제 미디어 — 표식 없음)" } ?? "" }
        else { marker.isHidden = true; label.string = k.map { "spectrum k=\($0) (분석 대기)" } ?? "" }
        CATransaction.commit()
        shownK = v == nil ? nil : k; shownBands = v
    }
    /// 타임라인 프레임 k에 보이는 영상 클립의 원본 프레임(맨 위 영상 레인, 끝 위치는 마지막 프레임)
    func expectedSource(_ k0: Int) -> Int? {
        let t = store.timeline, k = min(k0, max(0, t.durationFrames - 1))
        let vlanes = Set(t.lanes(.video).map(\.id))
        guard let c = t.clips.first(where: { vlanes.contains($0.lane ?? UUID()) && $0.start <= k && k < $0.start + $0.length }) else { return nil }
        return source.frame(q: c.sourceIn + (k - c.start))
    }
    func readSrc(_ pb: CVPixelBuffer) -> Int? { Self.readSource(pb, id: source.id) }

    // MARK: 표시(2026-10-24 고침): 흰 상자(원본 위 왼쪽 원점 x = 40 + 12·src mod 1400, y 300, 80 px — Spec4K FHD) 둘레에 틈 10 px, 테두리 2 px(캔버스 단위).
    // 한 프레임 어긋나면 상자가 12 px 옮겨 한쪽 틈 22 px·반대쪽 2 px 겹침이 된다. 화면 반올림(1화면 픽셀 안팎)은 10 px 틈에 묻힌다.
    static let markerGap: CGFloat = 10, markerBorder: CGFloat = 2
    /// 캔버스 좌표(아래 왼쪽 원점) 테두리 바깥 사각형
    static func markerFrame(src: Int) -> CGRect {
        let ex = CGFloat(40 + (src * 12) % 1400), o = markerGap + markerBorder
        return CGRect(x: ex - o, y: 1080 - 300 - 80 - o, width: 80 + 2 * o, height: 80 + 2 * o)
    }
    /// 캔버스를 영상 층이 실제로 영상을 그리는 사각형(AVPlayerLayer.videoRect)에 맞춘다. 아직 없으면 resizeAspect 식(PlayerNSView.fit과 같음).
    private func fitCanvas() {
        hostLayer.frame = view.bounds
        let vr = view.playerLayer.videoRect
        let r: CGRect
        if vr.width > 0, vr.height > 0 { r = hostLayer.convert(vr, from: view.playerLayer) }
        else { let sz = view.bounds.size, kk = min(sz.width / 1920, sz.height / 1080); r = CGRect(x: (sz.width - 1920 * kk) / 2, y: (sz.height - 1080 * kk) / 2, width: 1920 * kk, height: 1080 * kk) }
        canvas.bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        canvas.position = r.origin
        canvas.setAffineTransform(CGAffineTransform(scaleX: r.width / 1920, y: r.height / 1080))
    }

    // MARK: 표시 기하 기록(2026-10-24): 멈춘 화면마다 실제 표시 버퍼에서 흰 상자 경계(1/화소 보간)를 재고, 영상 층 videoRect로 화면 픽셀에 옮겨
    // 테두리 안쪽 경계와 네 변 틈을 적는다. 상자 왼쪽 경계 − 기대 위치(원본 px)가 ±12·n이면 프레임 어긋남, 0 근처면 공간 기하만 남는다.
    struct GeometrySample: Codable {
        let ms: Int; let k: Int; let expectedSrc: Int; let layerSrc: Int?
        let viewBounds: [Double]; let backingScale: Double; let videoRect: [Double]; let canvasInView: [Double]
        /// 표시 버퍼에서 잰 흰 상자 [왼, 위, 오른, 아래](원본 1920×1080 px, 위 왼쪽 원점), 기대 [ex, 300, ex+80, 380]
        let boxInBuffer: [Double]?; let expectedBox: [Double]; let boxOffsetVsExpected: Double?
        /// 화면 픽셀(보기 아래 왼쪽 원점 × 백킹 배율): [왼, 아래, 오른, 위]
        let boxOnScreenPx: [Double]?; let markerOuterPx: [Double]; let markerInnerPx: [Double]
        /// 잰 상자 기준 틈(화면 픽셀), 설계 틈 = markerGap × 배율 × videoRect 배율
        let gapsPx: [String: Double]?; let designGapPx: Double
    }
    /// 콜백 끝에서 부르는 관찰 훅(멈춤 조사용, 일반 실험에서는 nil)
    var tickHook: ((CADisplayLink) -> Void)?
    var geometryURL: URL?
    private(set) var geometry: [GeometrySample] = []
    private var lastGeometryK: Int?, geomPendingK: Int?, geomPendingSince = 0
    private func recordGeometry() {
        guard let url = geometryURL, source.hasCode, let k = shownK, let src = expectedSource(k), let w = view.window else { return }
        let sc = w.backingScaleFactor, vr = view.playerLayer.videoRect
        guard vr.width > 0 else { return }
        let vrV = view.layer!.convert(vr, from: view.playerLayer)
        let cr = view.layer!.convert(canvas.frame, from: hostLayer)
        let ex = Double(40 + (src * 12) % 1400)
        let pb = view.playerLayer.displayedPixelBuffer()
        let box = pb.flatMap { Self.boxEdges($0, expectedLeft: ex) }
        func dpx(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.maxX, r.maxY].map { Double($0 * sc) } }
        let outer = view.layer!.convert(marker.frame, from: canvas)
        let kx = vrV.width / 1920, ky = vrV.height / 1080
        let inner = outer.insetBy(dx: Self.markerBorder * kx, dy: Self.markerBorder * ky)
        var onScreen: [Double]?, gaps: [String: Double]?
        if let b = box {   // 원본 위 왼쪽 원점 → 보기 아래 왼쪽 원점(videoRect 선형 대응 가정)
            let r = CGRect(x: vrV.minX + CGFloat(b[0]) * kx, y: vrV.minY + (1080 - CGFloat(b[3])) * ky, width: CGFloat(b[2] - b[0]) * kx, height: CGFloat(b[3] - b[1]) * ky)
            onScreen = dpx(r)
            gaps = ["left": Double((r.minX - inner.minX) * sc), "right": Double((inner.maxX - r.maxX) * sc),
                    "bottom": Double((r.minY - inner.minY) * sc), "top": Double((inner.maxY - r.maxY) * sc)]
        }
        geometry.append(GeometrySample(ms: ms, k: k, expectedSrc: src, layerSrc: pb.flatMap(readSrc),
            viewBounds: [Double(view.bounds.width), Double(view.bounds.height)], backingScale: Double(sc),
            videoRect: [vrV.minX, vrV.minY, vrV.width, vrV.height].map(Double.init), canvasInView: [cr.minX, cr.minY, cr.width, cr.height].map(Double.init),
            boxInBuffer: box, expectedBox: [ex, 300, ex + 80, 380], boxOffsetVsExpected: box.map { $0[0] - ex },
            boxOnScreenPx: onScreen, markerOuterPx: dpx(outer), markerInnerPx: dpx(inner), gapsPx: gaps, designGapPx: Double(Self.markerGap * kx * sc)))
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(geometry) { try? d.write(to: url) }
    }
    /// 표시 버퍼에서 흰 상자 경계: 가운데 행·열의 최소 채널 단면이 문턱 135(배경 약 34와 흰색 235 사이)를 지나는 자리(화소 가운데 사이 직선 보간).
    /// 돌려주는 값: [왼, 위, 오른, 아래] 원본 1920×1080 px(버퍼 크기가 다르면 비례). 길이 60~100 px인 구간 중 기대 위치에 가장 가까운 것.
    nonisolated static func boxEdges(_ pb: CVPixelBuffer, expectedLeft ex: Double) -> [Double]? {
        withRGB(pb) { rgb, w, h in
            let sx = Double(w) / 1920, sy = Double(h) / 1080, T = 135.0
            func lum(_ x: Int, _ y: Int) -> Double? { rgb(x, y).map { min($0.0, $0.1, $0.2) } }
            func runs(_ vals: [Double], _ base: Int) -> [(Double, Double)] {   // (시작 경계, 끝 경계) 버퍼 px
                var out: [(Double, Double)] = []; var i = 1
                while i < vals.count {
                    if vals[i - 1] < T, vals[i] >= T {
                        let a = Double(base + i) - 0.5 + (T - vals[i - 1]) / (vals[i] - vals[i - 1])
                        var j = i; while j + 1 < vals.count, vals[j + 1] >= T { j += 1 }
                        if j + 1 < vals.count { out.append((a, Double(base + j) + 0.5 + (vals[j] - T) / (vals[j] - vals[j + 1]))) }
                        i = j + 1
                    } else { i += 1 }
                }
                return out
            }
            let y0 = Int(340 * sy), x0 = max(0, Int((ex - 200) * sx)), x1 = min(w - 1, Int((ex + 280) * sx))
            let row = (x0...x1).compactMap { lum($0, y0) }
            guard row.count == x1 - x0 + 1 else { return nil }
            guard let hr = runs(row, x0).filter({ ($0.1 - $0.0) / sx > 60 && ($0.1 - $0.0) / sx < 100 }).min(by: { abs($0.0 / sx - ex) < abs($1.0 / sx - ex) }) else { return nil }
            let xc = Int((hr.0 + hr.1) / 2), ya = Int(250 * sy), yb = min(h - 1, Int(395 * sy))
            let col = (ya...yb).compactMap { lum(xc, $0) }
            guard col.count == yb - ya + 1, let vr = runs(col, ya).first(where: { $0.0 <= Double(y0) && $0.1 >= Double(y0) }) else { return nil }
            return [hr.0 / sx, vr.0 / sy, hr.1 / sx, vr.1 / sy]
        }
    }
    /// 버퍼 화소 → RGB(0…255). BGRA와 4:2:0 두 평면(비디오·전체 범위, BT.709)
    nonisolated static func withRGB<T>(_ pb: CVPixelBuffer, _ body: ((Int, Int) -> (Double, Double, Double)?, Int, Int) -> T) -> T {
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        func rgb(_ x: Int, _ y: Int) -> (Double, Double, Double)? {
            guard x >= 0, y >= 0, x < w, y < h else { return nil }
            if fmt == kCVPixelFormatType_32BGRA {
                guard let b = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else { return nil }
                let q = b + y * CVPixelBufferGetBytesPerRow(pb) + x * 4
                return (Double(q[2]), Double(q[1]), Double(q[0]))
            }
            guard CVPixelBufferGetPlaneCount(pb) == 2, let yb = CVPixelBufferGetBaseAddressOfPlane(pb, 0)?.assumingMemoryBound(to: UInt8.self),
                  let cb = CVPixelBufferGetBaseAddressOfPlane(pb, 1)?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let full = fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            let yv = Double(yb[y * CVPixelBufferGetBytesPerRowOfPlane(pb, 0) + x])
            let c = cb + (y / 2) * CVPixelBufferGetBytesPerRowOfPlane(pb, 1) + (x / 2) * 2
            let u = Double(c[0]) - 128, v = Double(c[1]) - 128
            let yy = full ? yv : (yv - 16) * 255 / 219, k = full ? 1.0 : 255.0 / 224
            return (yy + 1.5748 * v * k, yy - 0.1873 * u * k - 0.4681 * v * k, yy + 1.8556 * u * k)   // BT.709
        }
        return body(rgb, w, h)
    }

    @objc private func tick(_ l: CADisplayLink) {
        ticks += 1
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fitCanvas()
        CATransaction.commit()
        let p = store.player, playing = p.rate != 0, pendingSeek = view.hasPendingSeeksForExperiment
        if playing { if playStartMs == nil { playStartMs = ms } } else { playStartMs = nil }
        var itemT = CMTime.invalid
        if playing, !pendingSeek, let o = output, outputItem === p.currentItem {
            itemT = o.itemTime(forHostTime: l.targetTimestamp)
            desired = store.settings.frame(containing: itemT)
        } else {
            desired = view.displayedFrameForExperiment
        }
        desired = max(0, min(desired, max(0, duration - 1)))   // 끝 위치 = 마지막 프레임 유지(D-018)
        if let v = cache[desired] { if shownK != desired { setShown(desired, v) } }
        else { request(desired); if shownK != nil || shownBands != nil { setShown(desired, nil) }; blankTicks += 1 }
        if playing { for d in 1...12 { request(desired + d) } }
        // 기하: 멈춘 화면에서 같은 프레임이 150 ms 유지된 뒤 한 번(탐색 완료 직후 1콜백 어긋남을 피함)
        if geometryURL != nil, !playing, !pendingSeek, let k = shownK {
            if k != geomPendingK { geomPendingK = k; geomPendingSince = ms }
            else if k != lastGeometryK, ms - geomPendingSince >= 150 { lastGeometryK = k; recordGeometry() }
        } else { geomPendingK = nil; if playing { lastGeometryK = nil } }
        tickHook?(l)
        guard recording else { return }
        // 관찰
        var outSrc: Int?, layerSrc: Int?
        if playing, itemT.isNumeric, let o = output {
            if o.hasNewPixelBuffer(forItemTime: itemT), let pb = o.copyPixelBuffer(forItemTime: itemT, itemTimeForDisplay: nil) { lastOutputSrc = readSrc(pb); lastOutputMs = ms }
            outSrc = lastOutputSrc
        } else if !playing, let pb = view.playerLayer.displayedPixelBuffer() {
            layerSrc = readSrc(pb); lastOutputSrc = nil
        }
        samples.append(Sample(phase: phase, ms: ms, playing: playing, pendingSeek: pendingSeek, desired: desired, shown: shownK,
                              expectedSrc: shownK.flatMap(expectedSource), outputSrc: outSrc, layerSrc: layerSrc, footprintMB: Self.footprintMB(),
                              sincePlayMs: playStartMs.map { ms - $0 }, outputAgeMs: outSrc == nil ? nil : ms - lastOutputMs))
    }

    /// 화면 코드(원본 프레임 번호 16비트)를 읽는다. E2/E3 생성기 FHD 배치(Spec4K ÷ 2): 칸 왼쪽 40, 간격 56, 크기 48, ID 행 위 100, 프레임 행 위 170.
    /// 칸 가운데 16×16의 평균 (R+G+B)/3 > 128이면 1(E2Metrics.measure와 같은 판정). 원본 ID가 id(기본 TA 0x33)가 아니면 읽지 못함(nil).
    nonisolated static func readSource(_ pb: CVPixelBuffer, id: Int = 0x33) -> Int? {
      withRGB(pb) { rgb, w, h in
        let sx = Double(w) / 1920, sy = Double(h) / 1080
        func code(_ rowY: Int, _ bits: Int) -> Int? {
            var v = 0
            for b in 0..<bits {
                let x0 = 40 + b * 56 + 16, y0 = rowY + 16
                var s = 0.0
                for yy in stride(from: y0, to: y0 + 16, by: 2) { for xx in stride(from: x0, to: x0 + 16, by: 2) {
                    guard let c = rgb(Int(Double(xx) * sx), Int(Double(yy) * sy)) else { return nil }
                    s += (c.0 + c.1 + c.2) / 3
                } }
                v = (v << 1) | (s / 64 > 128 ? 1 : 0)
            }
            return v
        }
        guard code(100, 8) == id else { return nil }
        return code(170, 16)
      }
    }
    nonisolated static func footprintMB() -> Double {
        var info = task_vm_info_data_t(); var n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n) } }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}

/// 멈춤 맞춤 소유자 비교(2026-10-24, Debug 실험 — `MANUAL=1 RECONCILE=1 app/scripts/spectrum-preview-test.sh`). 제품 재생 경로는 바꾸지 않는다.
/// 멈춤 맞춤은 떠 있는 "멈춤 맞춤 실험" 창의 단추로만 켠다(처음엔 꺼짐 = 제품 그대로). 켜져 있으면 제품 store.pause()가 끝난 직후(main 큐 다음 차례)
/// 그 재생 헤드로 기존 store.seek(to:)(정밀 탐색)를 한 번 부른다 — 그 사이 다른 탐색이 시작됐으면(탐색 번호가 바뀜) 부르지 않는다.
/// 자동 비교(runPauseReconcile)는 pause() 바로 뒤 같은 차례에 부른다 — 이 창은 한 차례 늦다(차이는 재지 않음).
/// 멈춤마다 700 ms(또는 재개·다시 멈춤까지) 콜백마다 실제 표시 버퍼 원본 번호를 읽어 <폴더>/pause-events-manual-<시각>.json에 쓰고 창에 요약한다.
/// 소리는 재지 않는다(소유자가 듣는다).
@MainActor
final class PauseReconcileManual: NSObject {
    let store: ProjectStore, probe: SpectrumPreviewProbe, url: URL
    private(set) var enabled = false
    private var rateObs: NSKeyValueObservation?, boundaryObs: Any?
    private let panel: NSPanel, modeText = NSTextField(labelWithString: ""), lastText = NSTextField(wrappingLabelWithString: ""),
                countText = NSTextField(wrappingLabelWithString: ""), toggle = NSButton(title: "", target: nil, action: nil)
    private let overlay = CATextLayer()
    struct Obs: Codable { let ms: Int; let layerSrc: Int?; let expectedSrc: Int?; let playhead: Int; let pendingSeek: Bool; var bufferID: UInt32? = nil }
    struct Event: Codable {
        let n: Int; let atMs: Int; let reconcile: Bool; let trigger: String; let source: String
        /// 멈춘 직후 player 시각(타임라인 초)과 다음 타임라인 프레임 경계까지 남은 ms
        let itemSecAtPause: Double; let msToNextBoundary: Double; let playhead: Int; let reconcileSeekIssued: Bool
        var obs: [Obs] = []; var endedBy = ""; var userSeekDuring = false
        /// 보인 원본 번호의 차례(같은 번호 이어짐은 하나로), 맞기까지 ms(그 뒤 끝까지 실제 표시 = 기대), 한 칸 뒤로 간 적, 400 ms 뒤 내내 어긋남
        var sequence: [Int] = []; var agreeMs: Int?; var backwardStep = false; var persistentMismatch = false
        /// 재개할 때 player 시각(프레임 경계에서 다시 시작했는지 보려고)
        var resumeItemSec: Double?
        /// 멈춘 뒤 표시 버퍼(IOSurface ID)가 바뀐 횟수 — 실제 미디어에서 프레임 번호 대신 쓰는 대리(새 그림이 걸렸다는 뜻, 어느 프레임인지는 아님)
        var bufferChanges = 0
    }
    private var events: [Event] = [], current: Event?, pauseMs = 0, tokenAfterStart = 0, nextTrigger = "space-or-other"

    init(store: ProjectStore, probe: SpectrumPreviewProbe, url: URL) {
        self.store = store; self.probe = probe; self.url = url
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 250), styleMask: [.titled, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.title = "멈춤 맞춤 실험(Debug)"; panel.isFloatingPanel = true; panel.becomesKeyOnlyIfNeeded = true; panel.hidesOnDeactivate = false
        toggle.target = self; toggle.action = #selector(toggleMode)
        let near = NSButton(title: "경계 직전에 멈추기(약 0.6초 재생)", target: self, action: #selector(pauseNear)),
            mid = NSButton(title: "프레임 가운데에서 멈추기(약 0.6초 재생)", target: self, action: #selector(pauseMid))
        modeText.font = .boldSystemFont(ofSize: 15)
        for t in [lastText, countText] { t.font = .systemFont(ofSize: 11); t.preferredMaxLayoutWidth = 430 }
        let stack = NSStackView(views: [modeText, toggle, near, mid, lastText, countText])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        panel.contentView = stack
        if let sf = NSScreen.main?.visibleFrame { panel.setFrameTopLeftPoint(NSPoint(x: sf.maxX - 480, y: sf.maxY - 20)) }
        panel.orderFrontRegardless()
        overlay.fontSize = 40; overlay.contentsScale = 2; overlay.actions = PlayerNSView.noActions
        overlay.frame = CGRect(x: 40, y: 1080 - 470, width: 1100, height: 52)   // 흰 상자(위 300~380) 아래
        probe.canvas.addSublayer(overlay)
        rateObs = store.player.observe(\.rate, options: [.old, .new]) { [weak self] _, ch in
            let old = ch.oldValue ?? 0, new = ch.newValue ?? 0
            let run: @Sendable () -> Void = { MainActor.assumeIsolated { _ = self?.rateChanged(old: old, new: new) } }
            if Thread.isMainThread { run() } else { DispatchQueue.main.async(execute: run) }
        }
        probe.tickHook = { [weak self] _ in self?.tick() }
        write(); refresh()
    }

    @objc func toggleMode() { enabled.toggle(); refresh() }
    var eventCount: Int { events.count }
    @objc func pauseNear() { schedulePause(fraction: 0.94, trigger: "button-near-boundary") }   // 경계 약 2 ms 앞
    @objc func pauseMid() { schedulePause(fraction: 0.5, trigger: "button-mid-frame") }
    /// 재생(멈춰 있으면 시작)하고 약 18프레임 뒤 (n + fraction)/30 s에 제품 store.pause()를 부른다(경계 관찰자 — 실제 멈춘 자리는 기록에 남음).
    private func schedulePause(fraction: Double, trigger: String) {
        if let o = boundaryObs { store.player.removeTimeObserver(o); boundaryObs = nil }
        if !store.isPlaying { store.play() }
        let target = ((store.player.currentTime().seconds * 30).rounded(.down) + 18 + fraction) / 30
        nextTrigger = trigger
        boundaryObs = store.player.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: target, preferredTimescale: 600_000))], queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let o = self.boundaryObs { self.store.player.removeTimeObserver(o); self.boundaryObs = nil }
                if self.store.isPlaying { self.store.pause() }
            }
        }
    }

    private func rateChanged(old: Float, new: Float) {
        if old != 0, new == 0 {
            if current != nil { finish("re-pause") }
            let t = store.player.currentTime().seconds, token = store.seekToken, at = probe.ms
            let trigger = nextTrigger; nextTrigger = "space-or-other"
            DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                var issued = false
                if self.enabled, !self.store.isPlaying, self.store.player.rate == 0, self.store.seekToken == token { self.store.seek(to: self.store.playhead); issued = true }
                self.pauseMs = at; self.tokenAfterStart = self.store.seekToken
                self.current = Event(n: self.events.count + 1, atMs: at, reconcile: self.enabled, trigger: trigger, source: self.probe.source.file, itemSecAtPause: t,
                                     msToNextBoundary: (((t * 30).rounded(.down) + 1) / 30 - t) * 1000, playhead: self.store.playhead, reconcileSeekIssued: issued)
            } }
        } else if old == 0, new != 0, current != nil {
            current?.resumeItemSec = store.player.currentTime().seconds
            finish("resume")
        }
    }
    private func tick() {
        guard current != nil else { return }
        let dt = probe.ms - pauseMs
        if dt > 700 { finish("700ms"); return }
        guard store.player.rate == 0 else { return }
        let ph = store.playhead, pb = store.previewHost?.playerLayer.displayedPixelBuffer()
        current?.obs.append(Obs(ms: dt, layerSrc: probe.source.hasCode ? pb.flatMap(probe.readSrc) : nil, expectedSrc: probe.source.hasCode ? probe.expectedSource(ph) : nil,
                                playhead: ph, pendingSeek: store.previewHost?.hasPendingSeeksForExperiment ?? false, bufferID: pb.flatMap(SpectrumPreviewExperiment.surfaceID)))
    }
    private func finish(_ why: String) {
        guard var e = current else { return }
        current = nil
        e.endedBy = why; e.userSeekDuring = store.seekToken != tokenAfterStart
        let ids = e.obs.compactMap(\.bufferID); e.bufferChanges = zip(ids, ids.dropFirst()).filter { $0 != $1 }.count
        for o in e.obs { if let v = o.layerSrc, e.sequence.last != v { e.sequence.append(v) } }
        func ok(_ o: Obs) -> Bool { o.layerSrc != nil && o.layerSrc == o.expectedSrc }
        for (j, o) in e.obs.enumerated() where ok(o) && e.obs[j...].allSatisfy(ok) { e.agreeMs = o.ms; break }
        let last = probe.source.frames - 1
        e.backwardStep = zip(e.sequence, e.sequence.dropFirst()).contains { $1 == $0 - 1 || ($0 == 0 && $1 == last) }
        let tail = e.obs.filter { $0.ms >= 400 }
        e.persistentMismatch = !tail.isEmpty && tail.allSatisfy { !ok($0) }
        events.append(e); write(); refresh()
    }
    private func write() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(events) { try? d.write(to: url) }
    }
    private func refresh() {
        modeText.stringValue = enabled ? "멈춤 맞춤: 켜짐 (실험 — 멈춘 뒤 정밀 탐색 한 번)" : "멈춤 맞춤: 꺼짐 (제품 그대로)"
        modeText.textColor = enabled ? .systemGreen : .systemOrange
        toggle.title = enabled ? "멈춤 맞춤 끄기" : "멈춤 맞춤 켜기"
        CATransaction.begin(); CATransaction.setDisableActions(true)
        overlay.string = enabled ? "멈춤 맞춤 켜짐 (RECONCILE ON)" : "멈춤 맞춤 꺼짐 (OFF, 제품 그대로)"
        overlay.foregroundColor = (enabled ? NSColor.systemGreen : NSColor.systemOrange).cgColor
        CATransaction.commit()
        if let e = events.last, !probe.source.hasCode {
            lastText.stringValue = "마지막 멈춤 #\(e.n) (\(e.reconcile ? "켜짐" : "꺼짐"), \(e.trigger)): 경계까지 \(String(format: "%.1f", e.msToNextBoundary)) ms · "
                + "멈춘 뒤 화면 버퍼 바뀜 \(e.bufferChanges)번 · 실제 미디어라 프레임 번호는 판별하지 않음" + (e.userSeekDuring ? " · 그 사이 다른 탐색" : "")
        } else if let e = events.last {
            let seq = e.sequence.map(String.init).joined(separator: " → ")
            lastText.stringValue = "마지막 멈춤 #\(e.n) (\(e.reconcile ? "켜짐" : "꺼짐"), \(e.trigger)): 경계까지 \(String(format: "%.1f", e.msToNextBoundary)) ms · "
                + "기대 원본 \(e.obs.last?.expectedSrc.map(String.init) ?? "-") · 화면 원본 \(seq.isEmpty ? "-" : seq)"
                + (e.backwardStep ? " (한 칸 뒤로)" : "") + (e.persistentMismatch ? " · 어긋난 채 남음" : "")
                + " · 맞음 \(e.agreeMs.map { "\($0) ms" } ?? "없음")" + (e.userSeekDuring ? " · 그 사이 다른 탐색" : "")
        } else { lastText.stringValue = "아직 멈춤 기록 없음" }
        func line(_ on: Bool) -> String {
            let xs = events.filter { $0.reconcile == on }
            if !probe.source.hasCode { return "\(on ? "켜짐" : "꺼짐"): 멈춤 \(xs.count) · 멈춘 뒤 화면 바뀜 있음 \(xs.filter { $0.bufferChanges > 0 }.count)" }
            return "\(on ? "켜짐" : "꺼짐"): 멈춤 \(xs.count) · 어긋난 채 남음 \(xs.filter(\.persistentMismatch).count) · 한 칸 뒤로 \(xs.filter(\.backwardStep).count)"
        }
        countText.stringValue = line(false) + "\n" + line(true) + "\n기록: \(url.lastPathComponent)"
    }
}

/// 멈춤 맞춤 비교에 쓰는 생성 fixture(DevFixtures의 같은 이름 상수와 같은 값: 화면 코드 ID, 고정 간격 PTS = f·v/ts, 프레임 수).
/// 타임라인 단위 q(1/30 s)에 보이는 원본 프레임 = PTS ≤ q/30인 마지막 프레임(TimedFixture.frame(atTimelineUnits:)와 같은 정수 식).
struct ReconcileSource: Sendable {
    let file: String, id: Int, v: Int64, ts: Int64, frames: Int
    func frame(q: Int) -> Int { min(frames - 1, max(0, Int(Int64(q) * ts / (30 * v)))) }
    var fps: Double { Double(ts) / Double(v) }
    /// 화면 코드가 있는 생성 fixture인가(실제 미디어는 id −1: 코드·흰 상자 표식을 증거로 쓰지 않음)
    var hasCode: Bool { id >= 0 }
    /// 실제 미디어(소유자가 허락한 원본, 읽기만): 코드 없음. 원본 프레임 대응은 쓰지 않는다(1:1 자리값).
    static func real(_ url: URL) -> ReconcileSource { ReconcileSource(file: url.lastPathComponent, id: -1, v: 1, ts: 30, frames: Int(Int32.max)) }
    static let ta = ReconcileSource(file: "otf-TA.mp4", id: 0x33, v: 1, ts: 30, frames: 120)
    static let all: [ReconcileSource] = [ta,
        ReconcileSource(file: "otf-N2997.mp4", id: 0x4E, v: 1001, ts: 30000, frames: 120),
        ReconcileSource(file: "otf-P25.mp4", id: 0x71, v: 24, ts: 600, frames: 100),
        ReconcileSource(file: "otf-F23976.mp4", id: 0xA5, v: 1001, ts: 24000, frames: 48),
        ReconcileSource(file: "otf-H5994.mov", id: 0xC3, v: 1001, ts: 60000, frames: 120)]
    /// 실행 인수 -OTFReconcileSource <파일 이름>(없으면 otf-TA)
    static func fromArguments() -> ReconcileSource {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "-OTFReconcileSource"), i + 1 < a.count else { return ta }
        return all.first { $0.file == a[i + 1] } ?? ta
    }
}

@MainActor
enum SpectrumPreviewExperiment {
    struct Check: Codable { let name: String; let pass: Bool; let detail: String }
    struct PhaseStat: Codable { let phase: String; let samples: Int; let compared: Int; let mismatches: Int; let blank: Int; let unreadable: Int; let kind: String; let firstMismatches: [String] }
    struct Resource: Codable { let label: String; let footprintMB: Double; let bandCacheEntries: Int; let bandCacheBytes: Int; let pending: Int; let imageBytes: Int }
    struct Result: Codable { var checks: [Check]; var phases: [PhaseStat]; var resources: [Resource]; var notes: [String]; var samples: [SpectrumPreviewProbe.Sample] }

    /// 4 × otf-TA(원본 120프레임, 클릭 30·50·75·100, 440 Hz) = 480프레임
    static func timeline(_ m: MediaAsset, trimFirst: Int = 0, frameSubtitles: Bool = false, copies: Int = 4) throws -> Timeline {
        var t = Timeline().registering(m)
        let v = t.lanes(.video).first!.id, a = t.lanes(.audio).first!.id
        for _ in 0..<copies { t = try t.appending(media: m.id, videoLane: v, audioLane: a) }
        if trimFirst > 0 { t = try t.trimmingStart(clip: t.clips.first { $0.lane == v }!.id, by: trimFirst) }
        if frameSubtitles {   // 프레임마다 한 프레임 길이 자막(자막 층의 선택 상태를 프레임 단위로 읽기 위함)
            let l = UUID(); t = try t.addingLane(.subtitle, name: "F", id: l, outward: true)
            for k in 0..<t.durationFrames { t = try t.addingSubtitle(lane: l, at: k, length: 1, text: "s\(k)") }
        }
        return t
    }
    /// 새 항목에 비디오 출력을 붙여 타임라인을 올린다(일반 재구성 경로)
    static func load(_ s: ProjectStore, _ probe: SpectrumPreviewProbe?, _ t: Timeline, _ m: MediaAsset) async -> (AVPlayerItem, AVPlayerItemVideoOutput)? {
        var attached: (AVPlayerItem, AVPlayerItemVideoOutput)?
        s.itemCreatedHookForTest = { item, _ in
            let o = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            item.add(o); attached = (item, o)
        }
        s.loadTimelineForTest(t)
        let ok = await LayerDiagSelfTest.waitUntil(30) { s.appliedGeneration == s.generation && attached != nil && s.player.currentItem === attached?.0 }
        guard ok, let a = attached else { return nil }
        probe?.newSession(item: a.0, output: a.1, timeline: s.timeline, media: m)
        return a
    }

    static var manualReconcile: PauseReconcileManual?
    /// media: open으로 함께 연 실제 미디어(읽기만, 소유자 허락 원본). 있으면 그 파일 한 번(1×)으로 타임라인을 만들고 코드·표식은 쓰지 않는다.
    static func runManual(folder: URL, media: URL? = nil) async {
        let s = ProjectStore.shared
        _ = await LayerDiagSelfTest.waitUntil(5) { s.editorWindow != nil }
        let src = media.map(ReconcileSource.real) ?? ReconcileSource.fromArguments()
        s.importFiles([media ?? folder.appendingPathComponent("sources/\(src.file)")])
        _ = await LayerDiagSelfTest.waitUntil(60) { s.importing == 0 && s.assets.count == 1 }
        guard let m = s.assets.first, let host = s.previewHost, let t = try? timeline(m, copies: media == nil ? 4 : 1) else { return }
        let probe = SpectrumPreviewProbe(store: s, view: host)
        probe.source = src
        _ = await load(s, probe, t, m)
        probe.geometryURL = folder.appendingPathComponent("marker-geometry-manual-\(stamp()).json")   // 멈춘 화면마다 기하를 덧붙여 씀
        probe.start()
        manualProbe = probe
        if CommandLine.arguments.contains("-OTFPauseReconcileManual") {   // 멈춤 맞춤 수동 비교(처음엔 꺼짐)
            let c = PauseReconcileManual(store: s, probe: probe, url: folder.appendingPathComponent("pause-events-manual-\(stamp()).json"))
            manualReconcile = c
            if CommandLine.arguments.contains("-OTFPauseReconcileManualCheck") {   // 실행 확인: 창 단추와 같은 동작을 꺼짐·켜짐 각 6번(경계 직전 4, 가운데 2) 부르고 끝냄
                func sleep(_ sec: Double) async { try? await Task.sleep(nanoseconds: UInt64(sec * 1e9)) }
                for on in [false, true] {
                    if c.enabled != on { c.toggleMode() }
                    for i in 0..<6 {
                        s.seek(to: 40 + i * 60); _ = await LayerDiagSelfTest.waitUntil(5) { !host.hasPendingSeeksForExperiment }; await sleep(0.3)
                        let before = c.eventCount
                        if i % 3 == 2 { c.pauseMid() } else { c.pauseNear() }
                        _ = await LayerDiagSelfTest.waitUntil(5) { c.eventCount > before && !s.isPlaying }
                        await sleep(0.3)
                    }
                }
                s.discardConfirmedForTest(); NSApp.terminate(nil); return
            }
        }
        s.discardConfirmedForTest()   // 창을 닫을 때 저장 질문 없이 닫힘(실험 프로젝트)
    }
    /// -OTFSpectrumPauseProbe(2026-10-24): 멈춘 뒤 1프레임 고정 어긋남 조사. 제품 재생 동작은 그대로(store.pause() 그대로 부름, 보정 탐색 없음).
    /// 회차마다: 무작위 자리로 탐색 → 무작위 0.4~1.6초 재생 → 멈춤 직전·직후 player.currentTime, store.pause() 뒤 재생 헤드, 그 뒤 600 ms 동안
    /// 콜백마다 속도·player 시각·재생 헤드·화면 프레임으로 아는 값·실제 표시 버퍼 원본 번호·스펙트럼 프레임·탐색 진행 여부를 적는다.
    struct PauseTick: Codable { let ms: Int; let rate: Float; let itemSec: Double; let playhead: Int; let displayedFrame: Int; let pendingSeek: Bool
        let layerSrc: Int?; let layerFrame: Int?; let shownK: Int? }
    struct PauseTrial: Codable { let trial: Int; let startFrame: Int; let playSec: Double
        let tBeforePause: Double; let tAfterPause: Double; let playheadAfterPause: Int; let fracInFrame: Double
        let preTicks: [PauseTick]; let ticks: [PauseTick]
        /// 150~600 ms 창: 실제 표시 프레임 − 재생 헤드(모두 같으면 고정 차이), 스펙트럼 프레임 − 재생 헤드
        let settledLayerMinusPlayhead: [Int]; let settledShownMinusPlayhead: [Int] }
    static func runPauseProbe(folder: URL, trials n: Int = 40) async {
        let s = ProjectStore.shared
        _ = await LayerDiagSelfTest.waitUntil(5) { s.editorWindow != nil }
        s.editorWindow?.orderFrontRegardless()
        s.importFiles([folder.appendingPathComponent("sources/otf-TA.mp4")])
        _ = await LayerDiagSelfTest.waitUntil(30) { s.importing == 0 && s.assets.count == 1 }
        var out: [PauseTrial] = []
        let url = folder.appendingPathComponent("pause-probe-\(stamp()).json")
        func write() { let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; if let d = try? enc.encode(out) { try? d.write(to: url) } }
        if let m = s.assets.first, let host = s.previewHost, let t = try? timeline(m) {
            let probe = SpectrumPreviewProbe(store: s, view: host)
            _ = await load(s, probe, t, m)
            probe.start()
            var buf: [PauseTick] = []
            /// 원본 번호 → 재생 헤드 근처(±8) 타임라인 프레임(4번 이어 붙여 원본 번호만으로는 정해지지 않음)
            func frameNear(_ src: Int?, _ ph: Int) -> Int? { src.flatMap { v in (ph - 8...ph + 8).first { probe.expectedSource($0) == v } } }
            probe.tickHook = { _ in
                let p = s.player, ph = s.playhead
                let ls = p.rate == 0 ? host.playerLayer.displayedPixelBuffer().flatMap { SpectrumPreviewProbe.readSource($0) } : nil
                buf.append(PauseTick(ms: probe.ms, rate: p.rate, itemSec: p.currentTime().seconds, playhead: ph, displayedFrame: host.displayedFrameForExperiment,
                                     pendingSeek: host.hasPendingSeeksForExperiment, layerSrc: ls, layerFrame: frameNear(ls, ph), shownK: probe.shownK))
            }
            var rng = SystemRandomNumberGenerator()
            for i in 0..<n {
                let f0 = Int.random(in: 0..<380, using: &rng), dur = Double.random(in: 0.4...1.6, using: &rng)
                s.seek(to: f0)
                _ = await LayerDiagSelfTest.waitUntil(5) { !host.hasPendingSeeksForExperiment && probe.shownK == f0 }
                try? await Task.sleep(nanoseconds: 200_000_000)
                s.play()
                try? await Task.sleep(nanoseconds: UInt64(dur * 1e9))
                buf = []
                try? await Task.sleep(nanoseconds: 60_000_000)   // 멈춤 직전 콜백 몇 개
                let pre = buf; buf = []
                let tb = s.player.currentTime().seconds
                s.pause()
                let ta = s.player.currentTime().seconds, ph = s.playhead
                let t0 = probe.ms
                try? await Task.sleep(nanoseconds: 600_000_000)
                let ticks = buf.map { PauseTick(ms: $0.ms - t0, rate: $0.rate, itemSec: $0.itemSec, playhead: $0.playhead, displayedFrame: $0.displayedFrame,
                                                pendingSeek: $0.pendingSeek, layerSrc: $0.layerSrc, layerFrame: $0.layerFrame, shownK: $0.shownK) }
                let settled = ticks.filter { $0.ms >= 150 }
                out.append(PauseTrial(trial: i, startFrame: f0, playSec: dur, tBeforePause: tb, tAfterPause: ta, playheadAfterPause: ph,
                                      fracInFrame: ta * 30 - (ta * 30).rounded(.down), preTicks: pre, ticks: ticks,
                                      settledLayerMinusPlayhead: settled.compactMap { $0.layerFrame.map { $0 - ph } },
                                      settledShownMinusPlayhead: settled.compactMap { $0.shownK.map { $0 - ph } }))
                write()
            }
            probe.tickHook = nil
            probe.stop()
        }
        write()
        s.discardConfirmedForTest()
        NSApp.terminate(nil)
    }
    /// -OTFSpectrumPauseReconcile(2026-10-24): 멈춤 맞춤 비교. 기준(baseline) = 제품 store.pause()만. 실험(reconcile) = store.pause() 뒤 그 재생 헤드로
    /// 기존 store.seek(to:)(정밀 탐색, 탐색 번호·완료 알림 그대로)를 한 번 더 요청. 제품 재생 경로는 바꾸지 않는다(이 함수 안에서만 탐색을 더 부른다).
    /// 같은 (시작 프레임, 재생 길이) 목록을 두 팔에 번갈아 쓰고, 지난 재현 회차(시작 82, 0.432초)를 넣는다. 멈춘 뒤 700 ms 콜백마다 실제 표시 버퍼를 읽는다.
    /// 그 밖: 빠른 멈춤·재개, 맞춤 탐색이 끝나기 전 새 탐색, 맞춤 중 프리뷰 항목 교체. 자막은 프레임마다 한 프레임 자막을 두고 자막 층 표시 상태(presentation)
    /// 불투명도로 선택된 자막 프레임을 읽는다(선택 상태 — 화면에 실제로 보였는지는 아님).
    struct RTick: Codable { let ms: Int; let rate: Float; let itemSec: Double; let playhead: Int; let displayedFrame: Int; let pendingSeek: Bool
        let layerFrame: Int?; let layerNil: Bool; let shownK: Int?; let subtitleSelected: Int?
        /// 실제 표시 버퍼의 원본 번호와 재생 헤드 프레임의 기대 원본 번호(원본 단위 비교, 2026-10-24 확대)
        let layerSrc: Int?; let expectedSrc: Int? }
    struct RTrial: Codable { let source: String; let arm: String; let scenario: String; let trial: Int; let startFrame: Int; let playSec: Double
        let tAfterPause: Double; let playheadAfterPause: Int; let intendedFrame: Int; let ticks: [RTick]
        let finalLayer: Int?; let finalShown: Int?; let finalSubtitle: Int?; let finalPlayhead: Int; let agreeMs: Int?; let persistentMismatch: Bool
        let layerSequence: [Int]; let pausedNilTicks: Int; let resumeItemSec: Double?; let note: String }
    struct LCG { var x: UInt64; mutating func next() -> Double { x = x &* 6364136223846793005 &+ 1442695040888963407; return Double(x >> 11) / Double(1 << 53) } }
    static func runPauseReconcile(folder: URL) async {
        let s = ProjectStore.shared
        _ = await LayerDiagSelfTest.waitUntil(5) { s.editorWindow != nil }
        s.editorWindow?.orderFrontRegardless()
        let src = ReconcileSource.fromArguments()
        s.importFiles([folder.appendingPathComponent("sources/\(src.file)")])
        _ = await LayerDiagSelfTest.waitUntil(30) { s.importing == 0 && s.assets.count == 1 }
        var out: [RTrial] = []
        let url = folder.appendingPathComponent("pause-reconcile-\((src.file as NSString).deletingPathExtension)-\(stamp()).json")
        func write() { let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; if let d = try? enc.encode(out) { try? d.write(to: url) } }
        guard let m = s.assets.first, let host = s.previewHost, let t1 = try? timeline(m, frameSubtitles: true),
              let t2 = try? timeline(m, trimFirst: 20, frameSubtitles: true) else { write(); NSApp.terminate(nil); return }
        let probe = SpectrumPreviewProbe(store: s, view: host)
        probe.source = src
        _ = await load(s, probe, t1, m)
        let D = t1.durationFrames
        probe.start()
        var buf: [RTick] = []
        /// 원본 번호 → 그 번호를 보이는 재생 헤드 근처(±8) 타임라인 프레임 중 재생 헤드에 가장 가까운 것(25·23.976 fps 원본은 한 원본이 여러 타임라인 프레임에 보임;
        /// 59.94 fps 원본의 홀수 번호처럼 어느 타임라인 프레임에도 속하지 않으면 nil — layerSrc에 원래 번호가 남는다)
        func frameNear(_ v: Int?, _ ph: Int) -> Int? { v.flatMap { v in (ph - 8...ph + 8).filter { probe.expectedSource($0) == v }.min { abs($0 - ph) < abs($1 - ph) } } }
        func subtitleSelected(_ ph: Int) -> Int? {
            for sub in s.timeline.subtitles where abs(sub.start - ph) <= 3 {
                if let l = host.subtitleLayerForTest(sub.id), (l.presentation()?.opacity ?? 0) > 0.5 { return sub.start }
            }
            return nil
        }
        probe.tickHook = { _ in
            let p = s.player, ph = s.playhead
            let pb = p.rate == 0 ? host.playerLayer.displayedPixelBuffer() : nil, ls = pb.flatMap(probe.readSrc)
            buf.append(RTick(ms: probe.ms, rate: p.rate, itemSec: p.currentTime().seconds, playhead: ph, displayedFrame: host.displayedFrameForExperiment,
                             pendingSeek: host.hasPendingSeeksForExperiment, layerFrame: frameNear(ls, ph),
                             layerNil: p.rate == 0 && pb == nil, shownK: probe.shownK, subtitleSelected: subtitleSelected(ph), layerSrc: ls, expectedSrc: probe.expectedSource(ph)))
        }
        func sleep(_ sec: Double) async { try? await Task.sleep(nanoseconds: UInt64(sec * 1e9)) }
        func settleAt(_ f: Int) async { s.seek(to: f); _ = await LayerDiagSelfTest.waitUntil(5) { !host.hasPendingSeeksForExperiment && probe.shownK == f }; await sleep(0.2) }
        /// 멈춘 뒤 관찰을 한 회차 기록으로
        func record(arm: String, scenario: String, i: Int, f0: Int, dur: Double, ta: Double, ph: Int, intended: Int, t0: Int, resume: Double?, note: String) {
            let ticks = buf.map { RTick(ms: $0.ms - t0, rate: $0.rate, itemSec: $0.itemSec, playhead: $0.playhead, displayedFrame: $0.displayedFrame, pendingSeek: $0.pendingSeek,
                                        layerFrame: $0.layerFrame, layerNil: $0.layerNil, shownK: $0.shownK, subtitleSelected: $0.subtitleSelected, layerSrc: $0.layerSrc, expectedSrc: $0.expectedSrc) }
            let paused = ticks.filter { $0.rate == 0 }
            func ok(_ x: RTick) -> Bool { x.layerFrame != nil && x.layerFrame == x.playhead && x.shownK == x.playhead && x.playhead == intended }
            var agree: Int? = nil
            for (j, x) in paused.enumerated() where ok(x) && paused[j...].allSatisfy(ok) { agree = x.ms; break }
            let tail = paused.filter { $0.ms >= 400 }
            var seq: [Int] = []; for x in paused { if let f = x.layerFrame, seq.last != f { seq.append(f) } }
            let last = paused.last
            out.append(RTrial(source: src.file, arm: arm, scenario: scenario, trial: i, startFrame: f0, playSec: dur, tAfterPause: ta, playheadAfterPause: ph, intendedFrame: intended, ticks: ticks,
                              finalLayer: last?.layerFrame, finalShown: last?.shownK, finalSubtitle: last?.subtitleSelected, finalPlayhead: last?.playhead ?? -1, agreeMs: agree,
                              persistentMismatch: !tail.isEmpty && tail.allSatisfy { !ok($0) }, layerSequence: seq, pausedNilTicks: paused.filter(\.layerNil).count,
                              resumeItemSec: resume, note: note))
            write()
        }
        // 1) 같은 자리·길이로 두 팔(번갈아 순서를 바꿈)
        var g = LCG(x: 20261024)
        var plan: [(Int, Double)] = [(82, 0.43203078358719116)]
        for _ in 0..<49 { plan.append((Int(g.next() * Double(D - 100)), 0.4 + g.next() * 1.2)) }
        for (i, (f0, dur)) in plan.enumerated() {
            for arm in (i % 2 == 0 ? ["baseline", "reconcile"] : ["reconcile", "baseline"]) {
                await settleAt(f0)
                s.play(); await sleep(dur)
                s.pause()
                let ta = s.player.currentTime().seconds, ph = s.playhead
                buf = []; let t0 = probe.ms
                if arm == "reconcile" { s.seek(to: ph) }
                await sleep(0.7)
                let resume = s.player.currentTime().seconds   // 재개가 시작할 시각(재생 직전 player 시각)
                record(arm: arm, scenario: "pause", i: i, f0: f0, dur: dur, ta: ta, ph: ph, intended: ph, t0: t0, resume: resume, note: "")
                s.play(); await sleep(0.15); s.pause()
            }
        }
        // 2) 빠른 멈춤·재개(맞춤 탐색 중 재생) → 0.3초 뒤 다시 멈춤·맞춤
        for i in 0..<10 {
            let f0 = Int(g.next() * Double(D - 100)); await settleAt(f0)
            s.play(); await sleep(0.5 + g.next() * 0.5)
            s.pause(); s.seek(to: s.playhead)
            await sleep(0.005); s.play()
            await sleep(0.3)
            let stillPlaying = s.player.rate != 0, itemAfter = s.player.currentTime().seconds
            s.pause()
            let ta = s.player.currentTime().seconds, ph = s.playhead
            buf = []; let t0 = probe.ms
            s.seek(to: ph)
            await sleep(0.7)
            record(arm: "reconcile", scenario: "rapid-resume", i: i, f0: f0, dur: 0, ta: ta, ph: ph, intended: ph, t0: t0, resume: nil,
                   note: "resumed-playing \(stillPlaying) item-after-resume \(String(format: "%.3f", itemAfter * 30))f")
        }
        // 3) 맞춤 탐색이 끝나기 전 새 탐색(사용자 의도가 이김)
        for i in 0..<10 {
            let f0 = Int(g.next() * Double(D - 100)), gTarget = Int(g.next() * Double(D - 10)); await settleAt(f0)
            s.play(); await sleep(0.5 + g.next() * 0.5)
            s.pause()
            let ta = s.player.currentTime().seconds, ph = s.playhead
            buf = []; let t0 = probe.ms
            s.seek(to: ph); s.seek(to: gTarget)
            await sleep(0.7)
            record(arm: "reconcile", scenario: "seek-before-correction", i: i, f0: f0, dur: 0, ta: ta, ph: ph, intended: gTarget, t0: t0, resume: nil, note: "")
        }
        // 4) 맞춤 탐색 중 프리뷰 항목 교체(같은 프로젝트의 새 회차) — 교체 뒤 재생 헤드가 의도
        for i in 0..<5 {
            let f0 = Int(g.next() * Double(D - 180)); await settleAt(f0)
            s.play(); await sleep(0.5 + g.next() * 0.5)
            s.pause()
            let ta = s.player.currentTime().seconds, ph = s.playhead
            buf = []; let t0 = probe.ms
            s.seek(to: ph)
            _ = await load(s, probe, i % 2 == 0 ? t2 : t1, m)
            await sleep(0.7)
            record(arm: "reconcile", scenario: "item-replace", i: i, f0: f0, dur: 0, ta: ta, ph: ph, intended: s.playhead, t0: t0, resume: nil,
                   note: "timeline \(i % 2 == 0 ? "t2(trim 20)" : "t1")")
        }
        probe.tickHook = nil
        probe.stop()
        s.discardConfirmedForTest()
        NSApp.terminate(nil)
    }
    /// -OTFSpectrumPausePhase(2026-10-24, 측정만): 멈춤 위상 쓸기. 제품 store.pause()를 경계 관찰자로 정한 위상에 부르고(미루기·탐색 없음) 멈춘 뒤 700 ms
    /// 콜백마다 실제 표시 버퍼 원본 번호·재생 헤드 기대 원본·스펙트럼 프레임을 적는다. 목표 21개(넓게 φ 0.05…0.95 10개 + 경계 앞 0.5…10 ms 11개) × 4회 = 원본당 84회.
    /// 3초 안에 관찰자가 불리지 않으면 no-fire로 적는다(빼지 않음). 분류는 실제 멈춘 시각(멈춤 직후 player 시각)의 위상으로 한다.
    struct PhaseTrial: Codable { let source: String; let trial: Int; let targetKind: String; let targetValue: Double; let startFrame: Int; let leadFrames: Int
        let targetSec: Double; let fired: Bool; let tBeforePause: Double?; let tAfterPause: Double?; let firedMs: Int?; let playhead: Int?
        let ticks: [RTick]; let agreeMs: Int?; let persistentMismatch: Bool; let readableTicks: Int; let nilTicks: Int; let unreadableTicks: Int
        let finalLayerSrc: Int?; let finalExpectedSrc: Int?; let finalShownK: Int? }
    struct PhaseRun: Codable { let source: String; var maxFPS: Int; var backingScale: Double; var linkIntervalsMs: [Double]; var trials: [PhaseTrial] }
    static func runPausePhase(folder: URL) async {
        let s = ProjectStore.shared
        _ = await LayerDiagSelfTest.waitUntil(5) { s.editorWindow != nil }
        s.editorWindow?.orderFrontRegardless()
        let src = ReconcileSource.fromArguments()
        s.importFiles([folder.appendingPathComponent("sources/\(src.file)")])
        _ = await LayerDiagSelfTest.waitUntil(30) { s.importing == 0 && s.assets.count == 1 }
        var run = PhaseRun(source: src.file, maxFPS: s.editorWindow?.screen?.maximumFramesPerSecond ?? -1, backingScale: Double(s.editorWindow?.backingScaleFactor ?? 0), linkIntervalsMs: [], trials: [])
        let url = folder.appendingPathComponent("pause-phase-\((src.file as NSString).deletingPathExtension)-\(stamp()).json")
        func write() { let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; if let d = try? enc.encode(run) { try? d.write(to: url) } }
        guard let m = s.assets.first, let host = s.previewHost, let t1 = try? timeline(m) else { write(); NSApp.terminate(nil); return }
        let probe = SpectrumPreviewProbe(store: s, view: host)
        probe.source = src
        _ = await load(s, probe, t1, m)
        let D = t1.durationFrames
        probe.start()
        var buf: [RTick] = [], lastLink: CFTimeInterval?, intervals: [Double] = []
        func frameNear(_ v: Int?, _ ph: Int) -> Int? { v.flatMap { v in (ph - 8...ph + 8).filter { probe.expectedSource($0) == v }.min { abs($0 - ph) < abs($1 - ph) } } }
        probe.tickHook = { l in
            if let p = lastLink, intervals.count < 4000 { intervals.append((l.timestamp - p) * 1000) }; lastLink = l.timestamp
            let p = s.player, ph = s.playhead
            let pb = p.rate == 0 ? host.playerLayer.displayedPixelBuffer() : nil, ls = pb.flatMap(probe.readSrc)
            buf.append(RTick(ms: probe.ms, rate: p.rate, itemSec: p.currentTime().seconds, playhead: ph, displayedFrame: host.displayedFrameForExperiment,
                             pendingSeek: host.hasPendingSeeksForExperiment, layerFrame: frameNear(ls, ph), layerNil: p.rate == 0 && pb == nil, shownK: probe.shownK,
                             subtitleSelected: nil, layerSrc: ls, expectedSrc: probe.expectedSource(ph)))
        }
        func sleep(_ sec: Double) async { try? await Task.sleep(nanoseconds: UInt64(sec * 1e9)) }
        var targets: [(String, Double)] = (0..<10).map { ("phase", 0.05 + 0.1 * Double($0)) }
        targets += [0.5, 1, 1.5, 2, 3, 4, 5, 6, 7, 8, 10].map { ("msBeforeBoundary", $0) }
        var g = LCG(x: 20261024 &+ UInt64(src.id))
        var plan: [(Int, Double)] = []
        for _ in 0..<4 { for (i, t) in targets.enumerated() { plan.append((i, t.1)) } }
        for (n, (ti, _)) in plan.enumerated() {
            let (kind, val) = targets[ti]
            let f0 = Int(g.next() * Double(D - 60)), lead = 14 + Int(g.next() * 9)
            s.seek(to: f0); _ = await LayerDiagSelfTest.waitUntil(5) { !host.hasPendingSeeksForExperiment && probe.shownK == f0 }; await sleep(0.2)
            let n0 = f0 + lead
            let tsec = kind == "phase" ? (Double(n0) + val) / 30 : Double(n0 + 1) / 30 - val / 1000
            var fired = false, tb: Double?, ta: Double?, at: Int?, ph: Int?
            nonisolated(unsafe) var obsToken: Any?
            s.play()
            obsToken = s.player.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: tsec, preferredTimescale: 600_000))], queue: .main) {
                MainActor.assumeIsolated {
                    guard !fired else { return }
                    fired = true
                    tb = s.player.currentTime().seconds
                    s.pause()
                    ta = s.player.currentTime().seconds; ph = s.playhead; at = probe.ms; buf = []
                }
            }
            _ = await LayerDiagSelfTest.waitUntil(3) { fired }
            if let o = obsToken { s.player.removeTimeObserver(o) }
            if !fired { s.pause() }
            await sleep(0.7)
            let t0 = at ?? probe.ms
            let ticks = buf.map { RTick(ms: $0.ms - t0, rate: $0.rate, itemSec: $0.itemSec, playhead: $0.playhead, displayedFrame: $0.displayedFrame, pendingSeek: $0.pendingSeek,
                                        layerFrame: $0.layerFrame, layerNil: $0.layerNil, shownK: $0.shownK, subtitleSelected: nil, layerSrc: $0.layerSrc, expectedSrc: $0.expectedSrc) }
            let paused = ticks.filter { $0.rate == 0 }
            func ok(_ x: RTick) -> Bool { x.layerSrc != nil && x.layerSrc == x.expectedSrc && x.shownK == x.playhead }
            var agree: Int? = nil
            for (j, x) in paused.enumerated() where ok(x) && paused[j...].allSatisfy(ok) { agree = x.ms; break }
            let tail = paused.filter { $0.ms >= 400 && $0.layerSrc != nil }
            run.trials.append(PhaseTrial(source: src.file, trial: n, targetKind: kind, targetValue: val, startFrame: f0, leadFrames: lead, targetSec: tsec, fired: fired,
                tBeforePause: tb, tAfterPause: ta, firedMs: at, playhead: ph, ticks: ticks, agreeMs: fired ? agree : nil,
                persistentMismatch: fired && !tail.isEmpty && tail.allSatisfy { !ok($0) }, readableTicks: paused.filter { $0.layerSrc != nil }.count,
                nilTicks: paused.filter(\.layerNil).count, unreadableTicks: paused.filter { !$0.layerNil && $0.layerSrc == nil }.count,
                finalLayerSrc: paused.last?.layerSrc, finalExpectedSrc: paused.last?.expectedSrc, finalShownK: paused.last?.shownK))
            run.linkIntervalsMs = intervals
            write()
        }
        probe.tickHook = nil
        probe.stop()
        write()
        s.discardConfirmedForTest()
        NSApp.terminate(nil)
    }
    // MARK: 실제 미디어 점검(2026-10-24, Debug 측정 도구 — 제품 경로 아님)
    /// 멈춘 표시 버퍼가 어느 타임라인 프레임인지: 같은 항목의 composition·videoComposition을 AVAssetImageGenerator로 허용 오차 0에서 그린
    /// 후보 k−1…k+2와 전체 해상도 휘도로 비교한다. 후보끼리 20 넘게 다른 화소만 쓴다(마스크). 마스크 30 화소 미만 = 가릴 수 없음,
    /// 가장 가까운 후보 거리 < 둘째의 0.5배 = 판별, 아니면 애매. 기준 그림과 표시 버퍼의 색 변환이 같다는 보장은 없다 — fixture(otf-TA)에서 화면 코드와 대조해 검증한다.
    struct IDResult: Codable { let candidates: [Int]; let dist: [Double]; let mask: Int; let best: Int?; let status: String }
    nonisolated static func surfaceID(_ pb: CVPixelBuffer) -> UInt32? { CVPixelBufferGetIOSurface(pb).map { IOSurfaceGetID($0.takeUnretainedValue()) } }
    nonisolated static func luma(_ pb: CVPixelBuffer) -> [UInt8]? {
        SpectrumPreviewProbe.withRGB(pb) { rgb, w, h in
            guard w == 1920, h == 1080 else { return nil }
            var out = [UInt8](repeating: 0, count: w * h)
            for y in 0..<h { for x in 0..<w { if let c = rgb(x, y) { out[y * w + x] = UInt8(max(0, min(255, 0.2126 * c.0 + 0.7152 * c.1 + 0.0722 * c.2))) } } }
            return out
        }
    }
    nonisolated static func luma(_ img: CGImage) -> [UInt8]? {
        let w = 1920, h = 1080
        guard img.width == w, img.height == h, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let d = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var out = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) { let q = d + i * 4; out[i] = UInt8(max(0, min(255, 0.2126 * Double(q[2]) + 0.7152 * Double(q[1]) + 0.0722 * Double(q[0])))) }
        return out
    }
    nonisolated static func identify(_ disp: [UInt8]?, _ refs: [(Int, [UInt8])]) -> IDResult {
        let ks = refs.map(\.0)
        guard let disp, refs.count >= 2 else { return IDResult(candidates: ks, dist: [], mask: 0, best: nil, status: "unavailable") }
        var sums = [Double](repeating: 0, count: refs.count), n = 0
        for i in 0..<disp.count {
            var lo = 255, hi = 0
            for r in refs { let v = Int(r.1[i]); lo = min(lo, v); hi = max(hi, v) }
            guard hi - lo > 20 else { continue }
            n += 1
            for (j, r) in refs.enumerated() { sums[j] += Double(abs(Int(disp[i]) - Int(r.1[i]))) }
        }
        guard n >= 30 else { return IDResult(candidates: ks, dist: [], mask: n, best: nil, status: "indistinguishable") }
        let d = sums.map { $0 / Double(n) }
        let order = d.indices.sorted { d[$0] < d[$1] }
        let ok = d[order[0]] < 0.5 * d[order[1]]
        return IDResult(candidates: ks, dist: d.map { ($0 * 100).rounded() / 100 }, mask: n, best: ok ? ks[order[0]] : nil, status: ok ? "identified" : "ambiguous")
    }
    struct RealTick: Codable { let ms: Int; let rate: Float; let playhead: Int; let pendingSeek: Bool; let bufferID: UInt32?; let nilBuffer: Bool; let codeSrc: Int? }
    struct RealTrial: Codable { let source: String; let arm: String; let kind: String; let trial: Int; let startFrame: Int; let targetSec: Double?
        let tBeforePause: Double; let tAfterPause: Double; let msToNextBoundary: Double; let playhead: Int; let ticks: [RealTick]
        let bufferChanges: Int; let lastChangeMs: Int?; let early: IDResult; let final: IDResult; let earlyMs: Int?; let finalMs: Int?
        /// fixture에서만: 화면 코드(실제 표시 원본)와 후보 프레임들의 기대 원본(판별 검증용)
        let codeEarly: Int?; let codeFinal: Int?; let codeOfCandidates: [Int?]; let resumeItemSec: Double; let refMs: Int }
    /// -OTFRealMediaCheck: 멈춤 비교(기준·맞춤 번갈아) 회차 20 × 2팔. 짝수 회차 = 0.4–1.6초 재생 뒤 멈춤, 홀수 = 경계 1.5 ms 앞을 노린 경계 관찰자 멈춤.
    static func runRealCheck(folder: URL, media: URL?) async {
        let s = ProjectStore.shared
        _ = await LayerDiagSelfTest.waitUntil(5) { s.editorWindow != nil }
        s.editorWindow?.orderFrontRegardless()
        let src = media.map(ReconcileSource.real) ?? ReconcileSource.fromArguments()
        s.importFiles([media ?? folder.appendingPathComponent("sources/\(src.file)")])
        _ = await LayerDiagSelfTest.waitUntil(60) { s.importing == 0 && s.assets.count == 1 }
        var out: [RealTrial] = []
        let url = folder.appendingPathComponent("real-check-\(media == nil ? (src.file as NSString).deletingPathExtension : "media")-\(stamp()).json")
        func write() { let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; if let d = try? enc.encode(out) { try? d.write(to: url) } }
        guard let m = s.assets.first, let host = s.previewHost, let t1 = try? timeline(m, copies: media == nil ? 4 : 1) else { write(); NSApp.terminate(nil); return }
        let probe = SpectrumPreviewProbe(store: s, view: host)
        probe.source = src
        _ = await load(s, probe, t1, m)
        let D = t1.durationFrames
        probe.start()
        var buf: [RealTick] = [], first: (Int, CVPixelBuffer)?, last: (Int, CVPixelBuffer)?, t0 = 0, epoch = 0, seenEpoch = 0
        probe.tickHook = { _ in
            if seenEpoch != epoch { seenEpoch = epoch; first = nil; last = nil }   // 멈춤마다 표본을 새로(관찰자 블록에서는 정수만 바꾼다)
            let p = s.player, pb = p.rate == 0 ? host.playerLayer.displayedPixelBuffer() : nil
            let ms = probe.ms - t0
            if let pb { if first == nil { first = (ms, pb) }; last = (ms, pb) }
            buf.append(RealTick(ms: ms, rate: p.rate, playhead: s.playhead, pendingSeek: host.hasPendingSeeksForExperiment, bufferID: pb.flatMap(surfaceID),
                                nilBuffer: p.rate == 0 && pb == nil, codeSrc: src.hasCode ? pb.flatMap(probe.readSrc) : nil))
        }
        func sleep(_ sec: Double) async { try? await Task.sleep(nanoseconds: UInt64(sec * 1e9)) }
        var g = LCG(x: 20261024 &+ 7)
        for i in 0..<20 {
            let f0 = Int(g.next() * Double(D - 120)), dur = 0.4 + g.next() * 1.2, lead = 14 + Int(g.next() * 9), targeted = i % 2 == 1
            for arm in (i % 4 < 2 ? ["baseline", "reconcile"] : ["reconcile", "baseline"]) {
                s.seek(to: f0); _ = await LayerDiagSelfTest.waitUntil(5) { !host.hasPendingSeeksForExperiment }; await sleep(0.3)
                var fired = false, tb = 0.0, ta = 0.0, ph = 0
                let tsec = Double(f0 + lead + 1) / 30 - 0.0015
                func doPause() { tb = s.player.currentTime().seconds; s.pause(); ta = s.player.currentTime().seconds; ph = s.playhead
                    buf = []; epoch += 1; t0 = probe.ms; fired = true
                    if arm == "reconcile" { s.seek(to: ph) } }
                s.play()
                if targeted {
                    nonisolated(unsafe) var tok: Any?
                    tok = s.player.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: tsec, preferredTimescale: 600_000))], queue: .main) {
                        MainActor.assumeIsolated {
                            guard !fired else { return }
                            tb = s.player.currentTime().seconds; s.pause(); ta = s.player.currentTime().seconds; ph = s.playhead
                            buf = []; epoch += 1; t0 = probe.ms; fired = true
                            if arm == "reconcile" { s.seek(to: ph) }
                        }
                    }
                    _ = await LayerDiagSelfTest.waitUntil(3) { fired }
                    if let o = tok { s.player.removeTimeObserver(o) }
                    if !fired { doPause() }
                } else { await sleep(dur); doPause() }
                await sleep(0.7)
                let ticks = buf, fb = first, lb = last
                let resume = s.player.currentTime().seconds
                let rt0 = probe.ms
                let cands = [ph - 1, ph, ph + 1, ph + 2].filter { $0 >= 0 && $0 < D }
                var refs: [(Int, [UInt8])] = []
                if let item = s.player.currentItem {
                    let gen = AVAssetImageGenerator(asset: item.asset)
                    gen.videoComposition = item.videoComposition
                    gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
                    for k in cands { if let img = try? await gen.image(at: s.settings.time(k)).image, let l = luma(img) { refs.append((k, l)) } }
                }
                let early = identify(fb.flatMap { luma($0.1) }, refs), final = identify(lb.flatMap { luma($0.1) }, refs)
                let ids = ticks.compactMap(\.bufferID)
                var lastChange: Int?
                for (a, b) in zip(ticks.filter { $0.bufferID != nil }, ticks.filter { $0.bufferID != nil }.dropFirst()) where a.bufferID != b.bufferID { lastChange = b.ms }
                out.append(RealTrial(source: src.file, arm: arm, kind: targeted ? "near-boundary" : "natural", trial: i, startFrame: f0, targetSec: targeted ? tsec : nil,
                    tBeforePause: tb, tAfterPause: ta, msToNextBoundary: (((ta * 30).rounded(.down) + 1) / 30 - ta) * 1000, playhead: ph, ticks: ticks,
                    bufferChanges: zip(ids, ids.dropFirst()).filter { $0 != $1 }.count, lastChangeMs: lastChange, early: early, final: final,
                    earlyMs: fb?.0, finalMs: lb?.0, codeEarly: src.hasCode ? fb.flatMap { probe.readSrc($0.1) } : nil, codeFinal: src.hasCode ? lb.flatMap { probe.readSrc($0.1) } : nil,
                    codeOfCandidates: cands.map { src.hasCode ? probe.expectedSource($0) : nil }, resumeItemSec: resume, refMs: probe.ms - rt0))
                write()
            }
        }
        probe.tickHook = nil
        probe.stop()
        write()
        s.discardConfirmedForTest()
        NSApp.terminate(nil)
    }
    static func stamp() -> String { let f = ISO8601DateFormatter(); f.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]; return f.string(from: Date()).replacingOccurrences(of: ":", with: "") }
    /// -OTFSpectrumMarkerGeometry: 수동 확인과 같은 창 설정으로 열어 멈춘 프레임 몇 곳(한 칸 이동 포함)의 기하를 <폴더>/marker-geometry-auto-<시각>.json에 쓰고 끝낸다.
    static func runGeometry(folder: URL) async {
        let s = ProjectStore.shared
        _ = await LayerDiagSelfTest.waitUntil(5) { s.editorWindow != nil }
        s.editorWindow?.orderFrontRegardless()
        s.importFiles([folder.appendingPathComponent("sources/otf-TA.mp4")])
        _ = await LayerDiagSelfTest.waitUntil(30) { s.importing == 0 && s.assets.count == 1 }
        if let m = s.assets.first, let host = s.previewHost, let t = try? timeline(m) {
            let probe = SpectrumPreviewProbe(store: s, view: host)
            probe.geometryURL = folder.appendingPathComponent("marker-geometry-auto-\(stamp()).json")
            _ = await load(s, probe, t, m)
            probe.start()
            for f in [0, 37, 100, 237, 238, 239, 401] {
                s.seek(to: f)
                _ = await LayerDiagSelfTest.waitUntil(5) { probe.shownK == f && !host.hasPendingSeeksForExperiment }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            probe.stop()
        }
        s.discardConfirmedForTest()
        NSApp.terminate(nil)
    }
    static var manualProbe: SpectrumPreviewProbe?

    static func run(folder: URL) async {
        let s = ProjectStore.shared
        var r = Result(checks: [], phases: [], resources: [], notes: [], samples: [])
        func check(_ n: String, _ p: Bool, _ d: String = "") { r.checks.append(Check(name: n, pass: p, detail: d)) }
        _ = await LayerDiagSelfTest.waitUntil(5) { s.editorWindow != nil }
        s.editorWindow?.orderFrontRegardless()   // 가려지면 화면 갱신이 줄 수 있다 — 활성화(초점)는 하지 않음
        r.notes.append("window occlusion visible at start: \(s.editorWindow?.occlusionState.contains(.visible) ?? false)")
        s.importFiles([folder.appendingPathComponent("sources/otf-TA.mp4")])
        _ = await LayerDiagSelfTest.waitUntil(30) { s.importing == 0 && s.assets.count == 1 }
        guard let m = s.assets.first, let host = s.previewHost, let t1 = try? timeline(m), let t2 = try? timeline(m, trimFirst: 20) else {
            r.checks.append(Check(name: "setup", pass: false, detail: "")); return finish(folder, r)
        }
        let probe = SpectrumPreviewProbe(store: s, view: host)
        func res(_ label: String) {
            r.resources.append(Resource(label: label, footprintMB: SpectrumPreviewProbe.footprintMB(), bandCacheEntries: probe.cacheBytes / 256, bandCacheBytes: probe.cacheBytes,
                                        pending: probe.pendingCount, imageBytes: probe.shownImageBytes))
        }
        res("baseline (imported, before spectrum)")
        guard await load(s, probe, t1, m) != nil else { r.checks.append(Check(name: "setup.load", pass: false, detail: "")); return finish(folder, r) }
        probe.start()
        func sleep(_ sec: Double) async { try? await Task.sleep(nanoseconds: UInt64(sec * 1e9)) }
        func settled() async { _ = await LayerDiagSelfTest.waitUntil(5) { !host.hasPendingSeeksForExperiment && probe.pendingCount == 0 } }
        probe.recording = true
        var rng = SystemRandomNumberGenerator()

        // 1) 멈춤에서 시작
        probe.phase = "initial-pause"; s.seek(to: 0); await settled(); await sleep(0.5)
        // 2) 재생 3초 → 멈춤
        probe.phase = "playback-1"; s.play(); await sleep(3.0)
        probe.phase = "pause-after-play"; s.pause(); await sleep(0.5)
        // 3) 탐색 12번(각 0.4초 관찰)
        probe.phase = "seeks"
        for _ in 0..<12 { s.seek(to: Int.random(in: 0..<470, using: &rng)); await sleep(0.4) }
        // 4) 빠른 탐색 30번(약 10 ms 간격) → 가라앉음
        probe.phase = "rapid-seeks"
        for _ in 0..<30 { s.seek(to: Int.random(in: 0..<470, using: &rng)); await sleep(0.01) }
        probe.phase = "after-rapid-seeks"; await settled(); await sleep(0.6)
        // 5) 한 칸씩(0.15초 간격)
        probe.phase = "steps"; s.seek(to: 200); await settled()
        for _ in 0..<10 { s.step(1); await sleep(0.15) }
        // 6) 재생 재개·멈춤 반복(멈춘 자리 실제 표시 비교)
        for i in 0..<8 {
            probe.phase = "resume-play-\(i)"; s.play(); await sleep(Double.random(in: 0.6...1.4, using: &rng))
            probe.phase = "resume-pause-\(i)"; s.pause(); await sleep(0.4)
        }
        res("after scripted phases")

        // 7) 늦은 분석 결과가 새 탐색의 그림을 바꾸지 않음: B는 미리 분석해 둠, A는 0.5초 늦춤 → A 탐색 직후 B 탐색
        probe.phase = "stale-seek"
        let A = 333, B = 211
        probe.clearCache()
        s.seek(to: B); await settled(); await sleep(0.2)
        let bShown = probe.shownK == B
        probe.delayForFrame[A] = 0.5
        let lateBefore = probe.lateCompletions.count
        s.seek(to: A); await sleep(0.04)
        s.seek(to: B)
        let bSeekAt = probe.ms
        await sleep(1.0)
        let late = probe.lateCompletions.dropFirst(lateBefore).filter { $0.k == A }
        let shownAAfterB = probe.samples.filter { $0.phase == "stale-seek" && $0.ms > bSeekAt + 100 && $0.shown == A }.count
        check("stale-seek.late-completion-happened", !late.isEmpty, "A(\(A)) 분석이 B 탐색 뒤 \(late.first.map { "\($0.ms - bSeekAt) ms" } ?? "-")에 끝남(늦은 결과)")
        check("stale-seek.no-replace", bShown && probe.shownK == B && shownAAfterB == 0, "끝 shown \(probe.shownK.map(String.init) ?? "nil"), B 탐색 100 ms 뒤 A를 보인 콜백 \(shownAAfterB)")
        probe.delayForFrame = [:]

        // 8) 세션(항목) 바꿈: 분석 진행 중에 타임라인을 바꾸면 이전 세션 결과를 버리고 새 조각으로 분석
        probe.phase = "session-switch"
        let C = 10   // t1: 원본 10(클릭 없음), t2(첫 클립 앞 20 트림): 원본 30(클릭)
        probe.clearCache(); probe.delayForFrame[C] = 0.4
        s.seek(to: C); await sleep(0.05)
        let staleBefore = probe.staleDropped
        guard await load(s, probe, t2, m) != nil else { r.checks.append(Check(name: "session.load", pass: false, detail: "")); return finish(folder, r) }
        probe.delayForFrame = [:]
        s.seek(to: C); await settled(); await sleep(0.6)
        let newBands = probe.shownBands
        let direct = try? ProtoAnalyzer(source: ProtoPCMSource(url: m.url)).bands(frame: C, pieces: s.timeline.audioClips
            .map { ProtoPiece(start: $0.start, length: $0.length, sourceIn: $0.sourceIn, audio: $0.audio ?? .default, laneGain: 1) })
        let oldDirect = try? ProtoAnalyzer(source: ProtoPCMSource(url: m.url)).bands(frame: C, pieces: [ProtoPiece(start: 0, length: 120, sourceIn: 0, audio: .default, laneGain: 1)])
        check("session.stale-dropped", probe.staleDropped > staleBefore, "이전 세션 결과 버림 \(probe.staleDropped - staleBefore)")
        r.notes.append("session: pieces \(probe.pieceCount), shown max \(newBands?.max() ?? -1), direct max \(direct?.max() ?? -1), old max \(oldDirect?.max() ?? -1)")
        check("session.new-analysis-shown", probe.shownK == C && newBands != nil && newBands == direct && direct != oldDirect && (direct?.max() ?? 0) > 0,
              "보인 값 = 새 타임라인 직접 분석: \(newBands == direct), 이전 타임라인 값과 다름: \(direct != oldDirect), 원본 \(probe.expectedSource(C).map(String.init) ?? "nil")")

        // 9) 자원: 재생 2초 + 탐색 10번 × 4차례, 그 뒤 2초 쉼
        for round in 0..<4 {
            probe.phase = "resource-\(round)"
            s.seek(to: Int.random(in: 0..<300, using: &rng)); await settled(); s.play(); await sleep(2.0); s.pause()
            for _ in 0..<10 { s.seek(to: Int.random(in: 0..<470, using: &rng)); await sleep(0.05) }
            await settled(); res("resource round \(round)")
        }
        probe.phase = "idle"; await sleep(2.0); res("settled (2 s idle)")
        probe.recording = false

        // 집계
        let phases = Array(NSOrderedSet(array: probe.samples.map(\.phase))) as! [String]
        for ph in phases {
            let xs = probe.samples.filter { $0.phase == ph }
            var compared = 0, mis = 0, blank = 0, unread = 0, first: [String] = [], kinds = Set<String>()
            for x in xs {
                guard let e = x.expectedSrc else { blank += 1; continue }
                let obs = x.layerSrc ?? x.outputSrc
                if x.layerSrc != nil { kinds.insert("layer(actual)") } else if x.outputSrc != nil { kinds.insert("output(proxy)") }
                guard let o = obs else { unread += 1; continue }
                compared += 1
                if o != e { mis += 1; if first.count < 12 { first.append("\(x.ms)ms \(x.playing ? "play" : "pause") shown \(x.shown!) exp src \(e) obs \(o)\(x.pendingSeek ? " seeking" : "")") } }
            }
            r.phases.append(PhaseStat(phase: ph, samples: xs.count, compared: compared, mismatches: mis, blank: blank, unreadable: unread, kind: kinds.sorted().joined(separator: "+"), firstMismatches: first))
        }
        // 분류: 멈춤(탐색 진행 중 아님) / 멈춤·탐색 진행 중 / 재생 150 ms 뒤·출력 새것(≤ 70 ms) / 재생 시작 150 ms 안 / 출력 오래됨(대리 없음)
        let paused = probe.samples.filter { !$0.playing && $0.layerSrc != nil && $0.expectedSrc != nil }
        let steadyP = paused.filter { !$0.pendingSeek }, seekP = paused.filter { $0.pendingSeek }
        let playing = probe.samples.filter { $0.playing && $0.outputSrc != nil && $0.expectedSrc != nil }
        let fresh = playing.filter { ($0.outputAgeMs ?? 999) <= 70 }, stale = playing.count - fresh.count
        let steadyO = fresh.filter { ($0.sincePlayMs ?? 0) >= 150 }, startO = fresh.filter { ($0.sincePlayMs ?? 0) < 150 }
        func mis(_ xs: [SpectrumPreviewProbe.Sample]) -> Int { xs.filter { ($0.layerSrc ?? $0.outputSrc) != $0.expectedSrc }.count }
        check("paused.no-pending-seek.actual-layer", mis(steadyP) == 0, "멈춤(탐색 진행 중 아님) 콜백 \(steadyP.count)개 중 불일치 \(mis(steadyP))(실제 표시 버퍼)")
        check("paused.seek-in-progress.actual-layer", mis(seekP) == 0, "탐색 진행 중 콜백 \(seekP.count)개 중 불일치 \(mis(seekP))(실제 표시 버퍼)")
        check("playing.steady.output-proxy", mis(steadyO) == 0, "재생 150 ms 뒤 콜백 \(steadyO.count)개 중 불일치 \(mis(steadyO))(대리; 출력이 70 ms 넘게 새 버퍼를 주지 않은 콜백 \(stale)개는 뺌)")
        check("playing.start.output-proxy", mis(startO) == 0, "재생 시작 150 ms 안 콜백 \(startO.count)개 중 불일치 \(mis(startO))(대리)")
        r.notes.append("ticks \(probe.ticks) blankTicks \(probe.blankTicks) analyzed \(probe.analyzed) staleDropped \(probe.staleDropped) droppedQueued \(probe.droppedQueued) peakQueued \(probe.peakQueued) lateCompletions \(probe.lateCompletions.count) chunkCacheBound \(probe.chunkBytesEstimate)")
        r.notes.append("peak footprint during run \(String(format: "%.1f", probe.samples.map(\.footprintMB).max() ?? -1)) MB")
        r.notes.append("window occlusion visible at end: \(s.editorWindow?.occlusionState.contains(.visible) ?? false)")
        r.samples = probe.samples
        probe.stop()
        s.itemCreatedHookForTest = nil
        finish(folder, r)
    }

    static func finish(_ folder: URL, _ r: Result) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(r) { try? d.write(to: folder.appendingPathComponent("spectrum-preview-result.json")) }
        ProjectStore.shared.discardConfirmedForTest()
        NSApp.terminate(nil)
    }
}
#endif
