import SwiftUI
import simd

/// 止めた1枚の上で、ブルとダブル外周の4点を順にタップしてもらう
struct CalibrationView: View {
    @EnvironmentObject var model: AppModel
    let frame: RGBImage
    @State private var taps: [SIMD2<Double>?] = Array(repeating: nil, count: Board.calibPoints.count)
    @State private var k = 0
    @State private var touching: CGPoint?
    @State private var cg: CGImage?

    private var done: Bool { taps.allSatisfy { $0 != nil } }
    private var preview: Calibration? {
        done ? Calibration(tapsPx: taps.compactMap { $0 }, imgW: frame.w, imgH: frame.h) : nil
    }

    var body: some View {
        Split {
            GeometryReader { geo in
                if let img = cg {
                    let fit = Fit(imgW: frame.w, imgH: frame.h, rot: model.rot, in: geo.size)
                    ZStack(alignment: .topLeading) {
                        Image(decorative: img, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: geo.size.width, height: geo.size.height)
                        Canvas { ctx, _ in
                            if let c = preview { BoardOverlay.draw(c, in: &ctx, fit: fit, alpha: 0.9) }
                            for (i, t) in taps.enumerated() {
                                guard let t else { continue }
                                let p = fit.toView(t)
                                let col: Color = i == k ? .yellow : .green
                                var plus = Path()
                                plus.move(to: CGPoint(x: p.x - 10, y: p.y)); plus.addLine(to: CGPoint(x: p.x + 10, y: p.y))
                                plus.move(to: CGPoint(x: p.x, y: p.y - 10)); plus.addLine(to: CGPoint(x: p.x, y: p.y + 10))
                                ctx.stroke(plus, with: .color(col), lineWidth: 2)
                            }
                        }
                        if let t = touching {
                            // 指の反対側に拡大鏡を出す
                            Loupe(image: img, center: fit.dispPoint(t), radius: 20, size: 170)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: t.x < geo.size.width / 2 ? .trailing : .leading)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            touching = v.location
                            taps[k] = fit.toImg(v.location)
                        }
                        .onEnded { _ in touching = nil })
                }
            }
        } panel: {
            VStack(alignment: .leading, spacing: 12) {
                Text("キャリブレーション \(k + 1)/\(taps.count)").font(.headline)
                Text("「\(Board.calibPoints[k].name)」を押して、拡大鏡の十字が合うまで指をずらす")
                    .font(.footnote).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("前へ") { k = max(0, k - 1) }.disabled(k == 0)
                    Button("次へ") { k = min(taps.count - 1, k + 1) }.disabled(k == taps.count - 1 || taps[k] == nil)
                }
                .buttonStyle(.bordered)
                if let c = preview {
                    Text("水色の線が盤と重なってたらOK").font(.footnote)
                    Text(String(format: "%.1f px/mm", c.pxPerMM)).font(.caption.monospacedDigit())
                    Button("これでOK") { model.finishCalibration(taps: taps.compactMap { $0 }) }
                        .buttonStyle(.borderedProminent)
                }
                Button("やめる", role: .cancel) { model.cancelCalibration() }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: model.rot) { cg = frame.rotated(model.rot).cgImage() }
        .onAppear {
            cg = frame.rotated(model.rot).cgImage()
            // 前回の点があれば初期位置にする(カメラを少し動かしただけなら微調整で済む)
            if let c = model.cal, c.imgW == frame.w, c.tapsPx.count == taps.count {
                taps = c.tapsPx.map { SIMD2($0[0], $0[1]) }
            }
        }
    }
}
