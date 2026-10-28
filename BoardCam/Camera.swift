import AVFoundation
import CoreMedia

/// 背面カメラ 1080p30 の映像をフレームごとに渡す。録画はしない。
final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "camera.frames")
    private var device: AVCaptureDevice?
    /// 起動前に setZoom されたら、カメラが立ち上がってから効かせる
    var pendingZoom = 1.0
    /// (縮小画像, 撮影時刻)。カメラ用のキューで呼ばれる
    var onFrame: ((RGBImage, Date) -> Void)?

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { ok in
            guard ok else { return }
            self.queue.async { self.configure() }
        }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(out) { session.addOutput(out) }
        if let conn = out.connection(with: .video) {
            // 処理はいつもカメラ本来の向き(横・端子が右)。縦持ちのときは表示だけ回す
            if conn.isVideoRotationAngleSupported(0) { conn.videoRotationAngle = 0 }
        }
        try? dev.lockForConfiguration()
        dev.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
        dev.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
        dev.unlockForConfiguration()
        device = dev
        session.commitConfiguration()
        if pendingZoom > 1 { setZoom(pendingZoom) }
        session.startRunning()
    }

    func stop() { queue.async { self.session.stopRunning() } }

    /// デジタルズーム(1〜5倍)。センサーの画素が余っているので 2〜3倍までは画質がほぼ落ちない。
    /// 遠く・斜めから盤を撮るとき、盤を画面いっぱいにするために使う
    func setZoom(_ factor: Double) {
        pendingZoom = factor
        queue.async {
            guard let dev = self.device, (try? dev.lockForConfiguration()) != nil else { return }
            let z = min(max(factor, 1), min(5, dev.activeFormat.videoMaxZoomFactor))
            dev.videoZoomFactor = z
            dev.unlockForConfiguration()
        }
    }

    /// キャリブレーション後は露出・ピント・ホワイトバランスを固定する(差分が明るさの揺れを拾わないように)
    func lockExposure(_ lock: Bool) {
        queue.async {
            guard let dev = self.device, (try? dev.lockForConfiguration()) != nil else { return }
            if lock {
                if dev.isExposureModeSupported(.locked) { dev.exposureMode = .locked }
                if dev.isFocusModeSupported(.locked) { dev.focusMode = .locked }
                if dev.isWhiteBalanceModeSupported(.locked) { dev.whiteBalanceMode = .locked }
            } else {
                if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
                if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
                if dev.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    dev.whiteBalanceMode = .continuousAutoWhiteBalance
                }
            }
            dev.unlockForConfiguration()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buf = CMSampleBufferGetImageBuffer(sb) else { return }
        // 撮影時刻(ホスト時計)を実時刻に直す。処理の遅れを含めないため
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let lag = CMTimeGetSeconds(CMTimeSubtract(now, pts))
        let wall = Date().addingTimeInterval(-(lag.isFinite && lag >= 0 && lag < 1 ? lag : 0))
        onFrame?(RGBImage(halving: buf), wall)
    }
}
