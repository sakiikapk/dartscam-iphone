import SwiftUI
import simd

/// 画像(処理画像の px)と画面(pt)の対応。画像は枠の中央に縦横比を保って収める
struct Fit {
    let scale: CGFloat
    let ox: CGFloat
    let oy: CGFloat

    init(imgW: Int, imgH: Int, in size: CGSize) {
        scale = min(size.width / CGFloat(imgW), size.height / CGFloat(imgH))
        ox = (size.width - CGFloat(imgW) * scale) / 2
        oy = (size.height - CGFloat(imgH) * scale) / 2
    }

    func toView(_ p: SIMD2<Double>) -> CGPoint { CGPoint(x: ox + CGFloat(p.x) * scale, y: oy + CGFloat(p.y) * scale) }
    func toImg(_ p: CGPoint) -> SIMD2<Double> { [Double((p.x - ox) / scale), Double((p.y - oy) / scale)] }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if model.mode == .calibrating, let f = model.frozen {
                    CalibrationView(frame: f)
                } else {
                    LiveView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            if model.mode != .calibrating {
                SidePanel().frame(width: 230)
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct LiveView: View {
    @EnvironmentObject var model: AppModel
    @State private var dragging: UUID?
    @State private var dragPos: CGPoint?

    var body: some View {
        GeometryReader { geo in
            if let img = model.preview {
                let fit = Fit(imgW: img.width, imgH: img.height, in: geo.size)
                ZStack(alignment: .topLeading) {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height)
                    Canvas { ctx, _ in
                        if let c = model.cal { BoardOverlay.draw(c, in: &ctx, fit: fit, alpha: 0.5) }
                        for (k, h) in model.hits.enumerated() {
                            guard var p = h.tipPx.map(fit.toView) else { continue }
                            if h.id == dragging, let d = dragPos { p = d }
                            let latest = k >= model.hits.count - 3
                            let r: CGFloat = latest ? 7 : 4
                            let col: Color = h.note == "tip_hidden" ? .orange : h.note == "manual" ? .cyan
                                : latest ? .yellow : .green
                            ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                                       with: .color(col), lineWidth: 2)
                        }
                    }
                    if let d = dragPos {
                        Loupe(image: img, center: fit.toImg(d)).padding(8)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 4)
                    .onChanged { v in
                        if dragging == nil {
                            // 押したところに一番近い点(40pt 以内)をつかむ
                            dragging = model.hits.compactMap { h -> (UUID, CGFloat)? in
                                guard let p = h.tipPx.map(fit.toView) else { return nil }
                                return (h.id, hypot(p.x - v.startLocation.x, p.y - v.startLocation.y))
                            }.filter { $0.1 < 40 }.min { $0.1 < $1.1 }?.0
                        }
                        if dragging != nil { dragPos = v.location }
                    }
                    .onEnded { v in
                        if let id = dragging { model.move(hitID: id, to: fit.toImg(v.location)) }
                        dragging = nil
                        dragPos = nil
                    })
            } else {
                Text("カメラ起動中…").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct SidePanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("BoardCam").font(.headline)
            Text(model.status).font(.footnote).fixedSize(horizontal: false, vertical: true)
            switch model.mode {
            case .live:
                Button("キャリブレーション") { model.beginCalibration() }
                    .buttonStyle(.bordered)
                Button("記録スタート") { model.startSession() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.cal == nil)
            case .recording:
                Button("記録おわり") { model.stopSession() }
                    .buttonStyle(.borderedProminent).tint(.red)
                Button("最後の1本を消す") { model.undoLast() }
                    .buttonStyle(.bordered)
                    .disabled(model.hits.isEmpty)
            case .calibrating:
                EmptyView()
            }
            Divider()
            Text("\(model.hits.count) 本").font(.title2.monospacedDigit())
            if let s = model.spread {
                Text(String(format: "σx %.0f mm / σy %.0f mm", s.sx, s.sy)).font(.footnote.monospacedDigit())
            }
            ForEach(Array(model.hits.suffix(3).reversed())) { h in
                if let mm = h.mm {
                    Text(String(format: "#%d %@  %.0f mm", h.no, Board.label(x: mm.x, y: mm.y), simd_length(mm)))
                        .font(.caption.monospacedDigit())
                } else {
                    Text("#\(h.no) \(h.note)").font(.caption)
                }
            }
            Spacer()
            if let dir = model.sessionDir, model.mode == .live, !model.hits.isEmpty {
                ShareLink(item: dir.appendingPathComponent("hits.csv")) {
                    Label("CSVを送る", systemImage: "square.and.arrow.up")
                }
            }
            Text("点はドラッグで直せる").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
    }
}

/// 指の下を拡大して見せる(十字が今の位置)
struct Loupe: View {
    let image: CGImage
    let center: SIMD2<Double>
    var radius = 24.0
    var size: CGFloat = 150

    var body: some View {
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)
        ZStack {
            if let crop = image.cropping(to: rect.integral) {
                Image(decorative: crop, scale: 1).resizable().interpolation(.none)
            } else {
                Color.black
            }
            Path { p in
                p.move(to: CGPoint(x: size / 2, y: 0)); p.addLine(to: CGPoint(x: size / 2, y: size))
                p.move(to: CGPoint(x: 0, y: size / 2)); p.addLine(to: CGPoint(x: size, y: size / 2))
            }
            .stroke(Color.yellow, lineWidth: 1)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white, lineWidth: 2))
    }
}

enum BoardOverlay {
    /// キャリブレーション結果の盤面(リングと区切り線)を重ねる
    static func draw(_ c: Calibration, in ctx: inout GraphicsContext, fit: Fit, alpha: Double) {
        let col = Color.cyan.opacity(alpha)
        for r in [Board.rBull, Board.rTripleIn, Board.rTripleOut, Board.rDoubleIn, Board.rDoubleOut] {
            var p = Path()
            for k in 0...96 {
                let a = Double(k) * 2 * .pi / 96
                let q = fit.toView(c.toPx([r * cos(a), r * sin(a)]))
                if k == 0 { p.move(to: q) } else { p.addLine(to: q) }
            }
            ctx.stroke(p, with: .color(col), lineWidth: 1)
        }
        for k in 0..<20 {
            let a = (9 + 18 * Double(k)) * .pi / 180
            var p = Path()
            p.move(to: fit.toView(c.toPx([Board.rBull * cos(a), Board.rBull * sin(a)])))
            p.addLine(to: fit.toView(c.toPx([Board.rDoubleOut * cos(a), Board.rDoubleOut * sin(a)])))
            ctx.stroke(p, with: .color(col), lineWidth: 1)
        }
        let top = fit.toView(c.toPx([0, Board.rDoubleOut * 1.1]))
        ctx.draw(Text("20").font(.caption.bold()).foregroundColor(.cyan), at: top)
    }
}
