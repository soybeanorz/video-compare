import Foundation
import Testing
@testable import VideoCompareApp

struct ModelsTests {
    @Test func neutralToneCurveProducesIdentityLUT() {
        let lut = ToneCurveState().makeLUT(size: 5)

        #expect(lut.count == 5)
        #expect(abs(lut[0] - 0) <= 0.0001)
        #expect(abs(lut[2] - 0.5) <= 0.05)
        #expect(abs(lut[4] - 1) <= 0.0001)
    }

    @Test func toneCurveConstrainsMovedRegionsMonotonically() {
        let moved = ToneCurveState().movingRegion(2, by: 0.4)

        for pair in zip(moved.centers, moved.centers.dropFirst()) {
            #expect(pair.0 < pair.1)
        }
    }

    @Test func playerStatusSnapshotDefaultsAreIdleAndPaused() {
        let snapshot = PlayerStatusSnapshot()

        #expect(snapshot.fileURL == nil)
        #expect(snapshot.timePosition == 0)
        #expect(snapshot.duration == 0)
        #expect(snapshot.fps == 60)
        #expect(snapshot.isPaused)
        #expect(snapshot.isSeekIdle)
        #expect(!snapshot.isStaticImage)
    }

    @Test func dngIsSupportedAsStaticImage() {
        #expect(MediaFileSupport.isSupportedExtension("dng"))
        #expect(MediaFileSupport.isSupportedExtension("DNG"))
        #expect(MediaFileSupport.isImage(URL(fileURLWithPath: "/tmp/sample.dng")))
    }

    @Test func rawImageDetectionIsCaseInsensitive() {
        #expect(MediaFileSupport.isRawImage(URL(fileURLWithPath: "/tmp/sample.dng")))
        #expect(MediaFileSupport.isRawImage(URL(fileURLWithPath: "/tmp/sample.DNG")))
        #expect(MediaFileSupport.isRawImage(URL(fileURLWithPath: "/tmp/sample.arw")))
        #expect(MediaFileSupport.isRawImage(URL(fileURLWithPath: "/tmp/sample.CR3")))
        #expect(MediaFileSupport.isRawImage(URL(fileURLWithPath: "/tmp/sample.nef")))
        #expect(!MediaFileSupport.isRawImage(URL(fileURLWithPath: "/tmp/sample.jpg")))
        #expect(!MediaFileSupport.isRawImage(URL(fileURLWithPath: "/tmp/sample.png")))
        #expect(!MediaFileSupport.isRawImage(URL(fileURLWithPath: "/tmp/sample.mp4")))
    }

    @Test func whiteBalanceSolverCorrectsGreenCastWithPositiveTint() {
        let result = WhiteBalanceSolver.temperatureTintCorrection(
            sample: .init(r: 0.35, g: 0.65, b: 0.35),
            baseAdjustment: ColorAdjustmentState(),
            range: ColorAdjustmentControlRanges.rawTemperatureTint
        )

        #expect(result != nil)
        #expect(abs((result?.temperature ?? 99) - 0) <= 0.0001)
        #expect(result?.tint == 1)
    }

    @Test func whiteBalanceSolverCorrectsRedBlueBiasWithTemperature() {
        let warmResult = WhiteBalanceSolver.temperatureTintCorrection(
            sample: .init(r: 0.62, g: 0.5, b: 0.42),
            baseAdjustment: ColorAdjustmentState(),
            range: ColorAdjustmentControlRanges.rawTemperatureTint
        )
        let coolResult = WhiteBalanceSolver.temperatureTintCorrection(
            sample: .init(r: 0.42, g: 0.5, b: 0.62),
            baseAdjustment: ColorAdjustmentState(),
            range: ColorAdjustmentControlRanges.rawTemperatureTint
        )

        #expect((warmResult?.temperature ?? 0) < 0)
        #expect((coolResult?.temperature ?? 0) > 0)
    }

    @Test func whiteBalanceSolverClampsToProvidedRange() {
        let standard = WhiteBalanceSolver.temperatureTintCorrection(
            sample: .init(r: 0.05, g: 0.95, b: 0.05),
            baseAdjustment: ColorAdjustmentState(),
            range: ColorAdjustmentControlRanges.standardTemperatureTint
        )
        let raw = WhiteBalanceSolver.temperatureTintCorrection(
            sample: .init(r: 0.05, g: 0.95, b: 0.05),
            baseAdjustment: ColorAdjustmentState(),
            range: ColorAdjustmentControlRanges.rawTemperatureTint
        )

        #expect(standard?.tint == 1)
        #expect(raw?.tint == 1)
    }

    @Test func whiteBalanceSolverRejectsInvalidSamples() {
        let dark = WhiteBalanceSolver.temperatureTintCorrection(
            sample: .init(r: 0.01, g: 0.01, b: 0.01),
            baseAdjustment: ColorAdjustmentState(),
            range: ColorAdjustmentControlRanges.rawTemperatureTint
        )
        let pureColor = WhiteBalanceSolver.temperatureTintCorrection(
            sample: .init(r: 0.95, g: 0.01, b: 0.01),
            baseAdjustment: ColorAdjustmentState(),
            range: ColorAdjustmentControlRanges.rawTemperatureTint
        )

        #expect(dark == nil)
        #expect(pureColor == nil)
    }

    @Test func rawTemperatureTintMappingUsesDefaultsAndClamps() {
        let defaults = RawNeutralDefaults(temperature: 6500, tint: 10)
        let mapped = RawTemperatureTintMapper.mappedNeutral(
            defaults: defaults,
            adjustment: ColorAdjustmentState(temperature: 0.5, tint: -0.25)
        )
        let ui = RawTemperatureTintMapper.uiAdjustment(defaults: defaults, neutral: mapped)
        let clamped = RawTemperatureTintMapper.mappedNeutral(
            defaults: defaults,
            adjustment: ColorAdjustmentState(temperature: 10, tint: -10)
        )

        #expect(mapped.temperature == 10500)
        #expect(mapped.tint == -65)
        #expect(abs(ui.temperature - 0.5) <= 0.0001)
        #expect(abs(ui.tint + 0.25) <= 0.0001)
        #expect(clamped.temperature == RawTemperatureTintMapper.temperatureBounds.upperBound)
        #expect(clamped.tint == RawTemperatureTintMapper.tintBounds.lowerBound)
    }

}
