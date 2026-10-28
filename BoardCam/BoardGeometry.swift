import Foundation
import simd

/// 盤面の寸法(DARTSLIVE Home, ダブル外周 Ø393.7mm)。比率は src/report.py と同じ
enum Board {
    static let rDoubleOut = 393.7 / 2
    static let rDoubleIn = rDoubleOut * 0.93
    static let rTripleMid = rDoubleOut * 0.59
    static let rTripleOut = rTripleMid + 5
    static let rTripleIn = rTripleMid - 5
    static let rBull = rDoubleOut * 0.10  // ファットブル
    /// 20 の真上から時計回り
    static let segments = [20, 1, 18, 4, 13, 6, 10, 15, 2, 17, 3, 19, 7, 16, 8, 11, 14, 9, 12, 5]

    /// キャリブレーションでタップしてもらう点(mm)。座標はブル中心が原点、+x が 6、+y が 20 の方向
    static let calibPoints: [(name: String, mm: SIMD2<Double>)] = [
        ("ブルの中心", [0, 0]),
        ("20 のダブルの外側のふち(真ん中)", [0, rDoubleOut]),
        ("6 のダブルの外側のふち(真ん中)", [rDoubleOut, 0]),
        ("3 のダブルの外側のふち(真ん中)", [0, -rDoubleOut]),
        ("11 のダブルの外側のふち(真ん中)", [-rDoubleOut, 0]),
    ]

    /// 着弾のラベル(例 T20, D6, S1, BULL, OUT)
    static func label(x: Double, y: Double) -> String {
        let r = hypot(x, y)
        if r <= rBull { return "BULL" }
        if r > rDoubleOut { return "OUT" }
        var ang = 90 - atan2(y, x) * 180 / .pi
        ang = ang.truncatingRemainder(dividingBy: 360)
        if ang < 0 { ang += 360 }
        let seg = segments[Int((ang + 9) / 18) % 20]
        if r >= rTripleIn && r <= rTripleOut { return "T\(seg)" }
        if r >= rDoubleIn { return "D\(seg)" }
        return "S\(seg)"
    }
}

/// 画像(px) ↔ 盤面(mm) の対応。タップした5点からホモグラフィを解く。
struct Calibration: Codable {
    var H: [Double]  // 画像px → mm(3x3 行優先)
    var imgW: Int
    var imgH: Int
    var tapsPx: [[Double]]

    var mat: simd_double3x3 { Mat.from(H) }

    init?(tapsPx: [SIMD2<Double>], imgW: Int, imgH: Int) {
        let mm = Board.calibPoints.map(\.mm)
        guard tapsPx.count == mm.count, let h = Homography.solve(src: tapsPx, dst: mm) else { return nil }
        H = Mat.toArray(h)
        self.imgW = imgW
        self.imgH = imgH
        self.tapsPx = tapsPx.map { [$0.x, $0.y] }
    }

    func toMM(_ p: SIMD2<Double>) -> SIMD2<Double> { Mat.apply(mat, p) }
    func toPx(_ p: SIMD2<Double>) -> SIMD2<Double> { Mat.apply(mat.inverse, p) }

    /// 盤中心付近の解像度(px/mm)
    var pxPerMM: Double {
        let c = toPx([0, 0])
        let d = [SIMD2<Double>(30, 0), [-30, 0], [0, 30], [0, -30]].map { simd_length(toPx($0) - c) }
        return d.reduce(0, +) / Double(d.count) / 30
    }

    /// 5点のあてはまり(タップ位置と、解いた変換で戻した位置のずれ、mm)
    var fitErrorMM: Double {
        let mm = Board.calibPoints.map(\.mm)
        let e = zip(tapsPx, mm).map { simd_length(toMM([$0[0], $0[1]]) - $1) }
        return e.max() ?? 0
    }

