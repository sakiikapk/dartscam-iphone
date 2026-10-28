import CoreGraphics
import CoreVideo
import UIKit

/// 処理用の RGB 画像(1画素3バイト、行詰め)。カメラの 1920x1080 を半分に縮めて持つ。
struct RGBImage {
    let w: Int
    let h: Int
    var px: [UInt8]

    /// BGRA のピクセルバッファを 2x2 平均で半分に縮める
    init(halving buf: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let sw = CVPixelBufferGetWidth(buf), sh = CVPixelBufferGetHeight(buf)
        let stride = CVPixelBufferGetBytesPerRow(buf)
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let w = sw / 2, h = sh / 2
        self.w = w
        self.h = h
        var out = [UInt8](repeating: 0, count: w * h * 3)
        out.withUnsafeMutableBufferPointer { o in
            for y in 0..<h {
                let r0 = base + (2 * y) * stride, r1 = r0 + stride
                var oi = y * w * 3
                for x in 0..<w {
                    let a = r0 + 8 * x, b = r1 + 8 * x
                    // BGRA → RGB
                    o[oi] = UInt8((Int(a[2]) + Int(a[6]) + Int(b[2]) + Int(b[6])) >> 2)
                    o[oi + 1] = UInt8((Int(a[1]) + Int(a[5]) + Int(b[1]) + Int(b[5])) >> 2)
                    o[oi + 2] = UInt8((Int(a[0]) + Int(a[4]) + Int(b[0]) + Int(b[4])) >> 2)
                    oi += 3
                }
            }
        }
        px = out
    }

    private init(w: Int, h: Int, px: [UInt8]) {
        self.w = w
        self.h = h
        self.px = px
    }

    /// 表示用に時計回りに 90°×k 回した画像(処理はいつもカメラ本来の向きのまま)
    func rotated(_ k: Int) -> RGBImage {
        let k = ((k % 4) + 4) % 4
        if k == 0 { return self }
        let (W, H) = (w, h)
        let dw = k % 2 == 1 ? H : W, dh = k % 2 == 1 ? W : H
        var out = [UInt8](repeating: 0, count: dw * dh * 3)
        px.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { o in
                for v in 0..<dh {
                    for u in 0..<dw {
                        let x: Int, y: Int
                        switch k {
                        case 1: x = v; y = H - 1 - u
                        case 2: x = W - 1 - u; y = H - 1 - v
                        default: x = W - 1 - v; y = u
                        }
                        let si = (y * W + x) * 3, oi = (v * dw + u) * 3
                        o[oi] = s[si]
                        o[oi + 1] = s[si + 1]
                        o[oi + 2] = s[si + 2]
                    }
                }
            }
        }
        return RGBImage(w: dw, h: dh, px: out)
    }

    func cgImage() -> CGImage? {
        let data = Data(px) as CFData
        guard let prov = CGDataProvider(data: data) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: w * 3,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    func jpeg(quality: CGFloat = 0.8) -> Data? {
        guard let cg = cgImage() else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: quality)
    }
}
