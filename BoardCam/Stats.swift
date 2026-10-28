import Foundation
import simd

/// 集計用の1本(座標が取れたものだけ)
struct Shot {
    var no: Int
    var mm: SIMD2<Double>
    var round: Int
    var label: String
    var points: Int
}

/// 1セッションの集計。ライブの画面と過去セッションの画面で共通
struct SessionStats {
    let shots: [Shot]
    let target: Target
    let n: Int
    let mean: SIMD2<Double>
    /// 共分散 (xx, xy, yy)
    let cov: SIMD3<Double>
    let roundTotals: [(round: Int, labels: [String], total: Int)]

    init(shots: [Shot], target: Target) {
        self.shots = shots
        self.target = target
        n = shots.count
        let m = n > 0 ? shots.map(\.mm).reduce(SIMD2<Double>(0, 0), +) / Double(n) : SIMD2<Double>(0, 0)
        mean = m
        if n >= 2 {
            var c = SIMD3<Double>(0, 0, 0)
            for s in shots {
                let d = s.mm - m
                c += SIMD3(d.x * d.x, d.x * d.y, d.y * d.y)
            }
            cov = c / Double(n - 1)
        } else {
            cov = SIMD3(0, 0, 0)
        }
        var byRound: [Int: [Shot]] = [:]
        for s in shots { byRound[s.round, default: []].append(s) }
        roundTotals = byRound.keys.sorted().map { r in
            let ss = byRound[r]!
            return (r, ss.map(\.label), ss.map(\.points).reduce(0, +))
        }
    }

    var sx: Double { cov.x.squareRoot() }
    var sy: Double { cov.z.squareRoot() }
    /// x と y の σ をならした「円で言うとこのくらい散っている」(darts-home の report.py と同じ)
    var sigma: Double { ((cov.x + cov.z) / 2).squareRoot() }

    /// 狙いからの平均のずれ
    var offset: SIMD2<Double> { mean - target.point }

    var offsetText: String {
        let d = offset
        let h = abs(d.x) < 3 ? "左右はほぼ真ん中" : String(format: "%@に%.0fmm", d.x > 0 ? "右" : "左", abs(d.x))
        let v = abs(d.y) < 3 ? "上下はほぼ真ん中" : String(format: "%@に%.0fmm", d.y > 0 ? "上" : "下", abs(d.y))
        return "\(h)・\(v)"
    }

    /// 狙いからの距離の中央値(半分の矢がこの円の中)
    var medianDistance: Double {
        let d = shots.map { simd_length($0.mm - target.point) }.sorted()
        return d.isEmpty ? 0 : d[d.count / 2]
    }

    var hitRate: Double {
        n == 0 ? 0 : Double(shots.filter { target.isHit($0.label) }.count) / Double(n)
    }

    var pointsPerDart: Double { n == 0 ? 0 : Double(shots.map(\.points).reduce(0, +)) / Double(n) }
    /// 1ラウンド(3本)平均 = 01 のスタッツ相当
    var ppr: Double { pointsPerDart * 3 }
    /// DARTSLIVE のレーティング目安(01スタッツ ≒ 30 + 5×Rt、darts-home の report.py と同じざっくり換算)
    var rating: Double { min(18, max(1, (ppr - 30) / 5)) }

    /// 共分散の楕円(k シグマ)の輪郭
    func ellipse(k: Double, steps: Int = 72) -> [SIMD2<Double>] {
        let a = cov.x, b = cov.y, c = cov.z
        let tr = (a + c) / 2, det = ((a - c) / 2) * ((a - c) / 2) + b * b
        let l1 = tr + det.squareRoot(), l2 = max(0, tr - det.squareRoot())
        let th = 0.5 * atan2(2 * b, a - c)
        let e1 = SIMD2<Double>(cos(th), sin(th)), e2 = SIMD2<Double>(-sin(th), cos(th))
        return (0...steps).map { i in
            let t = Double(i) / Double(steps) * 2 * .pi
            return mean + k * (l1.squareRoot() * cos(t) * e1 + l2.squareRoot() * sin(t) * e2)
        }
    }
}

/// 保存済みのセッション(Documents/sessions/<日時>/hits.csv)
struct SavedSession: Identifiable {
    let dir: URL
    let shots: [Shot]
    let count: Int
    var id: URL { dir }
    var name: String { dir.lastPathComponent }

    static func loadAll() -> [SavedSession] {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = docs.appendingPathComponent("sessions", isDirectory: true)
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.sorted { $0.lastPathComponent > $1.lastPathComponent }.compactMap { load($0) }
    }

    static func load(_ dir: URL) -> SavedSession? {
        guard let text = try? String(contentsOf: dir.appendingPathComponent("hits.csv"), encoding: .utf8) else {
            return nil
        }
        var lines = text.split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
        guard !lines.isEmpty else { return nil }
        let head = lines.removeFirst()
        func col(_ name: String) -> Int? { head.firstIndex(of: name) }
        guard let ix = col("x_mm"), let iy = col("y_mm") else { return nil }
        let ir = col("round_no"), ino = col("hit_no")
        var shots: [Shot] = []
        for (k, f) in lines.enumerated() {
            guard f.count > max(ix, iy), let x = Double(f[ix]), let y = Double(f[iy]) else { continue }
            let r = ir.flatMap { $0 < f.count ? Int(f[$0]) : nil } ?? (k / 3 + 1)
            let no = ino.flatMap { $0 < f.count ? Int(f[$0]) : nil } ?? (k + 1)
            let sc = Board.score(x: x, y: y)
            shots.append(Shot(no: no, mm: [x, y], round: r, label: sc.label, points: sc.points))
        }
        return SavedSession(dir: dir, shots: shots, count: lines.count)
    }
}
