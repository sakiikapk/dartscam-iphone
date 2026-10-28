import AudioToolbox
import Foundation
import SwiftUI
import UIKit
import simd

/// 画面の状態と、1セッション分の記録(CSV + 静止画)を持つ。
@MainActor
final class AppModel: ObservableObject {
    enum Mode { case live, calibrating, recording }

    @Published var preview: CGImage?
    @Published var mode: Mode = .live
    @Published var cal: Calibration?
    @Published var hits: [Hit] = []
    @Published var status = "盤全体が映るように置いて「自動キャリブレーション」"
    @Published var sessionDir: URL?
    /// キャリブレーション用に止めた1枚
    @Published var frozen: RGBImage?
    /// 表示の回転(時計回り 90°×rot)。処理と保存はいつもカメラ本来の向き
    @Published var rot = 0
    @Published var imgW = 960
    @Published var imgH = 540
    /// 盤の種類・狙い・音(設定画面)
    @Published var spec: BoardSpec = .soft()
    @Published var target: Target = .bull
    @Published var sound = true
    /// デジタルズーム(ピンチかスライダー)
    @Published var zoom = 1.0
    private var round = 1
    private var inRound = 0

    private let camera = Camera()
    private var hint20Px: SIMD2<Double>?
    private var lastFrame: RGBImage?
    private var launchAutoAt: Date?
    private var lastPreviewAt = Date.distantPast
    // カメラのキューから触るもの
    nonisolated(unsafe) private var detector: Detector?
    nonisolated(unsafe) private var sessionStart: Date?

    init() {
        let ud = UserDefaults.standard
        if let d = ud.data(forKey: "boardSpec"), let sp = try? JSONDecoder().decode(BoardSpec.self, from: d) {
            spec = sp
            Board.spec = sp
        }
        target = Target(rawValue: ud.string(forKey: "target") ?? "") ?? .bull
        sound = ud.object(forKey: "sound") as? Bool ?? true
        zoom = ud.object(forKey: "zoom") as? Double ?? 1
        camera.setZoom(zoom)
        camera.onFrame = { [weak self] img, wall in self?.onFrame(img, wall) }
        camera.start()
        if let data = UserDefaults.standard.data(forKey: "calibration"),
           let c = try? JSONDecoder().decode(Calibration.self, from: data) {
            cal = c
            status = "前回のキャリブレーションを読み込んだ。「自動キャリブレーション」で合わせ直せる"
        }
    }

    nonisolated private func onFrame(_ img: RGBImage, _ wall: Date) {
        var result: Detector.Result?
        if let det = detector, let s0 = sessionStart {
            result = det.process(img, t: wall.timeIntervalSince(s0))
        }
        let s0 = sessionStart
        Task { @MainActor in
            self.lastFrame = img
            // 起動して3秒たったら1回だけ自動キャリブレーション(画面に触らずに済むように)
            if self.launchAutoAt == nil { self.launchAutoAt = Date().addingTimeInterval(3) }
            if let t = self.launchAutoAt, Date() > t, self.mode == .live {
                self.launchAutoAt = .distantFuture
                self.autoCalibrate()
            }
            if Date().timeIntervalSince(self.lastPreviewAt) > 1.0 / 15 {
                self.imgW = img.w
                self.imgH = img.h
                self.preview = img.rotated(self.rot).cgImage()
                self.lastPreviewAt = Date()
            }
            if let r = result, let s0 { self.handle(r, start: s0) }
        }
    }

    /// 画面の向きから表示の回転を決める(カメラ本来の向き = 横・端子が右)
    func updateRotation() {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        switch scene?.interfaceOrientation {
        case .portrait: rot = 1
        case .landscapeLeft: rot = 2
        case .portraitUpsideDown: rot = 3
        default: rot = 0
        }
    }

    // MARK: - 設定

    /// 盤の種類を変える。キャリブレーションは同じタップ位置のまま新しい寸法で解き直す
    func setSpec(_ sp: BoardSpec) {
        spec = sp
        Board.spec = sp
        if let d = try? JSONEncoder().encode(sp) { UserDefaults.standard.set(d, forKey: "boardSpec") }
        if let c = cal?.resolved() {
            cal = c
            if let data = try? JSONEncoder().encode(c) { UserDefaults.standard.set(data, forKey: "calibration") }
        }
    }

    func setTarget(_ t: Target) {
        target = t
        UserDefaults.standard.set(t.rawValue, forKey: "target")
    }

    func setZoom(_ z: Double) {
        zoom = min(max(z, 1), 5)
        camera.setZoom(zoom)
        UserDefaults.standard.set(zoom, forKey: "zoom")
    }

    func setSound(_ on: Bool) {
        sound = on
        UserDefaults.standard.set(on, forKey: "sound")
    }

    /// 集計に使う本(座標が取れたもの)
    var shots: [Shot] {
        hits.compactMap { h in
            guard let mm = h.mm, h.note != "tip_hidden", h.note != "no_dart_found" else { return nil }
            let sc = Board.score(x: mm.x, y: mm.y)
            return Shot(no: h.no, mm: mm, round: h.round, label: sc.label, points: sc.points)
        }
    }

