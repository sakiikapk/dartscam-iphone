import AVKit
import SwiftUI
import simd

/// 処理画像(カメラ本来の向き、px)と画面(pt)の対応。
/// 表示は画面の向きに合わせて時計回りに 90°×rot 回し、枠の中央に縦横比を保って収める
struct Fit {
    let scale: CGFloat
    let ox: CGFloat
    let oy: CGFloat
    let rot: Int
    let W: Double
    let H: Double

    init(imgW: Int, imgH: Int, rot: Int, in size: CGSize) {
        self.rot = ((rot % 4) + 4) % 4
        W = Double(imgW)
        H = Double(imgH)
        let dw = CGFloat(self.rot % 2 == 1 ? imgH : imgW), dh = CGFloat(self.rot % 2 == 1 ? imgW : imgH)
        scale = min(size.width / dw, size.height / dh)
        ox = (size.width - dw * scale) / 2
        oy = (size.height - dh * scale) / 2
    }

    /// 処理画像の点 → 回した表示画像の点
    func toDisp(_ p: SIMD2<Double>) -> SIMD2<Double> {
        switch rot {
        case 1: return [H - p.y, p.x]
        case 2: return [W - p.x, H - p.y]
        case 3: return [p.y, W - p.x]
        default: return p
        }
    }

    func fromDisp(_ d: SIMD2<Double>) -> SIMD2<Double> {
        switch rot {
        case 1: return [d.y, H - d.x]
        case 2: return [W - d.x, H - d.y]
        case 3: return [W - d.y, d.x]
        default: return d
        }
    }

    /// 画面の点 → 表示画像の点(拡大鏡用)
    func dispPoint(_ p: CGPoint) -> SIMD2<Double> { [Double((p.x - ox) / scale), Double((p.y - oy) / scale)] }

    func toView(_ p: SIMD2<Double>) -> CGPoint {
        let d = toDisp(p)
        return CGPoint(x: ox + CGFloat(d.x) * scale, y: oy + CGFloat(d.y) * scale)
    }

    func toImg(_ p: CGPoint) -> SIMD2<Double> { fromDisp(dispPoint(p)) }
}

/// 縦なら画像の下にパネル、横なら右にパネル
struct Split<Main: View, Panel: View>: View {
    @EnvironmentObject var model: AppModel
    @ViewBuilder let main: () -> Main
    @ViewBuilder let panel: () -> Panel

    var body: some View {
        GeometryReader { geo in
            let portrait = geo.size.height > geo.size.width
            Group {
                if portrait {
                    // 縦持ち: 画面の下は台座に隠れがちなので、操作は上に半透明で重ねる
                    ZStack(alignment: .top) {
                        main()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.black)
                        ScrollView { panel() }
                            .frame(maxHeight: geo.size.height * 0.45)
                            .background(.ultraThinMaterial.opacity(0.9))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .padding(.horizontal, 6)
                            .padding(.top, 4)
                    }
                } else {
                    HStack(spacing: 0) {
                        main()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.black)
                        ScrollView { panel() }
                            .frame(width: 250, height: geo.size.height)
                    }
                }
            }
            .onAppear { model.updateRotation() }
            .onChange(of: geo.size) { model.updateRotation() }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if model.mode == .calibrating, let f = model.frozen {
                CalibrationView(frame: f)
            } else {
                Split { LiveView() } panel: { SidePanel() }
            }
        }
        .preferredColorScheme(.dark)
        .modifier(VolumeButtons())
    }
}

/// 音量ボタン(とカメラコントロール)で 記録スタート/記録おわり を切り替える。画面に触らずに済むように
struct VolumeButtons: ViewModifier {
    @EnvironmentObject var model: AppModel

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onCameraCaptureEvent { event in
                guard event.phase == .ended else { return }
                switch model.mode {
                case .live where model.cal != nil: model.startSession()
                case .recording: model.stopSession()
                default: break
                }
            }
        } else {
            content
        }
    }
}

