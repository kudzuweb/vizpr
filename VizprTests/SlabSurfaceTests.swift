import Testing
@testable import Vizpr

@Suite("SlabSurface mesh points")
struct SlabSurfaceTests {
    @Test("corners never move and edge midpoints stay on their edge")
    func outlineStaysExact() {
        for time in stride(from: 0.0, through: 24.0, by: 1.7) {
            let points = SlabSurface.meshPoints(time: time, drift: 0.5, loopSeconds: 12)
            #expect(points.count == 9)
            #expect(points[0] == SIMD2(0, 0) && points[2] == SIMD2(1, 0))
            #expect(points[6] == SIMD2(0, 1) && points[8] == SIMD2(1, 1))
            #expect(points[1].y == 0 && points[7].y == 1)
            #expect(points[3].x == 0 && points[5].x == 1)
        }
    }

    @Test("points drift by at most half the drift amplitude and loop")
    func boundedAndPeriodic() {
        let drift = 0.2
        let start = SlabSurface.meshPoints(time: 3, drift: drift, loopSeconds: 12)
        let later = SlabSurface.meshPoints(time: 15, drift: drift, loopSeconds: 12)
        for (first, second) in zip(start, later) {
            #expect(abs(first.x - second.x) < 1e-4 && abs(first.y - second.y) < 1e-4)
        }
        let center = SlabSurface.meshPoints(time: 1, drift: drift, loopSeconds: 12)[4]
        #expect(abs(center.x - 0.5) <= Float(drift * 0.5) + 1e-6)
    }

    @Test("zero drift is a regular grid")
    func noDrift() {
        let points = SlabSurface.meshPoints(time: 5, drift: 0, loopSeconds: 12)
        #expect(points[4] == SIMD2(0.5, 0.5) && points[1] == SIMD2(0.5, 0))
    }
}
