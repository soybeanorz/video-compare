import AppKit
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

    @Test func colorHistogramUsesExpandedBinCount() {
        #expect(ColorAdjustmentState.histogramBinCount == 128)
        #expect(ColorAdjustmentState.defaultHistogram().count == 128)
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

    @Test func rawWhiteBalanceEvaluatorScoresNeutralCandidateLower() {
        let greenCast = WhiteBalanceSolver.RGBSample(r: 0.35, g: 0.62, b: 0.36)
        let neutral = WhiteBalanceSolver.RGBSample(r: 0.45, g: 0.46, b: 0.45)

        #expect(RawWhiteBalanceEvaluator.isValidSample(greenCast))
        #expect(RawWhiteBalanceEvaluator.isValidSample(neutral))
        #expect(RawWhiteBalanceEvaluator.neutralError(neutral) < RawWhiteBalanceEvaluator.neutralError(greenCast))
    }

    @Test func rawWhiteBalanceEvaluatorRejectsInvalidSamples() {
        #expect(!RawWhiteBalanceEvaluator.isValidSample(.init(r: 0.01, g: 0.01, b: 0.01)))
        #expect(!RawWhiteBalanceEvaluator.isValidSample(.init(r: 0.99, g: 0.99, b: 0.99)))
        #expect(!RawWhiteBalanceEvaluator.isValidSample(.init(r: 0.95, g: 0.01, b: 0.01)))
    }

    @Test func rawWhiteBalancePatchClampsAtImageEdges() throws {
        let imageSize = CGSize(width: 400, height: 300)
        let topLeft = try #require(RawWhiteBalanceEvaluator.samplePatch(center: CGPoint(x: 4, y: 5), imageSize: imageSize, patchSize: 64))
        let bottomRight = try #require(RawWhiteBalanceEvaluator.samplePatch(center: CGPoint(x: 398, y: 299), imageSize: imageSize, patchSize: 64))
        let center = try #require(RawWhiteBalanceEvaluator.samplePatch(center: CGPoint(x: 200, y: 150), imageSize: imageSize, patchSize: 64))

        #expect(topLeft.rect.origin == .zero)
        #expect(topLeft.samplePoint == CGPoint(x: 4, y: 5))
        #expect(bottomRight.rect.maxX == imageSize.width)
        #expect(bottomRight.rect.maxY == imageSize.height)
        #expect(bottomRight.samplePoint.x <= bottomRight.rect.width)
        #expect(bottomRight.samplePoint.y <= bottomRight.rect.height)
        #expect(center.rect == CGRect(x: 168, y: 118, width: 64, height: 64))
        #expect(center.samplePoint == CGPoint(x: 32, y: 32))
    }

    @Test func rawWhiteBalancePreferredSearchValuesClampAroundCenter() {
        let middle = RawWhiteBalanceEvaluator.preferredSearchValues(center: 0.8, range: -1...1)
        let upper = RawWhiteBalanceEvaluator.preferredSearchValues(center: 0.95, range: -1...1)
        let lower = RawWhiteBalanceEvaluator.preferredSearchValues(center: -0.95, range: -1...1)

        #expect(zip(middle, [0.6, 0.7, 0.8, 0.9, 1.0]).allSatisfy { abs($0 - $1) < 0.0001 })
        #expect(upper.last == 1)
        #expect(Set(upper).count == upper.count)
        #expect(lower.first == -1)
        #expect(Set(lower).count == lower.count)
    }

    @Test func rawWhiteBalanceDragModeUsesFewerNominalCandidates() {
        #expect(RawWhiteBalanceSearchMode.dragPreview.nominalCandidateCount < RawWhiteBalanceSearchMode.finalCommit.nominalCandidateCount)
    }

    @Test func rawWhiteBalancePreviewThresholdSkipsTinyChanges() {
        let previous = ColorAdjustmentState(temperature: 0.25, tint: -0.4)
        let tiny = ColorAdjustmentState(temperature: 0.254, tint: -0.406)
        let visible = ColorAdjustmentState(temperature: 0.25, tint: -0.38)

        #expect(!RawWhiteBalanceEvaluator.shouldApplyPreview(previous: previous, next: tiny, threshold: 0.01))
        #expect(RawWhiteBalanceEvaluator.shouldApplyPreview(previous: previous, next: visible, threshold: 0.01))
        #expect(RawWhiteBalanceEvaluator.shouldApplyPreview(previous: nil, next: tiny, threshold: 0.01))
    }

    @MainActor
    @Test func whiteBalanceCursorFactoryProvidesCursorImage() {
        let cursor = WhiteBalanceCursorFactory.cursor()
        let cached = WhiteBalanceCursorFactory.cursor()

        #expect(cursor.image.size.width > 0)
        #expect(cursor.image.size.height > 0)
        #expect(cursor === cached)
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
        let disabled = RawTemperatureTintMapper.mappedNeutral(
            defaults: defaults,
            adjustment: ColorAdjustmentState(isEnabled: false, temperature: 0.5, tint: -0.25)
        )

        #expect(mapped.temperature == 10500)
        #expect(mapped.tint == -65)
        #expect(abs(ui.temperature - 0.5) <= 0.0001)
        #expect(abs(ui.tint + 0.25) <= 0.0001)
        #expect(clamped.temperature == RawTemperatureTintMapper.temperatureBounds.upperBound)
        #expect(clamped.tint == RawTemperatureTintMapper.tintBounds.lowerBound)
        #expect(disabled == defaults)
    }

    @Test func smbURLParsesToNetworkTarget() throws {
        let resolution = NetworkPathResolver.resolve(
            "smb://10.1.228.130/影像系统部/abc.mp4",
            mountedVolumes: [],
            volumesRoot: URL(fileURLWithPath: "/tmp/nonexistent-volumes", isDirectory: true)
        )

        guard case .needsMount(let mountURL, let target) = resolution else {
            Issue.record("Expected SMB URL to require mount")
            return
        }
        #expect(mountURL.absoluteString == "smb://10.1.228.130/%E5%BD%B1%E5%83%8F%E7%B3%BB%E7%BB%9F%E9%83%A8/")
        #expect(target.host == "10.1.228.130")
        #expect(target.share == "影像系统部")
        #expect(target.pathComponents == ["abc.mp4"])
        #expect(target.localURL(volumeURL: URL(fileURLWithPath: "/Volumes/影像系统部", isDirectory: true)).path == "/Volumes/影像系统部/abc.mp4")
    }

    @Test func windowsUNCPathParsesToNetworkTarget() {
        let resolution = NetworkPathResolver.resolve(
            "\\\\10.1.228.130\\影像系统部\\abc.mp4",
            mountedVolumes: [],
            volumesRoot: URL(fileURLWithPath: "/tmp/nonexistent-volumes", isDirectory: true)
        )

        guard case .needsMount(let mountURL, let target) = resolution else {
            Issue.record("Expected UNC path to require mount")
            return
        }
        #expect(mountURL.absoluteString == "smb://10.1.228.130/%E5%BD%B1%E5%83%8F%E7%B3%BB%E7%BB%9F%E9%83%A8/")
        #expect(target.host == "10.1.228.130")
        #expect(target.share == "影像系统部")
        #expect(target.pathComponents == ["abc.mp4"])
        #expect(target.localURL(volumeURL: URL(fileURLWithPath: "/Volumes/影像系统部", isDirectory: true)).path == "/Volumes/影像系统部/abc.mp4")
    }

    @Test func percentEncodedSMBShareParsesAsUnicode() {
        let resolution = NetworkPathResolver.resolve(
            "cifs://10.1.228.130/%E5%BD%B1%E5%83%8F%E7%B3%BB%E7%BB%9F%E9%83%A8/sub%20folder/abc.mp4",
            mountedVolumes: [],
            volumesRoot: URL(fileURLWithPath: "/tmp/nonexistent-volumes", isDirectory: true)
        )

        guard case .needsMount(_, let target) = resolution else {
            Issue.record("Expected percent-encoded CIFS URL to require mount")
            return
        }
        #expect(target.share == "影像系统部")
        #expect(target.pathComponents == ["sub folder", "abc.mp4"])
    }

    @Test func mountedSMBShareMapsToVolumesPath() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoCompareNetworkPathTests-\(UUID().uuidString)", isDirectory: true)
        let volumesRoot = base.appendingPathComponent("Volumes", isDirectory: true)
        let shareRoot = volumesRoot.appendingPathComponent("影像系统部", isDirectory: true)
        try FileManager.default.createDirectory(at: shareRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let resolution = NetworkPathResolver.resolve(
            "smb://10.1.228.130/影像系统部/abc.mp4",
            mountedVolumes: [],
            volumesRoot: volumesRoot
        )

        guard case .local(let localURL) = resolution else {
            Issue.record("Expected mounted SMB share to map to local URL")
            return
        }
        #expect(localURL.path == shareRoot.appendingPathComponent("abc.mp4").standardizedFileURL.path)
    }

    @Test func ordinaryLocalPathIsNotNetworkPath() {
        let resolution = NetworkPathResolver.resolve(
            "/Users/soybean/Downloads",
            mountedVolumes: [],
            volumesRoot: URL(fileURLWithPath: "/tmp/nonexistent-volumes", isDirectory: true)
        )

        #expect(resolution == .unsupported)
    }

}
