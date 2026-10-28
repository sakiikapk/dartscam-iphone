import Foundation
import simd

/// 盤の寸法(mm、半径)。ソフトとハードで大きさもブルの分け方も違う
struct BoardSpec: Codable, Hashable {
    var name: String
    var rDoubleOut: Double
    var rDoubleIn: Double
    var rTripleOut: Double
    var rTripleIn: Double
    var rBullOuter: Double
    var rBullInner: Double
    /// ブルを 50(インナー)/25(アウター)に分けるか。ソフトのファットブルなら false
    var splitBull: Bool

    /// ソフト(DARTSLIVE Home、ダブル外径 15.5インチ)。比率は darts-home の src/report.py と同じ
    static func soft(diameter: Double = 393.7, name: String = "ソフト 15.5インチ(DARTSLIVE Home など)",
                     splitBull: Bool = false) -> BoardSpec {
        let r = diameter / 2
        let tm = r * 0.59
        return BoardSpec(name: name, rDoubleOut: r, rDoubleIn: r * 0.93, rTripleOut: tm + 5 * r / 196.85,
                         rTripleIn: tm - 5 * r / 196.85, rBullOuter: r * 0.10, rBullInner: r * 0.035,
                         splitBull: splitBull)
    }

    /// ハード(スティール)の公式寸法
    static let hard = BoardSpec(name: "ハード(スティール公式、ダブル外径 340mm)", rDoubleOut: 170, rDoubleIn: 162,
                                rTripleOut: 107, rTripleIn: 99, rBullOuter: 15.9, rBullInner: 6.35, splitBull: true)

    var rTripleMid: Double { (rTripleIn + rTripleOut) / 2 }
}

/// 今の盤の設定と、盤まわりの計算(座標はブル中心が原点、+x が 6、+y が 20 の方向、mm)
enum Board {
    /// アプリで選んでいる盤(設定画面で変える)
    static var spec: BoardSpec = .soft()

    static var rDoubleOut: Double { spec.rDoubleOut }
    static var rDoubleIn: Double { spec.rDoubleIn }
    static var rTripleOut: Double { spec.rTripleOut }
    static var rTripleIn: Double { spec.rTripleIn }
    static var rBull: Double { spec.rBullOuter }
    /// 20 の真上から時計回り
    static let segments = [20, 1, 18, 4, 13, 6, 10, 15, 2, 17, 3, 19, 7, 16, 8, 11, 14, 9, 12, 5]

    /// キャリブレーションでタップしてもらう点(mm)
    static var calibPoints: [(name: String, mm: SIMD2<Double>)] {
        [
            ("ブルの中心", [0, 0]),
            ("20 のダブルの外側のふち(真ん中)", [0, rDoubleOut]),
            ("6 のダブルの外側のふち(真ん中)", [rDoubleOut, 0]),
            ("3 のダブルの外側のふち(真ん中)", [0, -rDoubleOut]),
            ("11 のダブルの外側のふち(真ん中)", [-rDoubleOut, 0]),
        ]
    }

    /// 数字 n の真ん中の向き(数学の角度、ラジアン。6 が 0、20 が π/2)
    static func angle(of n: Int) -> Double {
        let k = Double(segments.firstIndex(of: n) ?? 0)
        return (90 - 18 * k) * .pi / 180
    }

    /// 着弾のラベルと点数(例 T20=60, D6=12, BULL=50, 25, OUT=0)
    static func score(x: Double, y: Double) -> (label: String, points: Int) {
        let r = hypot(x, y)
        if spec.splitBull {
            if r <= spec.rBullInner { return ("BULL", 50) }
            if r <= spec.rBullOuter { return ("25", 25) }
        } else if r <= spec.rBullOuter {
            return ("BULL", 50)
        }
        if r > spec.rDoubleOut { return ("OUT", 0) }
        var ang = 90 - atan2(y, x) * 180 / .pi
        ang = ang.truncatingRemainder(dividingBy: 360)
        if ang < 0 { ang += 360 }
        let seg = segments[Int((ang + 9) / 18) % 20]
        if r >= spec.rTripleIn && r <= spec.rTripleOut { return ("T\(seg)", seg * 3) }
        if r >= spec.rDoubleIn { return ("D\(seg)", seg * 2) }
        return ("S\(seg)", seg)
    }

    static func label(x: Double, y: Double) -> String { score(x: x, y: y).label }
}

/// 狙っているところ。ずれや命中率をここ基準で出す
enum Target: String, CaseIterable, Codable, Identifiable {
    case bull = "BULL", t20 = "T20", t19 = "T19", t18 = "T18", t17 = "T17", t16 = "T16", t15 = "T15"

    var id: String { rawValue }

    var point: SIMD2<Double> {
        guard self != .bull, let n = Int(rawValue.dropFirst()) else { return [0, 0] }
        let a = Board.angle(of: n), r = Board.spec.rTripleMid
        return [r * cos(a), r * sin(a)]
    }

    /// 命中とみなすラベル
    func isHit(_ label: String) -> Bool {
        self == .bull ? (label == "BULL" || label == "25") : label == rawValue
    }
}

/// 画像(px) ↔ 盤面(mm) の対応。タップした5点からホモグラフィを解く。
struct Calibration: Codable {
    var H: [Double]  // 画像px → mm(3x3 行優先)
    var imgW: Int
    var imgH: Int
    var tapsPx: [[Double]]
    /// "auto"(色で自動) / "manual"(5点タップ)
    var source: String = "manual"

    var mat: simd_double3x3 { Mat.from(H) }

    /// 自動キャリブレーションの結果から。tapsPx には盤上の5点を画像に戻した位置を入れておく(手動の初期位置用)
    init?(H h: simd_double3x3, imgW: Int, imgH: Int, source: String) {
        guard abs(h.determinant) > 1e-12 else { return nil }
        H = Mat.toArray(h)
        self.imgW = imgW
        self.imgH = imgH
        self.source = source
        tapsPx = Board.calibPoints.map { Mat.apply(h.inverse, $0.mm) }.map { [$0.x, $0.y] }
    }

    init?(tapsPx: [SIMD2<Double>], imgW: Int, imgH: Int) {
        let mm = Board.calibPoints.map(\.mm)
        guard tapsPx.count == mm.count, let h = Homography.solve(src: tapsPx, dst: mm) else { return nil }
        H = Mat.toArray(h)
        self.imgW = imgW
        self.imgH = imgH
        self.tapsPx = tapsPx.map { [$0.x, $0.y] }
    }

    /// 同じタップ位置で、今の盤の寸法として解き直す(盤の種類を変えたとき)
    func resolved() -> Calibration? {
        Calibration(tapsPx: tapsPx.map { SIMD2($0[0], $0[1]) }, imgW: imgW, imgH: imgH)
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
