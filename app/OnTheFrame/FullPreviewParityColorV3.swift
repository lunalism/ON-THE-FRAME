#if DEBUG
import Foundation

/// SP-EXPORT-E4D-COLOR-V3-CORE-95 (pure, Foundation only): calculation core of the owner-approved `parity-color-v3`
/// diagnostic contract (DECISIONS 2026-11-26, task 93). NOT wired into the runtime: nothing in the v1 parity path calls this
/// file, so the existing CAL-B / RES-B / C1–C7 behaviour is unchanged until a separately approved integration.
/// Kept apart from the v1 code on purpose: `ColorMath.linear` (BT.1886 γ 2.4, `lab.v1`) stays the raw-ledger formula.

// MARK: - Contract identity and canonical bytes

enum ColorContractV3 {
    static let id = "parity-color-v3"
    static let revision = 3
    /// Frozen values from the approved canonical text (task 93). The Swift bytes below must reproduce them; they are
    /// never replaced by a recomputed value.
    static let frozenFingerprint = "22521502dd4ea3e1"
    static let frozenByteCount = 3665
    static let frozenFieldCount = 46
    static let frozenSHA256 = "f45297f1af24971e69dac992157ccb64448d858fb76a99a3065b2e90438a38bb"
    static let retiredFingerprints = ["parity-color-v2": "bb41977d54f69e42"]