    /// 盤上の点 px に垂直に刺さったダーツの、チップ→フライト方向の画像上ベクトル(長さ lengthMM 分)。
    /// src/board.py の Calibration.dart_vec と同じ考え方(焦点距離は長辺の 0.8 倍と仮定)。
    func dartVec(_ px: SIMD2<Double>, lengthMM: Double = 100) -> SIMD2<Double> {
        let w = Double(imgW), h = Double(imgH)
        let f = 0.8 * max(w, h)
        let K = simd_double3x3(rows: [[f, 0, w / 2], [0, f, h / 2], [0, 0, 1]])
        let G = K.inverse * mat.inverse  // 盤面mm → 正規化カメラ座標
        let lam = 1 / simd_length(G.columns.0)
        var r1 = G.columns.0 * lam, r2 = G.columns.1 * lam, t = G.columns.2 * lam
        if t.z < 0 { r1 = -r1; r2 = -r2; t = -t }
        var n = simd_cross(r1, r2)
        let P0 = toMM(px)
        let X0 = r1 * P0.x + r2 * P0.y + t
        if simd_dot(n, -X0) < 0 { n = -n }
        let X1 = X0 + n * lengthMM
        let p0 = K * X0, p1 = K * X1
        return SIMD2(p1.x / p1.z, p1.y / p1.z) - SIMD2(p0.x / p0.z, p0.y / p0.z)
    }
}

enum Mat {
    static func from(_ a: [Double]) -> simd_double3x3 {
        simd_double3x3(rows: [[a[0], a[1], a[2]], [a[3], a[4], a[5]], [a[6], a[7], a[8]]])
    }

    static func toArray(_ m: simd_double3x3) -> [Double] {
        (0..<3).flatMap { r in (0..<3).map { c in m[c][r] } }
    }

    static func apply(_ m: simd_double3x3, _ p: SIMD2<Double>) -> SIMD2<Double> {
        let v = m * SIMD3(p.x, p.y, 1)
        return SIMD2(v.x / v.z, v.y / v.z)
    }
}

enum Homography {
    /// 4点以上の対応から最小二乗で解く(座標は正規化してから)
    static func solve(src: [SIMD2<Double>], dst: [SIMD2<Double>]) -> simd_double3x3? {
        let Ts = normalizer(src), Td = normalizer(dst)
        let s = src.map { Mat.apply(Ts, $0) }, d = dst.map { Mat.apply(Td, $0) }
        // h33 = 1 として 8 未知数の正規方程式
        var A = [[Double]](repeating: [Double](repeating: 0, count: 8), count: 8)
        var b = [Double](repeating: 0, count: 8)
        for (p, q) in zip(s, d) {
            let rows: [([Double], Double)] = [
                ([p.x, p.y, 1, 0, 0, 0, -p.x * q.x, -p.y * q.x], q.x),
                ([0, 0, 0, p.x, p.y, 1, -p.x * q.y, -p.y * q.y], q.y),
            ]
            for (r, v) in rows {
                for i in 0..<8 {
                    for j in 0..<8 { A[i][j] += r[i] * r[j] }
                    b[i] += r[i] * v
                }
            }
        }
        guard let h = gaussSolve(A, b) else { return nil }
        let Hn = Mat.from(h + [1])
        return Td.inverse * Hn * Ts
    }

    private static func normalizer(_ pts: [SIMD2<Double>]) -> simd_double3x3 {
        let c = pts.reduce(SIMD2<Double>(0, 0), +) / Double(pts.count)
        let md = pts.map { simd_length($0 - c) }.reduce(0, +) / Double(pts.count)
        let k = md > 0 ? 2.0.squareRoot() / md : 1
        return simd_double3x3(rows: [[k, 0, -k * c.x], [0, k, -k * c.y], [0, 0, 1]])
    }

    private static func gaussSolve(_ A0: [[Double]], _ b0: [Double]) -> [Double]? {
        var A = A0, b = b0
        let n = b.count
        for col in 0..<n {
            guard let piv = (col..<n).max(by: { abs(A[$0][col]) < abs(A[$1][col]) }),
                  abs(A[piv][col]) > 1e-12 else { return nil }
            A.swapAt(col, piv)
            b.swapAt(col, piv)
            for r in (col + 1)..<n {
                let f = A[r][col] / A[col][col]
                if f == 0 { continue }
                for c in col..<n { A[r][c] -= f * A[col][c] }
                b[r] -= f * b[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = b[r]
            for c in (r + 1)..<n { s -= A[r][c] * x[c] }
            x[r] = s / A[r][r]
        }
        return x
    }
}
