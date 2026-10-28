import Foundation
import SwiftUI
import simd

/// 画面の状態と、1セッション分の記録(CSV + 静止画)を持つ。
@MainActor
final class AppModel: ObservableObject {
    enum Mode { case live, calibrating, recording }

    @Published var preview: CGImage?
    @Published var mode: Mode = .live
    @Published var cal: Calibration?
    @Published var hits: [Hit] = []
    @Published var status = "盤面全体が写るように置いて、キャリブレーションしてね"
    @Published var sessionDir: URL?
    /// キャリブレーション用に止めた1枚
    @Published var frozen: RGBImage?

    private let camera = Camera()
    private var lastFrame: RGBImage?
    private var lastPreviewAt = Date.distantPast
    // カメラのキューから触るもの
    nonisolated(unsafe) private var detector: Detector?
    nonisolated(unsafe) private var sessionStart: Date?

    init() {
        camera.onFrame = { [weak self] img, wall in self?.onFrame(img, wall) }
        camera.start()
        if let data = UserDefaults.standard.data(forKey: "calibration"),
           let c = try? JSONDecoder().decode(Calibration.self, from: data) {
            cal = c
            status = "前回のキャリブレーションを読み込んだ。カメラが動いてたらやり直してね"
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
            if Date().timeIntervalSince(self.lastPreviewAt) > 1.0 / 15 {
                self.preview = img.cgImage()
                self.lastPreviewAt = Date()
            }
            if let r = result, let s0 { self.handle(r, start: s0) }
        }
    }

    // MARK: - キャリブレーション

    func beginCalibration() {
        guard let f = lastFrame else { return }
        camera.lockExposure(false)
        frozen = f
        mode = .calibrating
    }

    func finishCalibration(taps: [SIMD2<Double>]) {
        guard let f = frozen, let c = Calibration(tapsPx: taps, imgW: f.w, imgH: f.h) else {
            status = "キャリブレーションに失敗。点を打ち直してね"
            return
        }
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

    func startSession() {
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

    private func handle(_ r: Detector.Result, start: Date) {
        switch r {
        case .reset:
            status = "ダーツを抜いた(\(hits.count)本目まで記録)"
        case let .hit(t, tip, note, before, after):
            guard let c = cal else { return }
            let no = hits.count + 1
            var mm: SIMD2<Double>? = nil
            if let tip { mm = c.toMM(tip) }
            let h = Hit(no: no, t: t, wall: start.addingTimeInterval(t), tipPx: tip, mm: mm, note: note,
                        before: nil, after: nil)  // 画像はファイルに書くだけ(メモリに溜めない)
            hits.append(h)
            if let dir = sessionDir {
                try? before.jpeg()?.write(to: dir.appendingPathComponent(String(format: "hit%03d_a.jpg", no)))
                try? after.jpeg()?.write(to: dir.appendingPathComponent(String(format: "hit%03d_b.jpg", no)))
            }
            if let mm {
                status = String(format: "%d本目: %@ (%.0f mm)%@", no, Board.label(x: mm.x, y: mm.y),
                                simd_length(mm), note.isEmpty ? "" : " ※チップ見えず、ずれてたら点を動かして")
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
        var lines = ["hit_no,frame,time_s,tip_x_px,tip_y_px,x_mm,y_mm,note,wall_time,r_mm,theta_deg,segment,img_before,img_after"]
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
            lines.append(row.joined(separator: ","))
        }
        try? (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("hits.csv"),
                                                          atomically: true, encoding: .utf8)
    }

    /// 着弾のばらつき(x, y の標準偏差 mm)
    var spread: (sx: Double, sy: Double)? {
        let pts = hits.compactMap { h -> SIMD2<Double>? in h.note == "tip_hidden" ? nil : h.mm }
        guard pts.count >= 3 else { return nil }
        let m = pts.reduce(SIMD2<Double>(0, 0), +) / Double(pts.count)
        let v = pts.map { ($0 - m) * ($0 - m) }.reduce(SIMD2<Double>(0, 0), +) / Double(pts.count - 1)
        return (v.x.squareRoot(), v.y.squareRoot())
    }
}
