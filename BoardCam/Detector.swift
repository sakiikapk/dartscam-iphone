import Foundation
import simd

/// 着弾1本ぶん
struct Hit: Identifiable {
    let id = UUID()
    var no: Int
    var t: Double  // セッション開始からの秒(動き始め=着弾)
    var wall: Date
    var tipPx: SIMD2<Double>?  // 処理画像(半分サイズ)の座標
    var mm: SIMD2<Double>?
    var note: String
    var before: RGBImage?
    var after: RGBImage?
    var round = 1
}

/// 固定カメラの盤面から、ダーツが刺さった瞬間とチップ位置を取る。
/// やっていることは src/board.py の detect_hits / find_tip と同じ(盤面が静止している前後の差分を見る)。
final class Detector {
    enum Result {
        case hit(t: Double, tip: SIMD2<Double>?, note: String, before: RGBImage, after: RGBImage)
        case reset  // ダーツを抜いた、人が前を通った
    }

    let cal: Calibration
    private let roi: (x0: Int, y0: Int, w: Int, h: Int)
    private let roiMask: [Bool]
    private let ppm: Double
    private let dartArea: Double

    private var prevSmall: [Int16]?
    private var lastQuiet: RGBImage?
    private var recent: [Float] = []
    private var eventStart: Double?
    private var eventBefore: RGBImage?
    private var lastActive = 0.0
    private(set) var dartsOnBoard = 0
    private let settle = 0.3  // 刺さった後の揺れが収まるまで(秒)

    init(cal: Calibration) {
        self.cal = cal
        ppm = cal.pxPerMM
        dartArea = 1500 * ppm * ppm  // 見かけ 150mm x 10mm
        // 盤の外周(ダブル外径の 1.2 倍)まで。外したダーツも盤の周りの黒い部分に刺さる
        let R = Board.rDoubleOut * 1.2
        let ring = (0..<72).map { k -> SIMD2<Double> in
            let a = Double(k) * .pi / 36
            return cal.toPx([R * cos(a), R * sin(a)])
        }
        let x0 = max(0, Int(ring.map(\.x).min()!) - 4), x1 = min(cal.imgW, Int(ring.map(\.x).max()!) + 4)
        let y0 = max(0, Int(ring.map(\.y).min()!) - 4), y1 = min(cal.imgH, Int(ring.map(\.y).max()!) + 4)
        roi = (x0, y0, max(1, x1 - x0), max(1, y1 - y0))
        var mask = [Bool](repeating: false, count: roi.w * roi.h)
        for y in 0..<roi.h {
            for x in 0..<roi.w {
                let mm = cal.toMM([Double(x + x0), Double(y + y0)])
                mask[y * roi.w + x] = simd_length(mm) < R
            }
        }
        roiMask = mask
    }

    func resetCount() { dartsOnBoard = 0 }

    /// 1フレームずつ渡す。着弾やリセットが確定したらそれを返す。
    func process(_ img: RGBImage, t: Double) -> Result? {
        let small = coarseGray(img)
        defer { prevSmall = small }
        guard let prev = prevSmall else { lastQuiet = img; return nil }
        var s: Float = 0
        for i in 0..<small.count { s += Float(abs(small[i] - prev[i])) }
        let motion = s / Float(max(1, small.count))
        recent.append(motion)
        if recent.count > 150 { recent.removeFirst() }
        guard recent.count >= 15 else { lastQuiet = img; return nil }
        let quiet = quietLevel()

        if motion > quiet {
            if eventStart == nil {
                eventStart = t
                eventBefore = lastQuiet
            }
            lastActive = t
            return nil
        }
        guard let start = eventStart, let before = eventBefore else {
            lastQuiet = img
            return nil
        }
        if t - lastActive < settle { return nil }
        // 動きが収まった。前後を比べる
        eventStart = nil
        eventBefore = nil
        lastQuiet = img
        let (count, diff) = changed(before, img)
        if count < dartArea * 0.04 { return nil }  // 露出の揺れ、影だけ
        if count > dartArea * 3 || lastActive - start > 2.0 || dartsOnBoard >= 3 {
            dartsOnBoard = 0
            return .reset
        }
        dartsOnBoard += 1
        let off = SIMD2<Double>(Double(roi.x0), Double(roi.y0))
        if let r = findTip(diff, off: off) {
            return .hit(t: start, tip: r.0 + off, note: r.1, before: before, after: img)
        }
        return .hit(t: start, tip: nil, note: "no_dart_found", before: before, after: img)
    }