    var stats: SessionStats { SessionStats(shots: shots, target: target) }

    /// 今のラウンドの表示(例 "R5: T20 S1 BULL = 111")
    var roundText: String? {
        guard let last = hits.last else { return nil }
        let cur = hits.filter { $0.round == last.round }
        let parts = cur.map { h -> (String, Int) in
            guard let mm = h.mm, h.note != "no_dart_found" else { return ("?", 0) }
            return Board.score(x: mm.x, y: mm.y)
        }
        return "R\(last.round): " + parts.map { $0.0 }.joined(separator: " ") + " = \(parts.map { $0.1 }.reduce(0, +))"
    }

    // MARK: - キャリブレーション

    /// 盤の色で自動キャリブレーション。終わったら completion(成功したか)
    /// 「20 はここ」を待っている
    @Published var picking20 = false

    /// 画面の上が、処理画像(カメラ本来の横向き)でどっち向きか
    var upInImage: SIMD2<Double> {
        switch rot {
        case 1: return [-1, 0]
        case 2: return [0, 1]
        case 3: return [1, 0]
        default: return [0, -1]
        }
    }

    func autoCalibrate(quiet: Bool = false, hint20: SIMD2<Double>? = nil, completion: ((Bool) -> Void)? = nil) {
        guard let f = lastFrame else { completion?(false); return }
        if !quiet { status = "盤を探してる…" }
        let up = upInImage
        // 一度「20 はここ」と教えてもらったら、以降もその向きを使う
        if let hint20 { hint20Px = hint20 }
        let hint = hint20Px
        Task.detached(priority: .userInitiated) {
            // あとで Mac で調べられるように、最後に試した1枚を残す(Documents/debug/autocal_last.jpg)
            let dbg = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("debug", isDirectory: true)
            try? FileManager.default.createDirectory(at: dbg, withIntermediateDirectories: true)
            try? f.jpeg(quality: 0.95)?.write(to: dbg.appendingPathComponent("autocal_last.jpg"))
            let r = AutoCalib.calibrate(f, up: up, hint20Px: hint)
            await MainActor.run {
                if var r, r.rmsPx < 3 {
                    r.cal.zoom = self.zoom
                    self.cal = r.cal
                    if let data = try? JSONEncoder().encode(r.cal) { UserDefaults.standard.set(data, forKey: "calibration") }
                    if !quiet {
                        self.status = String(format: "自動キャリブレーションOK(マス%d個、誤差 %.1fpx、%.1f px/mm)%@", r.nCells, r.rmsPx,
                                             r.cal.pxPerMM, r.upMarginDeg < 15 ? " ※20の向きが際どい、水色の20の位置を確認" : "")
                    }
                    completion?(true)
                } else {
                    if !quiet {
                        self.status = "盤が見つからへん。盤全体が明るく映ってるか確認して、無理なら手動(5点タップ)で"
                    }
                    completion?(false)
                }
            }
        }
    }

    func beginCalibration() {
        guard let f = lastFrame else { return }
        camera.lockExposure(false)
        frozen = f
        mode = .calibrating
    }

    func finishCalibration(taps: [SIMD2<Double>]) {
        guard let f = frozen, var c = Calibration(tapsPx: taps, imgW: f.w, imgH: f.h) else {
            status = "キャリブレーションに失敗。点を打ち直してね"
            return
        }
        c.zoom = zoom
        cal = c
        if let data = try? JSONEncoder().encode(c) { UserDefaults.standard.set(data, forKey: "calibration") }
        frozen = nil
        mode = .live
        status = String(format: "キャリブレーションOK(%.1f px/mm、5点のずれ最大 %.1f mm)", c.pxPerMM, c.fitErrorMM)
    }

    func cancelCalibration() {
        frozen = nil
        mode = .live
    }

    // MARK: - 記録

    /// 記録スタート。置き直してずれてても困らんように、まず自動で合わせ直してから始める
    func startSession() {
        guard cal != nil else { return }
        status = "盤を合わせてる…"
        autoCalibrate(quiet: true) { _ in self.beginRecording() }
    }

