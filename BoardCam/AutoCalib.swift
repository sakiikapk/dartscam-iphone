import Foundation
import simd

/// 盤面の赤青(ハードなら赤緑)のマスを色で拾って、タップなしでキャリブレーションする。
/// darts-home の src/board.py の calibrate() の移植。
///
/// 1. 色でマスを拾い、盤面のマス群(似た大きさで密集している塊)だけ残す
/// 2. 真ん中の赤 = ブル。各マスをブルからの向きで「近い=トリプル / 遠い=ダブル」に分ける
/// 3. ダブルの並びに楕円を当てて各マスのおおよその角度を出し、20 通りの回転のうち
///    色の偶奇が合うものだけホモグラフィを解いて、「20 が上」に一番近いものを採る
/// 4. 盤面座標で角度を取り直して1回だけ精密化
enum AutoCalib {
    struct Cell {
        var xy: SIMD2<Double>
        var area: Int
        var red: Bool
        var ring = ""  // "double" / "treble" / "bull" / "?"
        var seg = 0
    }

    struct Result {
        var cal: Calibration
        var nCells: Int
        var rmsPx: Double
        var upMarginDeg: Double
    }

    /// 盤上の数字の並び(6 から反時計回り、18°刻み)。board.py の ORDER
    static let order = [6, 13, 4, 18, 1, 20, 5, 12, 9, 14, 11, 8, 16, 7, 19, 3, 17, 2, 15, 10]
    /// 20 のダブル/トリプルは赤。この偶奇のマスが赤
    static let redParity = order.firstIndex(of: 20)! % 2