    private func quietLevel() -> Float {
        let s = recent.sorted()
        let med = s[s.count / 2]
        let dev = recent.map { abs($0 - med) }.sorted()
        let mad = dev[dev.count / 2]
        // 着弾の小さな揺れも拾えるよう、ノイズの中央値+4MAD(board.py と同じ)
        return max(1.0, med + 4 * mad)
    }

    /// 盤面ROIを4画素おきに見たグレー
    private func coarseGray(_ img: RGBImage) -> [Int16] {
        var out: [Int16] = []
        out.reserveCapacity((roi.w / 4 + 1) * (roi.h / 4 + 1))
        img.px.withUnsafeBufferPointer { p in
            for y in stride(from: roi.y0, to: roi.y0 + roi.h, by: 4) {
                for x in stride(from: roi.x0, to: roi.x0 + roi.w, by: 4) {
                    let i = (y * img.w + x) * 3
                    let r = Int(p[i]), g = Int(p[i + 1]), b = Int(p[i + 2])
                    out.append(Int16((r + 2 * g + b) >> 2))
                }
            }
        }
        return out
    }

    /// 前後の差分(ROI、色ごとの差の最大)。明るさの変化は色ごとの中央値でそろえる
    private func changed(_ a: RGBImage, _ b: RGBImage) -> (Double, [Float]) {
        let W = roi.w, Hh = roi.h
        let A = blurROI(a), B = blurROI(b)
        var gain = [Float](repeating: 1, count: 3)
        for c in 0..<3 {
            let ma = median(A, channel: c), mb = median(B, channel: c)
            gain[c] = ma / max(mb, 1)
        }
        var d = [Float](repeating: 0, count: W * Hh)
        var count = 0.0
        for i in 0..<(W * Hh) where roiMask[i] {
            var m: Float = 0
            for c in 0..<3 { m = max(m, abs(A[i * 3 + c] - B[i * 3 + c] * gain[c])) }
            d[i] = m
            if m > 40 { count += 1 }
        }
        return (count, d)
    }

    private func blurROI(_ img: RGBImage) -> [Float] {
        let W = roi.w, Hh = roi.h
        var out = [Float](repeating: 0, count: W * Hh * 3)
        img.px.withUnsafeBufferPointer { p in
            for y in 0..<Hh {
                let gy = y + roi.y0
                for x in 0..<W {
                    let gx = x + roi.x0
                    for c in 0..<3 {
                        var s = 0, n = 0
                        for yy in max(0, gy - 1)...min(img.h - 1, gy + 1) {
                            for xx in max(0, gx - 1)...min(img.w - 1, gx + 1) {
                                s += Int(p[(yy * img.w + xx) * 3 + c])
                                n += 1
                            }
                        }
                        out[(y * W + x) * 3 + c] = Float(s) / Float(n)
                    }
                }
            }
        }
        return out
    }

    private func median(_ buf: [Float], channel c: Int) -> Float {
        var hist = [Int](repeating: 0, count: 256)
        var n = 0
        for i in 0..<(roi.w * roi.h) where roiMask[i] {
            hist[min(255, Int(buf[i * 3 + c]))] += 1
            n += 1
        }
        var acc = 0
        for v in 0..<256 {
            acc += hist[v]
            if acc * 2 >= n { return Float(v) }
        }
        return 128
    }

