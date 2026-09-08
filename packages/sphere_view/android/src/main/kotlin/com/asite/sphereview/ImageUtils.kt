package com.asite.sphereview

import android.graphics.BitmapFactory
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.media.Image
import androidx.exifinterface.media.ExifInterface
import java.io.ByteArrayOutputStream
import java.io.File

/**
 * Pixel plumbing for the capture path: getting bytes out of an `Image` before
 * it is closed, encoding the deferred-JPEG variant, and the one measurement
 * that turns "the AE lock held" from an opinion into a number.
 */
object ImageUtils {

    /**
     * Forces a written JPEG's EXIF Orientation to 1 (normal).
     *
     * `JPEG_ORIENTATION = 0` on the request already asks the HAL for unrotated
     * pixels and a normal tag, and most honour it. This is the belt: the whole
     * pipeline's contract is that the pixels on disk are the capture frame as the
     * sensor delivered it and that `intrinsics` plus `captureQuarterTurns`
     * describe *those* pixels — and `cv::imread` applies a non-normal tag on
     * decode, silently transposing the frame out from under the model. A vendor
     * that writes the tag anyway would produce a panorama with rotated frames and
     * grey holes, with nothing in any log to say why.
     *
     * Best effort by design: a frame whose EXIF cannot be rewritten is still a
     * perfectly good photograph, and the native side now checks the decoded size
     * against the intrinsics and fails loudly rather than silently. Never throws.
     */
    fun normaliseExifOrientation(file: File) {
        try {
            val exif = ExifInterface(file.absolutePath)
            val current = exif.getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL,
            )
            if (current == ExifInterface.ORIENTATION_NORMAL) return
            exif.setAttribute(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL.toString(),
            )
            exif.saveAttributes()
        } catch (_: Throwable) {
            // Not worth failing a capture over, and not worth a warning either:
            // the decode-size check downstream catches the case that matters.
        }
    }

    /**
     * Mean R, G, B over the centre 20% of a JPEG.
     *
     * This is the grey-card measurement of §6, and it exists because "AE and
     * AWB lock verified […] not by eye" is an exit criterion. Decoded at
     * `inSampleSize = 8`, which is a factor-64 reduction in work and changes
     * the mean of a flat card by nothing that matters at the 1% threshold.
     *
     * The centre 20% rather than the whole frame because a grey card does not
     * fill the frame, and vignetting at the corners would swamp the very
     * variation being measured.
     */
    fun centreMeansRgb(jpeg: ByteArray): DoubleArray? {
        val opts = BitmapFactory.Options().apply { inSampleSize = 8 }
        val bmp = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size, opts) ?: return null
        try {
            val cw = (bmp.width * 0.2).toInt().coerceAtLeast(1)
            val ch = (bmp.height * 0.2).toInt().coerceAtLeast(1)
            val x0 = (bmp.width - cw) / 2
            val y0 = (bmp.height - ch) / 2
            val px = IntArray(cw * ch)
            bmp.getPixels(px, 0, cw, x0, y0, cw, ch)
            var r = 0.0
            var g = 0.0
            var b = 0.0
            for (p in px) {
                r += (p shr 16) and 0xFF
                g += (p shr 8) and 0xFF
                b += p and 0xFF
            }
            val n = px.size.toDouble()
            return doubleArrayOf(r / n, g / n, b / n)
        } finally {
            bmp.recycle()
        }
    }

    /** Copies a JPEG `Image`'s single plane out before the buffer is recycled. */
    fun jpegBytes(image: Image): ByteArray {
        val buffer = image.planes[0].buffer
        val bytes = ByteArray(buffer.remaining())
        buffer.get(bytes)
        return bytes
    }

    /**
     * `YUV_420_888` → NV21, honouring row and pixel strides.
     *
     * Strides are not cosmetic here: HALs routinely pad rows, and reading the
     * planes as though they were tightly packed produces a sheared image that
     * still looks plausible in a thumbnail.
     */
    fun yuv420ToNv21(image: Image): ByteArray {
        val w = image.width
        val h = image.height
        val out = ByteArray(w * h * 3 / 2)

        val yPlane = image.planes[0]
        val yBuf = yPlane.buffer
        var pos = 0
        if (yPlane.rowStride == w && yPlane.pixelStride == 1) {
            yBuf.get(out, 0, w * h)
            pos = w * h
        } else {
            val row = ByteArray(yPlane.rowStride)
            for (i in 0 until h) {
                yBuf.position(i * yPlane.rowStride)
                val toRead = minOf(yPlane.rowStride, yBuf.remaining())
                yBuf.get(row, 0, toRead)
                System.arraycopy(row, 0, out, pos, w)
                pos += w
            }
        }

        val uPlane = image.planes[1]
        val vPlane = image.planes[2]
        val uBuf = uPlane.buffer
        val vBuf = vPlane.buffer
        val cw = w / 2
        val chh = h / 2
        for (i in 0 until chh) {
            for (j in 0 until cw) {
                val vIdx = i * vPlane.rowStride + j * vPlane.pixelStride
                val uIdx = i * uPlane.rowStride + j * uPlane.pixelStride
                out[pos++] = if (vIdx < vBuf.limit()) vBuf.get(vIdx) else 128.toByte()
                out[pos++] = if (uIdx < uBuf.limit()) uBuf.get(uIdx) else 128.toByte()
            }
        }
        return out
    }

    /**
     * Encodes NV21 to JPEG. This is the cost the deferred path *moves*, not the
     * cost it removes — R3 §9's evidence is that encoding, not readout, is the
     * dominant per-frame latency, so moving it off the burst is what buys the
     * wall clock back. It still has to happen, just while the user is walking
     * to the next target.
     */
    fun nv21ToJpeg(nv21: ByteArray, width: Int, height: Int, quality: Int): ByteArray {
        val yuv = YuvImage(nv21, ImageFormat.NV21, width, height, null)
        val bos = ByteArrayOutputStream(width * height / 4)
        yuv.compressToJpeg(Rect(0, 0, width, height), quality, bos)
        return bos.toByteArray()
    }
}
