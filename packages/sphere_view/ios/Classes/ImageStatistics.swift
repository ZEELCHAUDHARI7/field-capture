import CoreGraphics
import Foundation
import ImageIO

/// The one measurement that turns "the AE and AWB locks held" from an opinion
/// into a number.
///
/// §6 requires the grey-card check to be a measurement — "not by eye" — and the
/// exit criterion is under 1% luminance variation across 29 captures. Computed
/// on a 512 px thumbnail, which is a large reduction in work and changes the
/// mean of a flat card by nothing at that threshold, and over the centre 20%
/// only, because a grey card does not fill the frame and corner vignetting
/// would swamp the very variation being measured.
enum ImageStatistics {

    static func centreMeansRgb(jpeg: Data) -> [Double]? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 512,
                ] as CFDictionary)
        else { return nil }

        let width = image.width
        let height = image.height
        let cropWidth = max(1, width / 5)
        let cropHeight = max(1, height / 5)
        guard
            let crop = image.cropping(
                to: CGRect(
                    x: (width - cropWidth) / 2,
                    y: (height - cropHeight) / 2,
                    width: cropWidth,
                    height: cropHeight))
        else { return nil }

        var buffer = [UInt8](repeating: 0, count: cropWidth * cropHeight * 4)
        guard
            let context = CGContext(
                data: &buffer,
                width: cropWidth,
                height: cropHeight,
                bitsPerComponent: 8,
                bytesPerRow: cropWidth * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: cropWidth, height: cropHeight))

        var r = 0.0
        var g = 0.0
        var b = 0.0
        for i in stride(from: 0, to: buffer.count, by: 4) {
            r += Double(buffer[i])
            g += Double(buffer[i + 1])
            b += Double(buffer[i + 2])
        }
        let n = Double(cropWidth * cropHeight)
        return [r / n, g / n, b / n]
    }
}