    // MARK: - チップ探し(src/board.py の find_tip を移植)

    private func findTip(_ diff: [Float], off: SIMD2<Double>) -> (SIMD2<Double>, String)? {
        let W = roi.w, Hh = roi.h
        let scale = max(ppm, 0.5)
        let m = Morph.close(diff.map { $0 > 40 }, W, Hh, r: 2)
        let cc = Morph.components(m, W, Hh)
        guard let big = cc.stats.max(by: { $0.area < $1.area }) else { return nil }
        let c = big.centroid
        let reach = 160 * scale
        var m2 = [Bool](repeating: false, count: W * Hh)
        for y in 0..<Hh {
            for x in 0..<W where diff[y * W + x] > 22 {
                m2[y * W + x] = hypot(Double(x) - c.x, Double(y) - c.y) < reach
            }
        }
        let cc2 = Morph.components(Morph.close(m2, W, Hh, r: 2), W, Hh)
        var j = cc2.labels[Int(c.y) * W + Int(c.x)]
        if j < 0 { j = cc2.stats.indices.max(by: { cc2.stats[$0].area < cc2.stats[$1].area }) ?? -1 }
        guard j >= 0 else { return nil }
        var pts: [SIMD2<Double>] = []
        for i in 0..<(W * Hh) where cc2.labels[i] == j { pts.append([Double(i % W), Double(i / W)]) }
        guard pts.count > 5 else { return nil }
        var (mu, ax) = Morph.fitLine(pts)
        // ax をチップ→フライト向きにそろえる(盤面法線の見かけの向きで決める)
        let dv = cal.dartVec(mu + off)
        let dvn = simd_normalize(dv)
        if simd_dot(ax, dv) < 0 { ax = -ax }
        let band = max(3, Int((2 * scale).rounded()))
        // 斜め下から撮るとフライトが一番大きな塊になる。太さのある変化をフライトからチップ側に
        // 1本ぶんまで集めて直線を当て直す(board.py と同じ理由)
        let thick = Morph.open(diff.map { $0 > 30 }, W, Hh, r: 2)
        let back = -dvn
        let expect0 = simd_length(cal.dartVec(c + off, lengthMM: 140))
        let cos30 = cos(30 * Double.pi / 180), cos35 = cos(35 * Double.pi / 180)
        var sel: [SIMD2<Double>] = []
        for i in 0..<(W * Hh) where thick[i] {
            let p = SIMD2<Double>(Double(i % W), Double(i / W))
            let rel = p - c
            let dist = simd_length(rel)
            let cosang = simd_dot(rel, back) / max(dist, 1e-6)
            if dist < 30 * scale || (cosang > cos30 && dist < 1.1 * expect0) { sel.append(p) }
        }
        if sel.count > 30 {
            var (mu2, cand) = Morph.fitLine(sel)
            if simd_dot(cand, dv) < 0 { cand = -cand }
            if simd_dot(cand, dvn) > cos35 {
                ax = cand
                mu = mu2
                pts += sel
            }
        }
        let nrm = SIMD2<Double>(-ax.y, ax.x)
        var pr = pts.map { simd_dot($0 - mu, ax) }
        let onLine = pts.filter { abs(simd_dot($0 - mu, nrm)) <= Double(2 * band) }.map { simd_dot($0 - mu, ax) }
        if onLine.count > 10 { pr = onLine }
        // 差分の塊のチップ側の端から、さらにチップ側へ変化が途切れるまで辿る
        let expect = simd_length(cal.dartVec(mu + off, lengthMM: 140))
        let start = pr.min()!, end = pr.max()!
        var prof: [(Double, Float)] = []
        var t = start + 20 * scale
        while t > start - 0.9 * expect {
            var v: Float = 0
            for s in -band...band {
                let q = mu + t * ax + Double(s) * nrm
                let qx = Int(q.x.rounded()), qy = Int(q.y.rounded())
                if qx >= 0 && qx < W && qy >= 0 && qy < Hh { v = max(v, diff[qy * W + qx]) }
            }
            prof.append((t, v))
            t -= 1
        }
        guard !prof.isEmpty else { return nil }
        var last = 0, gap = 0
        for k in 0..<prof.count {
            let a = prof[max(0, k - 1)].1, b = prof[k].1, c3 = prof[min(prof.count - 1, k + 1)].1
            if (a + b + c3) / 3 > 20 {
                last = k
                gap = 0
            } else {
                gap += 1
                if Double(gap) > 6 * scale { break }
            }
        }
        let tip = mu + prof[last].0 * ax
        // 見えている長さが1本の 1/4 もなければ、チップはフライトの裏に隠れている
        let seen = end - prof[last].0
        return (tip, seen < 0.25 * expect ? "tip_hidden" : "")
    }
}

