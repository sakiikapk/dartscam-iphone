import SwiftUI
import simd

/// 盤を真正面から見た図に、着弾・平均・ばらつきの楕円を重ねる
struct GroupingChart: View {
    let stats: SessionStats
    var highlightLast = 3

    var body: some View {
        Canvas { ctx, size in
            let side = min(size.width, size.height)
            let R = Board.rDoubleOut * 1.12
            let k = side / 2 / R
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            func pt(_ p: SIMD2<Double>) -> CGPoint { CGPoint(x: c.x + p.x * k, y: c.y - p.y * k) }
            func circle(_ r: Double) -> Path {
                Path(ellipseIn: CGRect(x: c.x - r * k, y: c.y - r * k, width: 2 * r * k, height: 2 * r * k))
            }
            func sector(_ r0: Double, _ r1: Double, _ a0: Double, _ a1: Double) -> Path {
                // 弧は点で刻んでつなぐ(向きの取り違えがないように)
                let n = 8
                let outer = (0...n).map { i in a0 + (a1 - a0) * Double(i) / Double(n) }
                var p = Path()
                p.move(to: pt([r1 * cos(outer[0]), r1 * sin(outer[0])]))
                for a in outer.dropFirst() { p.addLine(to: pt([r1 * cos(a), r1 * sin(a)])) }
                for a in outer.reversed() { p.addLine(to: pt([r0 * cos(a), r0 * sin(a)])) }
                p.closeSubpath()
                return p
            }
            let sp = Board.spec
            ctx.fill(circle(R), with: .color(Color(white: 0.08)))
            let hard = sp.name.hasPrefix("ハード")
            let ringA: Color = .red.opacity(0.75)
            let ringB: Color = hard ? .green.opacity(0.7) : .blue.opacity(0.75)
            for i in 0..<20 {
                let mid = (90 - 18 * Double(i)) * .pi / 180
                let a0 = mid + 9 * .pi / 180, a1 = mid - 9 * .pi / 180
                let even = i % 2 == 0
                let single: Color = even ? Color(white: 0.18) : Color(white: 0.55)
                ctx.fill(sector(sp.rBullOuter, sp.rDoubleOut, a0, a1), with: .color(single))
                ctx.fill(sector(sp.rTripleIn, sp.rTripleOut, a0, a1), with: .color(even ? ringA : ringB))
                ctx.fill(sector(sp.rDoubleIn, sp.rDoubleOut, a0, a1), with: .color(even ? ringA : ringB))
                let lp = pt([R * 0.94 * cos(mid), R * 0.94 * sin(mid)])
                ctx.draw(Text("\(Board.segments[i])").font(.system(size: max(8, side / 34))).foregroundColor(.white), at: lp)
            }
            ctx.fill(circle(sp.rBullOuter), with: .color(sp.splitBull ? ringB : ringA))
            if sp.splitBull { ctx.fill(circle(sp.rBullInner), with: .color(ringA)) }

            // 狙い
            let tg = pt(stats.target.point)
            var cross = Path()
            cross.move(to: CGPoint(x: tg.x - 8, y: tg.y)); cross.addLine(to: CGPoint(x: tg.x + 8, y: tg.y))
            cross.move(to: CGPoint(x: tg.x, y: tg.y - 8)); cross.addLine(to: CGPoint(x: tg.x, y: tg.y + 8))
            ctx.stroke(cross, with: .color(.white), lineWidth: 1.5)

            // 着弾
            for (i, s) in stats.shots.enumerated() {
                let p = pt(s.mm)
                let recent = i >= stats.shots.count - highlightLast
                let r: CGFloat = recent ? 4.5 : 3
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                         with: .color(recent ? .yellow : .white.opacity(0.85)))
            }

            // 平均とばらつき(1σ 実線、2σ 点線)
            if stats.n >= 3 {
                for (kk, dash) in [(1.0, [CGFloat]()), (2.0, [CGFloat(5), 4])] {
                    var e = Path()
                    for (j, q) in stats.ellipse(k: kk).enumerated() {
                        if j == 0 { e.move(to: pt(q)) } else { e.addLine(to: pt(q)) }
                    }
                    ctx.stroke(e, with: .color(.orange), style: StrokeStyle(lineWidth: 2, dash: dash))
                }
                let m = pt(stats.mean)
                var plus = Path()
                plus.move(to: CGPoint(x: m.x - 9, y: m.y)); plus.addLine(to: CGPoint(x: m.x + 9, y: m.y))
                plus.move(to: CGPoint(x: m.x, y: m.y - 9)); plus.addLine(to: CGPoint(x: m.x, y: m.y + 9))
                ctx.stroke(plus, with: .color(.orange), lineWidth: 3)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// 1セッションのまとめ(盤面図 + 数字 + ラウンドごとの点数)
struct SummaryView: View {
    let title: String
    let stats: SessionStats
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    GroupingChart(stats: stats)
                        .frame(maxWidth: 480)
                        .frame(maxWidth: .infinity)
                    Text("黄色=直近3本、オレンジの+=平均、実線=1σ(4割が入る)、点線=2σ(9割弱)、白い十字=狙い")
                        .font(.caption2).foregroundStyle(.secondary)
                    if stats.n == 0 {
                        Text("まだ座標の取れた矢がない").foregroundStyle(.secondary)
                    } else {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                            row("本数", "\(stats.n) 本")
                            row("ばらつき σx / σy", String(format: "%.0f / %.0f mm", stats.sx, stats.sy))
                            row("ばらつき(円にならす)", String(format: "%.0f mm", stats.sigma))
                            row("狙い(\(stats.target.rawValue))からの平均のずれ", stats.offsetText)
                            row("半分の矢が入る円", String(format: "半径 %.0f mm", stats.medianDistance))
                            row("\(stats.target.rawValue) に入った率", String(format: "%.0f %%", stats.hitRate * 100))
                            row("1本平均 / 1ラウンド平均", String(format: "%.1f / %.1f 点", stats.pointsPerDart, stats.ppr))
                            if stats.target == .bull {
                                row("レーティング目安", String(format: "Rt %.1f(01スタッツ換算、ざっくり)", stats.rating))
                            }
                        }
                        .font(.callout.monospacedDigit())
                        Divider()
                        Text("ラウンドごと").font(.headline)
                        ForEach(stats.roundTotals, id: \.round) { r in
                            HStack {
                                Text("R\(r.round)").frame(width: 44, alignment: .leading)
                                Text(r.labels.joined(separator: "  "))
                                Spacer()
                                Text("\(r.total)").bold()
                            }
                            .font(.callout.monospacedDigit())
                        }
                    }
                }
                .padding()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
        }
    }

    @ViewBuilder private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v)
        }
    }
}

