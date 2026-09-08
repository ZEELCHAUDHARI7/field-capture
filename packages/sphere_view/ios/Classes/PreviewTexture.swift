import CoreVideo
import Flutter
import Foundation

/// The preview, delivered as a Flutter platform texture.
///
/// §4: preview exists only for aiming, so it is requested at ~1280 wide
/// regardless of capture resolution — a full-resolution preview on a tablet
/// burns battery and thermal headroom that the 60 s stitch will need — and it
/// is delivered through the texture APIs. Bytes are never streamed over the
/// channel; at 1280×960 BGRA that would be ~150 MB/s of message traffic to draw
/// a viewfinder.
///
/// One buffer is held at a time and the newest wins. Dropping a preview frame
/// costs nothing: the frame the shutter records comes from the photo output,
/// not from here.
final class PreviewTexture: NSObject, FlutterTexture {

    private let lock = NSLock()
    private var latest: CVPixelBuffer?

    func setPixelBuffer(_ buffer: CVPixelBuffer) {
        lock.lock()
        latest = buffer
        lock.unlock()
    }

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        lock.lock()
        defer { lock.unlock() }
        guard let buffer = latest else { return nil }
        return Unmanaged.passRetained(buffer)
    }

    func clear() {
        lock.lock()
        latest = nil
        lock.unlock()
    }
}