/// 2値画像の簡単な処理(OpenCV の代わり)
enum Morph {
    struct Stat {
        var area: Int
        var centroid: SIMD2<Double>
    }

    static func dilate(_ m: [Bool], _ W: Int, _ H: Int, r: Int) -> [Bool] {
        var tmp = [Bool](repeating: false, count: m.count), out = tmp
        for y in 0..<H {
            for x in 0..<W where m[y * W + x] {
                for xx in max(0, x - r)...min(W - 1, x + r) { tmp[y * W + xx] = true }
            }
        }
        for y in 0..<H {
            for x in 0..<W where tmp[y * W + x] {
                for yy in max(0, y - r)...min(H - 1, y + r) { out[yy * W + x] = true }
            }
        }
        return out
    }

    static func erode(_ m: [Bool], _ W: Int, _ H: Int, r: Int) -> [Bool] {
        dilate(m.map { !$0 }, W, H, r: r).map { !$0 }
    }

    static func close(_ m: [Bool], _ W: Int, _ H: Int, r: Int) -> [Bool] {
        erode(dilate(m, W, H, r: r), W, H, r: r)
    }

    static func open(_ m: [Bool], _ W: Int, _ H: Int, r: Int) -> [Bool] {
        dilate(erode(m, W, H, r: r), W, H, r: r)
    }

    /// 8近傍の連結成分。labels は成分番号(背景は -1)
    static func components(_ m: [Bool], _ W: Int, _ H: Int) -> (labels: [Int], stats: [Stat]) {
        var labels = [Int](repeating: -1, count: m.count)
        var stats: [Stat] = []
        var stack: [Int] = []
        for s in 0..<m.count where m[s] && labels[s] < 0 {
            let id = stats.count
            labels[s] = id
            stack.append(s)
            var n = 0, sx = 0.0, sy = 0.0
            while let i = stack.popLast() {
                let x = i % W, y = i / W
                n += 1
                sx += Double(x)
                sy += Double(y)
                for dy in -1...1 {
                    for dx in -1...1 {
                        let xx = x + dx, yy = y + dy
                        guard xx >= 0, xx < W, yy >= 0, yy < H else { continue }
                        let k = yy * W + xx
                        if m[k] && labels[k] < 0 {
                            labels[k] = id
                            stack.append(k)
                        }
                    }
                }
            }
            stats.append(Stat(area: n, centroid: [sx / Double(n), sy / Double(n)]))
        }
        return (labels, stats)
    }

    /// 点群に直線を当てる(主成分の向き)。返すのは (通る点, 単位方向)
    static func fitLine(_ pts: [SIMD2<Double>]) -> (SIMD2<Double>, SIMD2<Double>) {
        let mu = pts.reduce(SIMD2<Double>(0, 0), +) / Double(pts.count)
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for p in pts {
            let d = p - mu
            sxx += d.x * d.x
            sxy += d.x * d.y
            syy += d.y * d.y
        }
        let ang = 0.5 * atan2(2 * sxy, sxx - syy)
        return (mu, [cos(ang), sin(ang)])
    }
}