    /// Canonical fields in their fixed order, copied byte-for-byte from `canonical-v3.txt`. Literal strings only:
    /// no number in this table is produced by floating-point formatting or a locale.
    static let fields: [(String, String)] = [
        ("contract", "parity-color-v3"),
        ("revision", "3"),
        ("supersedes", "parity-color-v2:bb41977d54f69e42"),
        ("scope", "DEBUG-parity-diagnostics-only"),
        ("declarationSource", "source-track-format-description-only"),
        ("c5Declaration", "track-primaries,track-transfer,track-matrix,track-FullRangeVideo/all-present/no-track-buffer-conflict"),
        ("c5Range", "track-FullRangeVideo-explicit-only/absent-is-undeclared"),
        ("conversionRange", "decoded-pixel-format-range/420v~video/decoding-and-pixel-calculation-only/never-a-source-declaration"),
        ("bufferAttachments", "observation-only/corroborate-or-conflict/never-fill-missing"),
        ("conflict", "record-both-values/C5-INCONCLUSIVE"),
        ("untagged", "no-declaration/no-conversion/managed-INCONCLUSIVE/C6-hypothesis-record-only"),
        ("primaries", "ITU_R_709_2:0.640,0.330,0.300,0.600,0.150,0.060|SMPTE_C:0.630,0.340,0.310,0.595,0.155,0.070"),
        ("white", "D65:0.3127,0.3290"),
        ("adaptation", "none"),
        ("primaryMatrix", "RGB-to-XYZ-from-chromaticities/declared-to-XYZ-to-linear-sRGB"),
        ("transfer", "ITU_R_709_2"),
        ("matrix", "ITU_R_709_2:0.2126,0.0722|ITU_R_601_4:0.299,0.114"),
        ("unsupported", "managed-INCONCLUSIVE"),
        ("order", "decode|eclip|resample-encoded|gamma|primaries|gclip|sRGB-OETF|calibration"),
        ("resampling", "area|bilinear|catmullRom|mitchell|lanczos2|lanczos3"),
        ("gamma", "1.96"),
        ("gammaStatus", "diagnostic-hypothesis"),
        ("sRGB", "IEC-61966-2-1-piecewise"),
        ("eclip", "clamp-0-1-decoded-encoded-RGB/record-preclip"),
        ("gclip", "clamp-0-1-per-channel-linear-sRGB/record-preclip,clipped-channel-count,max-abs-delta,gamut-loss-DE00/judge-postclip/no-exclusion"),
        ("prediction", "P-unquantized-floating-0-1"),
        ("labV2", "expected:gamma,declared-primaries,postclip-XYZ/observed:calibrated-capture,sRGB-EOTF,sRGB-primaries/Xn:0.95047,Yn:1,Zn:1.08883/CIE1976/CIEDE2000"),
        ("labV1", "BT1886-gamma-2.4/raw-ledger-only/export-side-C5"),
        ("calibrationStorage", "row-major-3x4/M:columns-0-2/b:column-3"),
        ("calibrationApply", "out:clamp-0-1(M*capture+b)/capture:normalized-sRGB-encoded-0-1/floating-point-until-final-output-boundary"),
        ("calibrationFit", "least-squares/target:P/training-patches-only"),
        ("calibrationSplit", "holdout:2,5,8,12,14,17,20,23/training:remaining-16/grey:0-10"),
        ("calibrationAdmissibility", "elementwise/abs(M[i][j]-I[i][j])-le-0.10/abs(b[i])-le-0.04/normalized-0-1/boundary-inclusive/no-parameter-clamping/no-refit"),
        ("calibrationValidation", "holdout-DE00-labV2-mean-le-threshold-v1,max-le-threshold-v1/grey-monotonic-v1"),
        ("calibrationRecord", "admissibility|holdout|grey-monotonic/each-recorded-separately"),
        ("calibrationVerdict", "admissibility-violation:INCONCLUSIVE/admissible-and-validation-failure:FAIL/all-valid:PASS/validation-failure-recorded-even-when-INCONCLUSIVE/non-PASS-stops-RES"),
        ("dependency", "CAL-B|CAL-V|RES-B|RES-C"),
        ("ledgerRaw", "compositor,export,settle,stable,capture,identity,timing,geometry,mask,edge,gapBlackExport,planActiveLayers,anchorMean,CAL.sourceDeclaration,previewVsExportPreCalibration,outputConversion,C3,C4,C6,C7,C5.sourceInterpretation,C5.exportFollowsDeclaration,C1-C2.exportPixels,C1-C2.patchDE,baseline"),
        ("ledgerManaged", "gapBlackPreview,CAL.reference,CAL.patches,CAL-B,CAL-V,RES-B,RES-C,fidelity,previewVsExportColour,C5.previewFollowsDeclaration,C1-C2.previewPixels"),
        ("ledgerComposite", "C5.M2,C5.M3,C5.declaredInterpretation,C1.realMultiLayerInvariance,C2.emptyLaneInvariance,D041.conformance:C1-and-C3-and-C5"),
        ("managedLabel", "managed(parity-color-v3)/never-raw-pixel-parity"),
        ("geometryRepresentation", "record-managed-calibrated-when-calibrated-crop-used"),
        ("display", "record-profile,backing-scale,capture-colour-space/capture-not-sRGB-or-differs-from-CAL-B:reject-or-INCONCLUSIVE"),
        ("validation", "freeze-before-new-data/change-requires-new-version/independent-tagged-BT709-and-SMPTE_C-required/untagged-not-evidence/failure-preserved-no-retuning"),
        ("thresholds", "v1:b2cd7ba0367c680d"),
        ("models", "record-colorContract-in-results,CAL-B,RES-B,provenance/reject-missing-or-different-colorContract")
    ]
    /// key=value joined by ";", ASCII-only UTF-8, no trailing newline.
    static var canonical: String { fields.map { "\($0.0)=\($0.1)" }.joined(separator: ";") }
    static var canonicalBytes: [UInt8] { Array(canonical.utf8) }
    /// FNV-1a 64 of the canonical bytes (same formula as `Fingerprint.fnv`, written out here so the two can be compared).
    static var fingerprint: String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in canonicalBytes { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(format: "%016llx", h)
    }
    /// True only when the Swift bytes reproduce the frozen length, field count and fingerprint.
    static var reproducesFrozen: Bool {
        canonicalBytes.count == frozenByteCount && fields.count == frozenFieldCount && fingerprint == frozenFingerprint
            && canonicalBytes.allSatisfy { $0 < 0x80 } && canonicalBytes.last != 0x0A
            && fields.allSatisfy { !($0.0 + $0.1).contains(";") && !($0.0 + $0.1).contains("=") }
    }
    static func value(_ key: String) -> String? { fields.first { $0.0 == key }?.1 }
    static var identity: ColorContractIdentity { ColorContractIdentity(id: id, fingerprint: frozenFingerprint) }
}