/// 過去のセッション一覧
struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [SavedSession] = []

    var body: some View {
        NavigationStack {
            List(sessions) { s in
                let st = SessionStats(shots: s.shots, target: model.target)
                NavigationLink {
                    SummaryView(title: s.name, stats: st)
                } label: {
                    VStack(alignment: .leading) {
                        Text(s.name).font(.headline)
                        Text(st.n >= 3
                             ? String(format: "%d本  σ %.0f mm  1R平均 %.1f", st.n, st.sigma, st.ppr)
                             : "\(s.count)本")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            .overlay { if sessions.isEmpty { Text("まだ記録がない").foregroundStyle(.secondary) } }
            .navigationTitle("履歴")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
        }
        .onAppear { sessions = SavedSession.loadAll() }
    }
}

/// 盤の種類・狙い・音
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var kind = 0  // 0 ソフト15.5 / 1 ハード / 2 カスタム
    @State private var diameter = "393.7"
    @State private var split = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("盤", selection: $kind) {
                        Text("ソフト 15.5インチ").tag(0)
                        Text("ハード(スティール)").tag(1)
                        Text("カスタム(ソフトの比率)").tag(2)
                    }
                    if kind == 2 {
                        HStack {
                            Text("ダブルの外径")
                            TextField("mm", text: $diameter).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            Text("mm")
                        }
                    }
                    if kind != 1 {
                        Toggle("セパレートブル(外 25 / 内 50)", isOn: $split)
                    }
                } header: {
                    Text("盤の種類")
                } footer: {
                    Text("変えるとキャリブレーションは同じタップ位置のまま新しい寸法で解き直す。ハードはダブル外径 340mm、ブルは 25/50。")
                }
                Section("狙い") {
                    Picker("狙い", selection: Binding(get: { model.target }, set: { model.setTarget($0) })) {
                        ForEach(Target.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Toggle("刺さったら音とバイブ", isOn: Binding(get: { model.sound }, set: { model.setSound($0) }))
                    Picker("縦持ちの操作パネル", selection: Binding(get: { model.panelTop }, set: { model.setPanelTop($0) })) {
                        Text("上").tag(true)
                        Text("下").tag(false)
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") {
                        apply()
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            let sp = model.spec
            kind = sp.name.hasPrefix("ハード") ? 1 : sp.name.hasPrefix("カスタム") ? 2 : 0
            diameter = String(format: "%.1f", sp.rDoubleOut * 2)
            split = sp.splitBull
        }
    }

    private func apply() {
        switch kind {
        case 1:
            model.setSpec(.hard)
        case 2:
            let d = Double(diameter.replacingOccurrences(of: ",", with: ".")) ?? 393.7
            model.setSpec(.soft(diameter: min(max(d, 200), 600), name: String(format: "カスタム ダブル外径 %.1fmm", d),
                                splitBull: split))
        default:
            model.setSpec(.soft(splitBull: split))
        }
    }
}