    /// up: 画面の上が画像のどっち向きか(横持ちなら (0,-1)、縦持ちなら (-1,0))。
    /// hint20Px: 「20 はここ」とタップされた画像上の位置。あれば「20 が上」よりこっちを優先する
    static func calibrate(_ img: RGBImage, up: SIMD2<Double> = [0, -1], hint20Px: SIMD2<Double>? = nil) -> Result? {
        var cells = pickBoardCells(findCells(img), img: img)
        guard cells.count >= 10, let bull = findBull(cells) else { return nil }
        labelRings(&cells, bull: bull)
        var ringIdx = cells.indices.filter { cells[$0].ring == "double" || cells[$0].ring == "treble" }

        // 1) ダブルの重心にブル中心の楕円を当て、円に戻してから各マスの角度を出す。
        //    盤の外の青(カーテンなど)がダブル扱いで混ざると楕円が崩れるので、4個ずつ選んで楕円を作り、
        //    いちばん多くのダブルが乗るものを採る(RANSAC)。そのあと楕円上の距離でダブル/トリプルを付け直す
        let c0 = cells[bull].xy
        var ea = 0.0, eb = 0.0, th = 0.0
        var rot = simd_double2x2(1)
        func setEllipse(_ e: (Double, Double, Double)) {
            (ea, eb, th) = e
            rot = simd_double2x2(rows: [[cos(th), sin(th)], [-sin(th), cos(th)]])
        }
        func rho(_ i: Int) -> Double {
            let p = rot * (cells[i].xy - c0)
            return hypot(p.x / ea, p.y / eb)
        }
        let dblAll = ringIdx.filter { cells[$0].ring == "double" }
        guard dblAll.count >= 5 else { return nil }
        var best: [Int] = []
        for _ in 0..<300 {
            var pick = Set<Int>()
            while pick.count < 4 { pick.insert(dblAll.randomElement()!) }
            guard let e = centeredEllipse(pick.map { cells[$0].xy - c0 }), e.0 < 4 * e.1, e.1 < 4 * e.0 else { continue }
            setEllipse(e)
            let inl = dblAll.filter { abs(rho($0) - 1) < 0.12 }
            if inl.count > best.count { best = inl }
        }
        guard best.count >= 5, let ell = centeredEllipse(best.map { cells[$0].xy - c0 }) else { return nil }
        setEllipse(ell)
        let tRatio = Board.spec.rTripleMid / ((Board.spec.rDoubleIn + Board.spec.rDoubleOut) / 2)
        for i in cells.indices where i != bull {
            let r = rho(i)
            cells[i].ring = abs(r - 1) < 0.13 ? "double" : abs(r - tRatio) < 0.13 ? "treble" : "out"
        }
        ringIdx = cells.indices.filter { cells[$0].ring == "double" || cells[$0].ring == "treble" }
        for i in ringIdx {
            var p = rot * (cells[i].xy - c0)
            p = [p.x / ea, p.y / eb]
            // 画像は y が下向き。円に戻したあと y を反転すると盤面の反時計回りの角度になる
            let deg = atan2(-p.y, p.x) * 180 / .pi
            cells[i].seg = ((Int((deg / 18).rounded()) % 20) + 20) % 20
        }
        // 2) 回転候補ごとに、色の偶奇が合うものだけホモグラフィを当てる
        var cands: [(up: Double, k: Int, H: simd_double3x3)] = []
        for k in 0..<20 {
            let agree = ringIdx.filter { (((cells[$0].seg + k) % 20) % 2 == redParity) == cells[$0].red }.count
            if Double(agree) / Double(ringIdx.count) < 0.8 { continue }
            let (src, dst) = boardPoints(cells, shift: k)
            guard let H = ransacHomography(src: src, dst: dst, thresholdPx: 6)?.H else { continue }
            // 3) 「20 が上」: 盤面の +y が画面の上(up)を向く候補ほど良い。20 の位置をタップしてもらったらそっち
            let inv = H.inverse
            let p0 = Mat.apply(inv, [0, 0]), p1 = Mat.apply(inv, [0, 100])
            let v = simd_normalize(p1 - p0)
            let ref = hint20Px.map { simd_normalize($0 - p0) } ?? simd_normalize(up)
            let ang = acos(max(-1, min(1, simd_dot(v, ref)))) * 180 / .pi
            cands.append((ang, k, H))
        }
        guard !cands.isEmpty else { return nil }
        cands.sort { $0.up < $1.up }
        let margin = cands.count > 1 ? cands[1].up - cands[0].up : 180
        let H0 = cands[0].H
        // 4) 角度を盤面座標で取り直して1回だけ精密化(遠近で楕円近似の角度がずれる分を直す)
        for i in ringIdx {
            let q = Mat.apply(H0, cells[i].xy)
            let deg = atan2(q.y, q.x) * 180 / .pi
            cells[i].seg = ((Int((deg / 18).rounded()) % 20) + 20) % 20
        }
        let (src, dst) = boardPoints(cells, shift: 0)
        guard let fit = ransacHomography(src: src, dst: dst, thresholdPx: 6), fit.inliers.count >= 8 else { return nil }
        let inv = fit.H.inverse
        var se = 0.0
        for i in fit.inliers { se += simd_length_squared(Mat.apply(inv, dst[i]) - src[i]) }
        let rms = (se / Double(fit.inliers.count)).squareRoot()
        guard let cal = Calibration(H: fit.H, imgW: img.w, imgH: img.h, source: "auto") else { return nil }
        return Result(cal: cal, nCells: fit.inliers.count, rmsPx: rms, upMarginDeg: margin)
    }

    // MARK: - マスを拾う

    /// 赤と、青(ハードなら緑)のマスの連結成分
    static func findCells(_ img: RGBImage) -> [Cell] {
        let W = img.w, Hh = img.h
        var red = [Bool](repeating: false, count: W * Hh)
        var other = red
        let greenBoard = Board.spec.name.hasPrefix("ハード")
        img.px.withUnsafeBufferPointer { p in
            for i in 0..<(W * Hh) {
                let r = Double(p[i * 3]), g = Double(p[i * 3 + 1]), b = Double(p[i * 3 + 2])
                let mx = max(r, g, b), mn = min(r, g, b)
                let v = mx, s = mx > 0 ? (mx - mn) / mx * 255 : 0
                guard v > 70, s > 70 else { continue }
                let d = mx - mn
                var h: Double
                if d == 0 { h = 0 } else if mx == r { h = 60 * ((g - b) / d) } else if mx == g { h = 60 * (2 + (b - r) / d) } else { h = 60 * (4 + (r - g) / d) }
                if h < 0 { h += 360 }
                h /= 2  // OpenCV と同じ 0..180
                if h < 10 || h > 165 {
                    red[i] = true
                } else if greenBoard {
                    if h > 35 && h < 85 && s > 60 { other[i] = true }
                } else if h > 100 && h < 130 && s > 90 {
                    other[i] = true
                }
            }
        }
        let minArea = Double(W * Hh) * 5e-6 * 4  // 元の 1920x1080 基準の 5e-6 を半分サイズに合わせる
        var cells: [Cell] = []
        for (mask, isRed) in [(red, true), (other, false)] {
            let m = Morph.open(mask, W, Hh, r: 1)
            let cc = Morph.components(m, W, Hh)
            for st in cc.stats where Double(st.area) >= minArea {
                cells.append(Cell(xy: st.centroid, area: st.area, red: isRed))
            }
        }
        return cells
    }