struct LiveView: View {
    @EnvironmentObject var model: AppModel
    @State private var dragging: UUID?
    @State private var dragPos: CGPoint?

    var body: some View {
        GeometryReader { geo in
            if let img = model.preview {
                let fit = Fit(imgW: model.imgW, imgH: model.imgH, rot: model.rot, in: geo.size)
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
                        Loupe(image: img, center: fit.dispPoint(d)).padding(8)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { loc in
                    // 「20 はここ」待ちのときは、タップした所を 20 の向きとして合わせ直す
                    if model.picking20 {
                        model.picking20 = false
                        model.autoCalibrate(hint20: fit.toImg(loc))
                    }
                }
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
    enum Sheet: Int, Identifiable {
        case summary, history, settings
        var id: Int { rawValue }
    }
    @State private var sheet: Sheet?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("BoardCam").font(.headline)
                Spacer()
                Button { sheet = .history } label: { Image(systemName: "clock.arrow.circlepath") }
                Button { sheet = .settings } label: { Image(systemName: "gearshape") }
                    .disabled(model.mode == .recording)
            }
            Text(model.status).font(.footnote).fixedSize(horizontal: false, vertical: true)
            Text("\(model.spec.name)・狙い \(model.target.rawValue)").font(.caption2).foregroundStyle(.secondary)
            switch model.mode {
            case .live:
                HStack {
                    Button("自動キャリブ") { model.autoCalibrate() }
                        .buttonStyle(.bordered)
                    Button("記録スタート") { model.startSession() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.cal == nil)
                }
                .controlSize(.large)
                HStack {
                    Button(model.picking20 ? "画面の 20 を押して…" : "20がずれてる") { model.picking20.toggle() }
                        .buttonStyle(.bordered)
                        .tint(model.picking20 ? .yellow : nil)
                        .disabled(model.cal == nil)
                    Button("手動5点") { model.beginCalibration() }
                        .buttonStyle(.bordered)
                }
            case .recording:
                HStack {
                    Button("記録おわり") { model.stopSession() }
                        .buttonStyle(.borderedProminent).tint(.red)
                    Button("1本消す") { model.undoLast() }
                        .buttonStyle(.bordered)
                        .disabled(model.hits.isEmpty)
                }
                .controlSize(.large)
            case .calibrating:
                EmptyView()
            }
            Divider()
            if let r = model.roundText {
                Text(r).font(.title3.monospacedDigit().bold())
            }
            let st = model.stats
            Text("\(model.hits.count) 本").font(.headline.monospacedDigit())
            if st.n >= 3 {
                Text(String(format: "σ %.0f mm(x %.0f / y %.0f)", st.sigma, st.sx, st.sy))
                Text(String(format: "1R平均 %.1f 点  %@率 %.0f%%", st.ppr, st.target.rawValue, st.hitRate * 100))
                Text("平均のずれ: \(st.offsetText)")
            }
            if !model.hits.isEmpty {
                Button {
                    sheet = .summary
                } label: {
                    Label("まとめ(盤面の散らばり)", systemImage: "scope")
                }
            }
            if let dir = model.sessionDir, model.mode == .live, !model.hits.isEmpty {
                ShareLink(item: dir.appendingPathComponent("hits.csv")) {
                    Label("CSVを送る", systemImage: "square.and.arrow.up")
                }
            }
            Text("点はドラッグで直せる").font(.caption2).foregroundStyle(.secondary)
        }
        .font(.footnote.monospacedDigit())
        .padding(12)
        .sheet(item: $sheet) { s in
            switch s {
            case .summary: SummaryView(title: "今回のまとめ", stats: model.stats)
            case .history: HistoryView().environmentObject(model)
            case .settings: SettingsView().environmentObject(model)
            }
        }
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
        for r in [Board.rBull, Board.rTripleIn, Board.rTripleOut, Board.rDoubleIn, Board.rDoubleOut]
            + (Board.spec.splitBull ? [Board.spec.rBullInner] : []) {
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