/// Identity stored with every v3 result and frozen model (`colorContract`).
struct ColorContractIdentity: Codable, Sendable, Equatable {
    let id: String
    let fingerprint: String
}

// MARK: - Model-version admission (D-042 order: CAL-B → RES-B → RES-C)

enum ContractAdmission: Equatable, Sendable {
    case accepted
    case rejected(String)
    var isAccepted: Bool { self == .accepted }
}

enum ColorContractValidation {
    /// A frozen CAL-B / RES-B model may be used under v3 only when it carries exactly the v3 identity.
    /// Models without an identity (all v1 models) and retired or unknown contracts are refused, never migrated.
    static func admit(_ identity: ColorContractIdentity?) -> ContractAdmission {
        guard let c = identity else { return .rejected("missing colorContract (historical v1 model)") }
        if let retired = ColorContractV3.retiredFingerprints[c.id] { return .rejected("retired contract \(c.id) (\(retired))") }
        guard c.id == ColorContractV3.id else { return .rejected("unsupported contract \(c.id)") }
        guard c.fingerprint == ColorContractV3.frozenFingerprint else {
            return .rejected("wrong \(c.id) fingerprint \(c.fingerprint) (expected \(ColorContractV3.frozenFingerprint))")
        }
        return .accepted
    }
    /// RES-B depends on a CAL-B frozen under the same contract; RES-C on both.
    static func admitChain(calibration: ColorContractIdentity?, resampling: ColorContractIdentity?) -> ContractAdmission {
        if case .rejected(let w) = admit(calibration) { return .rejected("CAL-B: \(w)") }
        if case .rejected(let w) = admit(resampling) { return .rejected("RES-B: \(w)") }
        return calibration == resampling ? .accepted : .rejected("CAL-B and RES-B contract identities differ")
    }
}

// MARK: - Source declarations (track declaration / buffer observation / decoded format kept apart)

/// What a source may contribute under v3. Built only from `DeclaredInterpretation` (G1/G2 rules unchanged):
/// - `c5Eligible`: complete track declaration (primaries, transfer, matrix, explicit FullRangeVideo) with no track/buffer
///   conflict — the only path to a C5 declaration. A decoded 420v range never fills it.
/// - `managed`: the conversion (track-declared primaries/transfer/matrix + decoded pixel-format range) when it is inside v3;
///   otherwise nil and `managedProblem` (managed verdicts INCONCLUSIVE).
struct SourceDeclarationV3: Sendable {
    let c5Eligible: Bool
    let c5Problem: String?
    let managed: ColorDeclaration?
    let managedProblem: String?
    let decodedRangeIsDeclaration = false

    static func make(_ i: DeclaredInterpretation) -> SourceDeclarationV3 {
        let c5ok = i.resolved != nil && i.problem == nil
        guard let c = i.conversion else {
            return SourceDeclarationV3(c5Eligible: c5ok, c5Problem: c5ok ? nil : i.problem,
                                       managed: nil, managedProblem: "no conversion: primaries/transfer/matrix not all declared in the track, conflicting, or no decoded range")
        }
        guard let p = c.primaries, ColorV3.supportedPrimaries.contains(p) else {
            return SourceDeclarationV3(c5Eligible: c5ok, c5Problem: c5ok ? nil : i.problem, managed: nil, managedProblem: "primaries outside parity-color-v3")
        }
        guard c.transfer == ColorV3.supportedTransfer else {
            return SourceDeclarationV3(c5Eligible: c5ok, c5Problem: c5ok ? nil : i.problem, managed: nil, managedProblem: "transfer outside parity-color-v3")
        }
        guard let m = c.matrix, ColorV3.supportedMatrices.contains(m), c.fullRange != nil else {
            return SourceDeclarationV3(c5Eligible: c5ok, c5Problem: c5ok ? nil : i.problem, managed: nil, managedProblem: "matrix or decoded range outside parity-color-v3")
        }
        return SourceDeclarationV3(c5Eligible: c5ok, c5Problem: c5ok ? nil : i.problem, managed: c, managedProblem: nil)
    }
}

// MARK: - Fixed transform

