#if DEBUG
import Foundation

/// SP-EXPORT-E4D-G1: approved threshold table v1 for the full Preview versus Export parity (phase 1), copied from
/// docs/DECISIONS.md "2026-11-25 전체 Preview 대 Export parity 1단계 설계(제안, G0 승인 대기)" (approved at G0).
/// Frozen before any runtime result. Every result records `version` and `fingerprint`. Changing a value needs a new version
/// and a new owner approval; never change it after observing a result.
enum ParityThresholdsV1 {
    static let version = "v1"

    // Identity and timing
    static let stableSamples = 3                 // consecutive complete samples with the expected code
    static let stableMinimumSeconds = 0.050
    static let stableTimeoutSeconds = 10.0
    static let codeMarginMinimum = 40            // |cell luma − 128| (8-bit, full-range luma of the capture or the decoded plane)

    // Geometry (Preview pixels)
    static let geometryWithModel = 0.5
    static let geometryWithoutModel = 1.0

    // Masks
    static let maskDeltaY = 24                   // 8-bit video-range Y'
    static let maskDeltaC = 24                   // 8-bit Cb/Cr
    static let coverageCore = 0.9, coverageEdgeLow = 0.1
    static let maskCoreIoU = 0.97
    static let maskBoundingBoxPixels = 1.0
    static let maskMinimumCoreNativePixels = 500
    static let exportFalsePositiveDilation = 8   // native px around the timeline layout box
    static let exportFalsePositiveMax = 0
    static let previewFalsePositiveDilation = 2  // Preview px around the expected region
    static let previewFalsePositiveFraction = 0.001
    static let previewFalsePositiveMax = 50

    // Calibration
    static let calibrationValidationMeanDE = 1.5
    static let calibrationValidationMaxDE = 3.0

    // Colour
    static let previewVersusExportMeanDE = 2.0
    static let previewVersusExportMaxDE = 4.0
    static let sourceInterpretationMeanDE = 2.0
    static let sourceInterpretationP95DE = 3.0
    static let sourceInterpretationMaxDE = 5.0

    // D-041 conformance
    static let laneInvarianceChannel = 2         // 8-bit
    static let laneInvarianceFraction = 0.999
    static let laneInvariancePatchMaxDE = 1.0
    static let approvedReferenceMeanDE = 1.0
    static let approvedReferenceMaxDE = 2.0
    static let anchorYCbCr = (69, 119, 207)      // plate-red-640x480 corrected Export mean, recorded 2026-11-24 (generated material)
    static let anchorTolerance = 2

    // Resampling model
    static let resamplingValidationRMS = 2.0
    static let resamplingValidationMax = 8.0
    static let resamplingDisagreementLevel = 2.0
    static let resamplingDisagreementFraction = 0.005
    static let resamplingDisagreementMax = 6.0
    static let resamplingPhaseSteps = 16         // 1/16 px grid in [−0.5, 0.5)

    // Pixel fidelity (interior: at least 3 Preview px from video and layer edges)
    static let fidelityInteriorMargin = 3
    static let fidelityChannel = 6
    static let fidelityFraction = 0.99

    // Edges
    static let exportEdgeTolerance = 16
    static let previewEdgeNoiseFactor = 3.0

    /// Canonical text of every value; its FNV-1a 64 hash is recorded with each result.
    static var canonical: String {
        let values: [(String, String)] = [
            ("stableSamples", "\(stableSamples)"), ("stableMinimumSeconds", "\(stableMinimumSeconds)"), ("stableTimeoutSeconds", "\(stableTimeoutSeconds)"),
            ("codeMarginMinimum", "\(codeMarginMinimum)"), ("geometryWithModel", "\(geometryWithModel)"), ("geometryWithoutModel", "\(geometryWithoutModel)"),
            ("maskDeltaY", "\(maskDeltaY)"), ("maskDeltaC", "\(maskDeltaC)"), ("coverageCore", "\(coverageCore)"), ("coverageEdgeLow", "\(coverageEdgeLow)"),
            ("maskCoreIoU", "\(maskCoreIoU)"), ("maskBoundingBoxPixels", "\(maskBoundingBoxPixels)"), ("maskMinimumCoreNativePixels", "\(maskMinimumCoreNativePixels)"),
            ("exportFalsePositiveDilation", "\(exportFalsePositiveDilation)"), ("exportFalsePositiveMax", "\(exportFalsePositiveMax)"),
            ("previewFalsePositiveDilation", "\(previewFalsePositiveDilation)"), ("previewFalsePositiveFraction", "\(previewFalsePositiveFraction)"),
            ("previewFalsePositiveMax", "\(previewFalsePositiveMax)"), ("calibrationValidationMeanDE", "\(calibrationValidationMeanDE)"),
            ("calibrationValidationMaxDE", "\(calibrationValidationMaxDE)"), ("previewVersusExportMeanDE", "\(previewVersusExportMeanDE)"),
            ("previewVersusExportMaxDE", "\(previewVersusExportMaxDE)"), ("sourceInterpretationMeanDE", "\(sourceInterpretationMeanDE)"),
            ("sourceInterpretationP95DE", "\(sourceInterpretationP95DE)"), ("sourceInterpretationMaxDE", "\(sourceInterpretationMaxDE)"),
            ("laneInvarianceChannel", "\(laneInvarianceChannel)"), ("laneInvarianceFraction", "\(laneInvarianceFraction)"),
            ("laneInvariancePatchMaxDE", "\(laneInvariancePatchMaxDE)"), ("approvedReferenceMeanDE", "\(approvedReferenceMeanDE)"),
            ("approvedReferenceMaxDE", "\(approvedReferenceMaxDE)"), ("anchorYCbCr", "\(anchorYCbCr.0),\(anchorYCbCr.1),\(anchorYCbCr.2)"),
            ("anchorTolerance", "\(anchorTolerance)"), ("resamplingValidationRMS", "\(resamplingValidationRMS)"), ("resamplingValidationMax", "\(resamplingValidationMax)"),
            ("resamplingDisagreementLevel", "\(resamplingDisagreementLevel)"), ("resamplingDisagreementFraction", "\(resamplingDisagreementFraction)"),
            ("resamplingDisagreementMax", "\(resamplingDisagreementMax)"), ("resamplingPhaseSteps", "\(resamplingPhaseSteps)"),
            ("fidelityInteriorMargin", "\(fidelityInteriorMargin)"), ("fidelityChannel", "\(fidelityChannel)"), ("fidelityFraction", "\(fidelityFraction)"),
            ("exportEdgeTolerance", "\(exportEdgeTolerance)"), ("previewEdgeNoiseFactor", "\(previewEdgeNoiseFactor)")]
        return values.map { "\($0.0)=\($0.1)" }.joined(separator: ";")
    }
    static var fingerprint: String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in canonical.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(format: "%016llx", h)
    }
}
#endif