    /// 盤面の赤青マス群だけを残す(床のダーツや飾りの赤を捨てる)。
    /// 盤面のマスは似た大きさで密集しているので、面積の中央値付近かつ互いに近いものの最大の塊を取る
    static func pickBoardCells(_ cells: [Cell], img: RGBImage) -> [Cell] {
        guard cells.count >= 8 else { return [] }
        let areas = cells.map { Double($0.area) }
        // 盤面のマスは最大41個。細かいノイズに引っ張られないよう、大きい方の40個で基準を取る
        let top = areas.sorted().suffix(40)
        let med = Array(top)[top.count / 2]
        let ok = areas.map { $0 > med / 6 && $0 < med * 6 }
        let n = cells.count
        var d = [[Double]](repeating: [Double](repeating: .infinity, count: n), count: n)
        for i in 0..<n where ok[i] {
            for j in 0..<n where ok[j] && i != j { d[i][j] = simd_length(cells[i].xy - cells[j].xy) }
        }
        let nearest = (0..<n).filter { ok[$0] }.map { d[$0].min() ?? .infinity }.filter { $0.isFinite }.sorted()
        guard !nearest.isEmpty else { return [] }
        let link = nearest[nearest.count / 2] * 4
        var label = [Int](repeating: -1, count: n)
        var cur = 0
        for i in 0..<n where ok[i] && label[i] < 0 {
            var stack = [i]
            label[i] = cur
            while let j = stack.popLast() {
                for k in 0..<n where ok[k] && label[k] < 0 && d[j][k] < link {
                    label[k] = cur
                    stack.append(k)
                }
            }
            cur += 1
        }
        guard cur > 0 else { return [] }
        var count = [Int](repeating: 0, count: cur)
        for l in label where l >= 0 { count[l] += 1 }
        let best = count.indices.max { count[$0] < count[$1] }!
        return cells.indices.filter { label[$0] == best }.map { cells[$0] }
    }

    /// ブル(赤いリング)。マス群の中心にいちばん近い赤
    static func findBull(_ cells: [Cell]) -> Int? {
        let c = cells.map(\.xy).reduce(SIMD2<Double>(0, 0), +) / Double(cells.count)
        return cells.indices.filter { cells[$0].red }.min { simd_length(cells[$0].xy - c) < simd_length(cells[$1].xy - c) }
    }

    /// ブルから見た方向ごとに、近いマス=トリプル、遠いマス=ダブルに分ける
    static func labelRings(_ cells: inout [Cell], bull: Int) {
        let c0 = cells[bull].xy
        let others = cells.indices.filter { $0 != bull }
        var ang: [Int: Double] = [:], dist: [Int: Double] = [:]
        for i in others {
            let v = cells[i].xy - c0
            ang[i] = atan2(v.y, v.x)
            dist[i] = simd_length(v)
        }
        func dAng(_ a: Double, _ b: Double) -> Double { abs(atan2(sin(a - b), cos(a - b))) }
        cells[bull].ring = "bull"
        for i in others {
            // 同じ向き(±6°)にもう1つマスがあれば、遠い方がダブル
            let mates = others.filter { $0 != i && dAng(ang[$0]!, ang[i]!) < 6 * .pi / 180 }
            if let j = mates.min(by: { dAng(ang[$0]!, ang[i]!) < dAng(ang[$1]!, ang[i]!) }) {
                cells[i].ring = dist[i]! > dist[j]! ? "double" : "treble"
            } else {
                cells[i].ring = "?"  // 相方が見切れている。あとで距離で判断
            }
        }
        let dd = median(others.filter { cells[$0].ring == "double" }.map { dist[$0]! }) ?? .infinity
        let tt = median(others.filter { cells[$0].ring == "treble" }.map { dist[$0]! }) ?? 0
        for i in others where cells[i].ring == "?" {
            cells[i].ring = abs(dist[i]! - dd) < abs(dist[i]! - tt) ? "double" : "treble"
        }
    }

