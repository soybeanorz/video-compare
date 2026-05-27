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
    }
}