enum ColorV3 {
    typealias RGB = ColorMath.RGB
    typealias Lab = ColorMath.Lab
    static let supportedPrimaries = ["ITU_R_709_2", "SMPTE_C"]
    static let supportedTransfer = "ITU_R_709_2"
    static let supportedMatrices = ["ITU_R_709_2", "ITU_R_601_4"]
    /// Diagnostic hypothesis (Apple: "approximately 1.96"); fixed, never fitted.
    static let gamma = 1.96
    static let white = (x: 0.95047, y: 1.0, z: 1.08883)

    /// IEC 61966-2-1 piecewise curves on 0…1 (inputs outside 0…1 are clamped first).
    static func srgbEOTF(_ v: Double) -> Double { let x = min(1, max(0, v)); return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
    static func srgbOETF(_ v: Double) -> Double { let x = min(1, max(0, v)); return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055 }
    /// Display hypothesis: per channel max(0, V)^1.96.
    static func displayLinear(_ v: Double) -> Double { pow(max(0, v), gamma) }

    static func rgbToXYZ(_ primaries: String) -> [[Double]]? { ColorMath.primaries(primaries).map(ColorMath.rgbToXYZ) }
    static func multiply(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
        (0..<3).map { r in (0..<3).map { c in (0..<3).reduce(0) { $0 + a[r][$1] * b[$1][c] } } }
    }
    static func apply(_ m: [[Double]], _ v: [Double]) -> [Double] { (0..<3).map { r in m[r][0] * v[0] + m[r][1] * v[1] + m[r][2] * v[2] } }
    static func inverse(_ m: [[Double]]) -> [[Double]]? {
        let cols = (0..<3).compactMap { c in Linear.solve3(m, (0..<3).map { $0 == c ? 1.0 : 0.0 }) }
        guard cols.count == 3 else { return nil }
        return (0..<3).map { r in (0..<3).map { c in cols[c][r] } }
    }
    /// Linear declared RGB → XYZ (D65) → linear sRGB. No chromatic adaptation (same white). Identity for BT.709.
    static func declaredToLinearSRGB(_ primaries: String) -> [[Double]]? {
        guard supportedPrimaries.contains(primaries), let src = rgbToXYZ(primaries), let srgb = rgbToXYZ("ITU_R_709_2"),
              let inv = inverse(srgb) else { return nil }
        return multiply(inv, src)
    }

    /// E-clip: decoded encoded R'G'B' with its pre-clip values.
    struct Decoded: Sendable { let preClip: [Double]; let encoded: [Double]; let clippedChannels: Int }
    static func decode(y: Double, cb: Double, cr: Double, matrix: String, fullRange: Bool) -> Decoded? {
        guard supportedMatrices.contains(matrix), let k = ColorMath.coefficients(matrix) else { return nil }
        let yn = fullRange ? y / 255 : (y - 16) / 219
        let pb = fullRange ? (cb - 128) / 255 : (cb - 128) / 224, pr = fullRange ? (cr - 128) / 255 : (cr - 128) / 224
        let r = yn + 2 * (1 - k.kr) * pr, b = yn + 2 * (1 - k.kb) * pb
        let g = (yn - k.kr * r - k.kb * b) / (1 - k.kr - k.kb)
        let pre = [r, g, b]
        let enc = pre.map { min(1, max(0, $0)) }
        return Decoded(preClip: pre, encoded: enc, clippedChannels: zip(pre, enc).filter { $0 != $1 }.count)
    }

    /// Spatial prediction in the ENCODED domain: weighted mean of encoded samples (the kernel weights come from the six
    /// unchanged resampling candidates; this helper only fixes the order — resample first, transform second).
    static func resampleEncoded(_ samples: [[Double]], weights: [Double]) -> [Double]? {
        guard samples.count == weights.count, !samples.isEmpty else { return nil }
        let w = weights.reduce(0, +)
        guard w != 0 else { return nil }
        return (0..<3).map { c in zip(samples, weights).reduce(0) { $0 + $1.0[c] * $1.1 } / w }
    }

    /// One managed prediction with every G-clip observation recorded.
    struct Prediction: Sendable {
        let encoded: [Double]              // input (already resampled, E-clipped)
        let linearDeclared: [Double]       // V^1.96 in declared primaries
        let linearSRGBPreClip: [Double]
        let linearSRGB: [Double]           // after G-clip
        let clippedChannels: Int
        let maxAbsClip: Double
        let gamutLossDE00: Double          // ΔE00 between pre- and post-clip colours
        let p: [Double]                    // sRGB-encoded predicted capture, floating point, 0…1 (never quantized)
        var clipped: Bool { clippedChannels > 0 }
    }
    static func predict(encoded: [Double], primaries: String) -> Prediction? {
        guard encoded.count == 3, let m = declaredToLinearSRGB(primaries) else { return nil }
        let lin = encoded.map(displayLinear)
        let pre = apply(m, lin)
        let post = pre.map { min(1, max(0, $0)) }
        let deltas = zip(pre, post).map { abs($0 - $1) }
        guard let a = labFromLinearSRGB(pre), let b = labFromLinearSRGB(post) else { return nil }
        return Prediction(encoded: encoded, linearDeclared: lin, linearSRGBPreClip: pre, linearSRGB: post,
                          clippedChannels: deltas.filter { $0 > 0 }.count, maxAbsClip: deltas.max() ?? 0,
                          gamutLossDE00: ColorMath.deltaE2000(a, b), p: post.map(srgbOETF))
    }

    /// CIELAB (D65, Xn 0.95047, Yn 1, Zn 1.08883) of linear sRGB (values used as given; the pre-clip colour may be negative).
    static func labFromLinearSRGB(_ lin: [Double]) -> Lab? {
        guard let m = rgbToXYZ("ITU_R_709_2") else { return nil }
        let xyz = apply(m, lin)
        func f(_ t: Double) -> Double { t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116 }
        let fx = f(xyz[0] / white.x), fy = f(xyz[1] / white.y), fz = f(xyz[2] / white.z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }
    /// lab.v2 expected: the post-clip prediction.
    static func labV2Expected(_ p: Prediction) -> Lab? { labFromLinearSRGB(p.linearSRGB) }
    /// lab.v2 observed: CAL-B-calibrated capture (sRGB encoded) → sRGB EOTF → sRGB primaries.
    static func labV2Observed(calibratedCapture c: [Double]) -> Lab? { c.count == 3 ? labFromLinearSRGB(c.map(srgbEOTF)) : nil }
}

// MARK: - CAL-B v3

enum CalibrationV3 {
    /// Stored row-major 3×4: M = columns 0–2, b = column 3. out = clamp01(M · capture + b), floating point.
    static func apply(_ stored: [[Double]], _ capture: [Double]) -> [Double] {
        (0..<3).map { c in min(1, max(0, stored[c][0] * capture[0] + stored[c][1] * capture[1] + stored[c][2] * capture[2] + stored[c][3])) }
    }

    struct Admissibility: Codable, Sendable, Equatable {
        let admissible: Bool
        let violations: [String]
        let maxMatrixDeviation: Double
        let maxOffset: Double
    }
    /// Inclusive direct interval bounds equivalent to |M−I| ≤ 0.10 and |b| ≤ 0.04 (task 96, owner approved). Each decimal
    /// bound is the nearest Double literal and the stored value is compared to it directly — no subtraction, no epsilon —
    /// so a stored 1.10 is accepted and the next representable value is rejected.
    static let diagonalBounds = (low: 0.90, high: 1.10)
    static let offDiagonalBounds = (low: -0.10, high: 0.10)
    static let offsetBounds = (low: -0.04, high: 0.04)

    /// Elementwise hard limits, boundary inclusive, finite values required. Parameters are never clamped or refitted here.
    /// The deviations are recorded for inspection only; they do not decide admissibility.
    static func admissibility(_ stored: [[Double]]) -> Admissibility {
        guard stored.count == 3, stored.allSatisfy({ $0.count == 4 && $0.allSatisfy(\.isFinite) }) else {
            return Admissibility(admissible: false, violations: ["matrix is not a finite 3x4"], maxMatrixDeviation: .nan, maxOffset: .nan)
        }
        var v: [String] = [], md = 0.0, mo = 0.0
        for i in 0..<3 {
            for j in 0..<3 {
                let x = stored[i][j], bounds = i == j ? diagonalBounds : offDiagonalBounds
                md = max(md, abs(x - (i == j ? 1 : 0)))
                if !(bounds.low <= x && x <= bounds.high) { v.append("M[\(i)][\(j)] \(x) outside [\(bounds.low), \(bounds.high)]") }
            }
            let b = stored[i][3]; mo = max(mo, abs(b))
            if !(offsetBounds.low <= b && b <= offsetBounds.high) { v.append("b[\(i)] \(b) outside [\(offsetBounds.low), \(offsetBounds.high)]") }
        }
        return Admissibility(admissible: v.isEmpty, violations: v, maxMatrixDeviation: md, maxOffset: mo)
    }

    struct Outcome: Sendable {
        let admissibility: Admissibility
        let holdoutDE: Distribution
        let holdoutComputed: Int
        let holdoutExpected: Int
        let holdoutPass: Bool
        let greyMonotonic: Bool
        /// Validation (holdout + grey) on its own, recorded even when the aggregate is INCONCLUSIVE.
        var validationVerdict: ParityVerdict { holdoutPass && greyMonotonic ? .pass : .fail }
        /// Precedence: admissibility violation → INCONCLUSIVE; admissible but validation failure → FAIL; else PASS.
        var aggregate: ParityVerdict { !admissibility.admissible ? .inconclusive : (validationVerdict == .pass ? .pass : .fail) }
        var proceedsToRES: Bool { aggregate == .pass }
    }

    /// Precedence on already computed parts (used by `evaluate` and directly by tests).
    static func outcome(admissibility a: Admissibility, holdoutDE: [Double], expected: Int, greyMonotonic: Bool) -> Outcome {
        let d = Distribution(holdoutDE)
        let ok = holdoutDE.count == expected && d.mean <= ParityThresholdsV1.calibrationValidationMeanDE
            && d.max <= ParityThresholdsV1.calibrationValidationMaxDE
        return Outcome(admissibility: a, holdoutDE: d, holdoutComputed: holdoutDE.count, holdoutExpected: expected, holdoutPass: ok, greyMonotonic: greyMonotonic)
    }

    /// One patch for v3: captured sRGB-encoded mean and the floating-point managed target P (never quantized).
    struct Patch: Sendable { let index: Int; let capture: [Double]; let target: [Double] }

    /// Fit on the 16 training patches (least squares to P, the existing v1 solver), then evaluate the three parts separately.
    static func evaluate(patches: [Patch]) -> (stored: [[Double]], outcome: Outcome)? {
        let asV1 = patches.map { Calibration.Patch(index: $0.index, measured: $0.capture, reference: $0.target, pixels: 0) }
        let training = asV1.filter { ParityLayout.trainingPatches.contains($0.index) }
        guard let m = try? Calibration.fit(training: training) else { return nil }
        let validation = patches.filter { ParityLayout.validationPatches.contains($0.index) }
        var des: [Double] = []
        for v in validation {
            guard let o = ColorV3.labV2Observed(calibratedCapture: apply(m, v.capture)),
                  let e = ColorV3.labFromLinearSRGB(v.target.map(ColorV3.srgbEOTF)) else { continue }
            des.append(ColorMath.deltaE2000(o, e))
        }
        let greys = ParityLayout.greyPatches.compactMap { i in patches.first { $0.index == i } }
        let lumas = greys.map { g -> Double in let a = apply(m, g.capture); return 0.2126 * a[0] + 0.7152 * a[1] + 0.0722 * a[2] }
        let mono = lumas.count == ParityLayout.greyPatches.count && zip(lumas, lumas.dropFirst()).allSatisfy { $0 < $1 }
        return (m, outcome(admissibility: admissibility(m), holdoutDE: des, expected: ParityLayout.validationPatches.count, greyMonotonic: mono))
    }
}

// MARK: - Raw / managed ledgers

/// `metadata`: orchestration records (e.g. `execution`) that are neither raw nor managed colour/pixel verdicts (task 96).
enum ParityLedger: String, Codable, Sendable { case raw, managed, composite, metadata }

/// A value tagged with its ledger. Raw values never carry a contract; managed values always carry the v3 identity and
/// the label "managed(parity-color-v3)", so managed agreement can never be reported as raw pixel identity.
struct LedgerValue: Codable, Sendable, Equatable {
    let ledger: ParityLedger
    let name: String
    let values: [Double]
    let colorContract: ColorContractIdentity?
    let label: String
    static func raw(_ name: String, _ values: [Double]) -> LedgerValue {
        LedgerValue(ledger: .raw, name: name, values: values, colorContract: nil, label: "raw")
    }
    static func managed(_ name: String, _ values: [Double]) -> LedgerValue {
        LedgerValue(ledger: .managed, name: name, values: values, colorContract: ColorContractV3.identity, label: ParityLedgerV3.managedLabel)
    }
    var wellFormed: Bool {
        switch ledger {
        case .raw: return colorContract == nil && label == "raw"
        case .managed: return colorContract == ColorContractV3.identity && label == ParityLedgerV3.managedLabel
        case .composite, .metadata: return false
        }
    }
}

enum ParityLedgerV3 {
    static let managedLabel = "managed(parity-color-v3)"
    static let composite: Set<String> = ["C5.M2", "C5.M3", "C5.declaredInterpretation", "C1.realMultiLayerInvariance",
                                         "C2.emptyLaneInvariance", "D041.conformance"]
    static let managedLeaves: Set<String> = ["gapBlackPreview", "fidelity", "previewVsExportColour", "previewFollowsDeclaration",
                                             "previewPixels", "residual", "calibration"]
    static let rawLeaves: Set<String> = ["previewInstalled", "dimensions", "previewSettled", "previewStable", "exportTiming",
                                         "exportIdentity", "previewIdentity", "identity", "geometry", "previewEdge", "exportEdge",
                                         "gapBlackExport", "planActiveLayers", "anchorMean", "sourceDeclaration",
                                         "previewVsExportPreCalibration", "outputConversion", "sourceInterpretation",
                                         "exportFollowsDeclaration", "exportPixels", "patchDE", "builtinLaneDependence"]
    static func isC1C2Precondition(_ name: String) -> Bool {
        let parts = name.split(separator: ".").map(String.init)
        guard let first = parts.first, first == "C1" || first == "C2" else { return false }
        if parts.count == 1 { return true }
        guard parts.count == 2, parts[1].hasPrefix("frame") else { return false }
        let k = parts[1].dropFirst(5)
        return !k.isEmpty && k.allSatisfy(\.isNumber)
    }
    /// Ledger owner of a check name (task 93 table; `execution` and the C1/C2 precondition markers per task 96).
    /// nil = not mapped (must be decided before integration, never guessed).
    static func owner(of name: String) -> ParityLedger? {
        if name == "execution" { return .metadata }
        if composite.contains(name) { return .composite }
        // C1/C2 precondition markers (Judge.compare): "C1", "C2", "C1.frameK", "C2.frameK" are INCONCLUSIVE / NOT RUN
        // markers that feed the C1/C2 roll-ups; their real sub-checks (exportPixels, patchDE, previewPixels) are mapped below.
        if isC1C2Precondition(name) { return .composite }
        let parts = name.split(separator: ".").map(String.init)
        guard let first = parts.first, let leaf = parts.last else { return nil }
        if first == "RES-B" || first == "RES-C" || first == "CAL-B" || first == "CAL-V" { return .managed }
        if first == "CAL" { return leaf == "sourceDeclaration" ? .raw : (leaf == "reference" || leaf == "patches" ? .managed : nil) }
        if ["C3", "C4", "C6", "C7"].contains(first) || ["baseline", "compositor", "export", "capture"].contains(first) || leaf == "capture" { return .raw }
        if leaf == "exportFrame" { return .raw }
        if managedLeaves.contains(leaf) { return .managed }
        if rawLeaves.contains(leaf) || leaf.hasPrefix("mask") || leaf.hasPrefix("previewMask") || leaf.hasPrefix("exportMask")
            || parts.contains("C6") || parts.contains("C7") || parts.contains("C3") { return .raw }
        return nil
    }
}
#endif