    /// マスの通し番号 shift ずらしで、盤面座標(mm)との対応点を作る
    static func boardPoints(_ cells: [Cell], shift: Int) -> ([SIMD2<Double>], [SIMD2<Double>]) {
        var src: [SIMD2<Double>] = [], dst: [SIMD2<Double>] = []
        let sp = Board.spec
        for c in cells {
            if c.ring == "bull" {
                src.append(c.xy)
                dst.append([0, 0])
            } else if c.ring == "double" || c.ring == "treble" {
                let r = c.ring == "double" ? (sp.rDoubleIn + sp.rDoubleOut) / 2 : sp.rTripleMid
                let a = Double((c.seg + shift) % 20) * 18 * .pi / 180
                src.append(c.xy)
                dst.append([r * cos(a), r * sin(a)])
            }
        }
        return (src, dst)
    }

    // MARK: - 数学

    static func median(_ a: [Double]) -> Double? {
        guard !a.isEmpty else { return nil }
        let s = a.sorted()
        return s[s.count / 2]
    }

    /// 原点中心の楕円 A x² + B xy + C y² = 1 を最小二乗で当てて、(長軸, 短軸, 長軸の角度) を返す
    static func centeredEllipse(_ pts: [SIMD2<Double>]) -> (Double, Double, Double)? {
        guard pts.count >= 4 else { return nil }
        var M = simd_double3x3(0), v = SIMD3<Double>(0, 0, 0)
        for p in pts {
            let row = SIMD3<Double>(p.x * p.x, p.x * p.y, p.y * p.y)
            M += simd_double3x3(columns: (row * row.x, row * row.y, row * row.z))
            v += row
        }
        guard abs(M.determinant) > 1e-12 else { return nil }
        let abc = M.inverse * v
        let (A, B, C) = (abc.x, abc.y, abc.z)
        // 固有値分解で軸を出す
        let th = 0.5 * atan2(B, A - C)
        let l1 = (A + C) / 2 + ((A - C) / 2 * (A - C) / 2 + B * B / 4).squareRoot()
        let l2 = (A + C) / 2 - ((A - C) / 2 * (A - C) / 2 + B * B / 4).squareRoot()
        guard l1 > 0, l2 > 0 else { return nil }
        // th は l1(大きい固有値 = 短軸)の向き。rot で th を x に合わせるので、x 側が短軸
        return (1 / l1.squareRoot(), 1 / l2.squareRoot(), th)
    }

    /// RANSAC でホモグラフィ(外れ値のマスを捨てる)。inliers は src の番号
    static func ransacHomography(src: [SIMD2<Double>], dst: [SIMD2<Double>], thresholdPx: Double,
                                 iterations: Int = 300) -> (H: simd_double3x3, inliers: [Int])? {
        let n = src.count
        guard n >= 4 else { return nil }
        var rng = SystemRandomNumberGenerator()
        var best: [Int] = []
        for _ in 0..<iterations {
            var pick = Set<Int>()
            while pick.count < 4 { pick.insert(Int.random(in: 0..<n, using: &rng)) }
            let idx = Array(pick)
            guard let H = Homography.solve(src: idx.map { src[$0] }, dst: idx.map { dst[$0] }) else { continue }
            let inv = H.inverse
            let inl = (0..<n).filter { simd_length(Mat.apply(inv, dst[$0]) - src[$0]) < thresholdPx }
            if inl.count > best.count { best = inl }
            if best.count == n { break }
        }
        guard best.count >= 4,
              let H = Homography.solve(src: best.map { src[$0] }, dst: best.map { dst[$0] }) else { return nil }
        // 当て直した H で inlier を取り直す
        let inv = H.inverse
        let inl = (0..<n).filter { simd_length(Mat.apply(inv, dst[$0]) - src[$0]) < thresholdPx }
        return (H, inl.count >= 4 ? inl : best)
    }
}