    private func beginRecording() {
        guard let c = cal, let f = lastFrame else { return }
        camera.lockExposure(true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HHmmss"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("sessions/\(fmt.string(from: Date()))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? f.jpeg()?.write(to: dir.appendingPathComponent("calib.jpg"))
        try? JSONEncoder().encode(c).write(to: dir.appendingPathComponent("calibration.json"))
        sessionDir = dir
        hits = []
        round = 1
        inRound = 0
        sessionStart = Date()
        detector = Detector(cal: c)
        mode = .recording
        status = "記録中。投げてOK(ダーツを抜くと自動で区切る)"
        writeCSV()
    }

    func stopSession() {
        detector = nil
        sessionStart = nil
        camera.lockExposure(false)
        mode = .live
        status = "\(hits.count)本記録した。CSVは「ファイル」アプリの BoardCam/sessions に入ってる"
        writeCSV()
    }

    func undoLast() {
        guard !hits.isEmpty else { return }
        hits.removeLast()
        if let last = hits.last {
            round = last.round
            inRound = hits.filter { $0.round == round }.count
        } else {
            round = 1
            inRound = 0
        }
        writeCSV()
    }

    /// 点を手で動かした(処理画像の座標)
    func move(hitID: UUID, to px: SIMD2<Double>) {
        guard let c = cal, let i = hits.firstIndex(where: { $0.id == hitID }) else { return }
        hits[i].tipPx = px
        hits[i].mm = c.toMM(px)
        hits[i].note = "manual"
        writeCSV()
    }

    /// ダーツを抜いて盤がきれいなとき、自動キャリブをやり直してカメラのずれに追従する(board.py と同じ)
    private func refollow() {
        guard let f = lastFrame, let old = cal, mode == .recording else { return }
        // 記録中の追従は、画面の向きより「さっきまでの 20 の向き」を手がかりにする方が確実
        let up = upInImage, hint = hint20Px ?? old.toPx([0, 150])
        Task.detached(priority: .utility) {
            let r = AutoCalib.calibrate(f, up: up, hint20Px: hint)
            await MainActor.run {
                guard self.mode == .recording, var r, r.rmsPx < 3 else { return }
                r.cal.zoom = self.zoom
                let moved = simd_length(r.cal.toPx([0, 0]) - old.toPx([0, 0]))
                guard moved > 3 else { return }
                self.cal = r.cal
                self.detector = Detector(cal: r.cal)
                self.status = String(format: "カメラが %.0fpx ずれてたので合わせ直した", moved)
                if let dir = self.sessionDir {
                    try? JSONEncoder().encode(r.cal).write(to: dir.appendingPathComponent("calibration.json"))
                }
            }
        }
    }

    private func handle(_ r: Detector.Result, start: Date) {
        switch r {
        case .reset:
            if inRound > 0 {
                round += 1
                inRound = 0
            }
            status = "ダーツを抜いた(\(hits.count)本目まで記録)"
            refollow()
        case let .hit(t, tip, note, before, after):
            guard let c = cal else { return }
            let no = hits.count + 1
            if inRound >= 3 {
                round += 1
                inRound = 0
            }
            inRound += 1
            var mm: SIMD2<Double>? = nil
            if let tip { mm = c.toMM(tip) }
            let h = Hit(no: no, t: t, wall: start.addingTimeInterval(t), tipPx: tip, mm: mm, note: note,
                        before: nil, after: nil, round: round)  // 画像はファイルに書くだけ(メモリに溜めない)
            hits.append(h)
            if sound {
                AudioServicesPlaySystemSound(1057)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            if let dir = sessionDir {
                try? before.jpeg()?.write(to: dir.appendingPathComponent(String(format: "hit%03d_a.jpg", no)))
                try? after.jpeg()?.write(to: dir.appendingPathComponent(String(format: "hit%03d_b.jpg", no)))
            }
            if let mm {
                let sc = Board.score(x: mm.x, y: mm.y)
                status = String(format: "%d本目: %@ %d点 (%.0f mm)%@", no, sc.label, sc.points,
                                simd_length(mm - target.point), note.isEmpty ? "" : " ※チップ見えず、ずれてたら点を動かして")
            } else {
                status = "\(no)本目: ダーツが見つからへん(\(note))"
            }
            writeCSV()
        }
    }

    // MARK: - CSV

    /// src/board.py の hits.csv と同じ列 + 追加の列。座標は元の 1920x1080 の px に直して書く
    func writeCSV() {
        guard let dir = sessionDir else { return }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        iso.timeZone = .current
        var lines = ["hit_no,frame,time_s,tip_x_px,tip_y_px,x_mm,y_mm,note,wall_time,r_mm,theta_deg,segment,img_before,img_after,round_no,score,board"]
        for h in hits {
            let tip = h.tipPx.map { [String(format: "%.1f", $0.x * 2), String(format: "%.1f", $0.y * 2)] } ?? ["", ""]
            // チップが隠れていた点は board.py と同じく座標を空にする(手で直したものは入れる)
            let mm = (h.note == "tip_hidden" || h.note == "no_dart_found") ? nil : h.mm
            let xy = mm.map { [String(format: "%.1f", $0.x), String(format: "%.1f", $0.y)] } ?? ["", ""]
            let polar = mm.map { [String(format: "%.1f", simd_length($0)),
                                  String(format: "%.1f", atan2($0.y, $0.x) * 180 / .pi),
                                  Board.label(x: $0.x, y: $0.y)] } ?? ["", "", ""]
            let row = [String(h.no), String(Int((h.t * 30).rounded())), String(format: "%.3f", h.t)] + tip + xy
                + [h.note, iso.string(from: h.wall)] + polar
                + [String(format: "hit%03d_a.jpg", h.no), String(format: "hit%03d_b.jpg", h.no)]
                + [String(h.round), mm.map { String(Board.score(x: $0.x, y: $0.y).points) } ?? "",
                   "\"\(spec.name)\""]
            lines.append(row.joined(separator: ","))
        }
        try? (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("hits.csv"),
                                                          atomically: true, encoding: .utf8)
    }
}
