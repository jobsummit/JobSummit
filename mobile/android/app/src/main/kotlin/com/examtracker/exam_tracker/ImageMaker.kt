package com.examtracker.exam_tracker

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Rect
import android.media.ExifInterface
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import java.io.ByteArrayOutputStream
import java.io.File
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * A photo or signature sized for an exam form: upright, cropped to the form's
 * shape from the middle, resized, on white, and saved as the best JPEG quality
 * that fits the size limit. Too small for the minimum: padded with a JPEG comment,
 * which every image reader skips.
 */
object ImageMaker {
    fun make(path: String, width: Int?, height: Int?, minKb: Int?, maxKb: Int?): ByteArray {
        val longest = max(width ?: 0, height ?: 0)
        var image = onWhite(upright(path, if (longest > 0) longest * 2 else 2000))
        val sized = width != null && height != null && width > 0 && height > 0
        if (sized) image = cropTo(image, width!!, height!!)

        // KB as 1000 bytes at the top and 1024 at the bottom: inside the limit either way.
        val most = maxKb?.let { it * 1000 }
        val least = minKb?.let { it * 1024 }?.takeIf { most == null || it < most }
        var bytes = fit(image, most, mayShrink = !sized)
        if (least != null && bytes.size < least) bytes = padded(bytes, least + 512)
        return bytes
    }

    /** The highest quality under [most] bytes; past quality 30, smaller instead (when no size is fixed). */
    private fun fit(image: Bitmap, most: Int?, mayShrink: Boolean): ByteArray {
        if (most == null) return jpeg(image, 90)
        var current = image
        while (true) {
            for (q in 95 downTo 30 step 5) {
                val b = jpeg(current, q)
                if (b.size <= most) return b
            }
            if (!mayShrink || current.width < 60 || current.height < 60) return jpeg(current, 30)
            current = Bitmap.createScaledBitmap(
                current, (current.width * 0.85).roundToInt(), (current.height * 0.85).roundToInt(), true
            )
        }
    }

    private fun jpeg(image: Bitmap, quality: Int): ByteArray =
        ByteArrayOutputStream().also { image.compress(Bitmap.CompressFormat.JPEG, quality, it) }.toByteArray()

    /** COM segments (0xFFFE) right after the start marker, up to [size] bytes in all. */
    private fun padded(jpeg: ByteArray, size: Int): ByteArray {
        val out = ByteArrayOutputStream()
        out.write(jpeg, 0, 2)
        var missing = size - jpeg.size
        while (missing > 4) {
            val chunk = minOf(missing - 4, 65533)
            out.write(0xFF); out.write(0xFE)
            out.write((chunk + 2) shr 8); out.write((chunk + 2) and 0xFF)
            out.write(ByteArray(chunk) { 0x20 })
            missing -= chunk + 4
        }
        out.write(jpeg, 2, jpeg.size - 2)
        return out.toByteArray()
    }

    /** Decoded about [side] px on its long edge (never much bigger), turned the way the camera held it. */
    private fun upright(path: String, side: Int): Bitmap {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        var sample = 1
        while (max(bounds.outWidth, bounds.outHeight) / (sample * 2) >= side) sample *= 2
        val bitmap = BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = sample })
            ?: throw IllegalArgumentException("not an image")
        val turn = try {
            when (ExifInterface(path).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
                ExifInterface.ORIENTATION_ROTATE_90 -> 90f
                ExifInterface.ORIENTATION_ROTATE_180 -> 180f
                ExifInterface.ORIENTATION_ROTATE_270 -> 270f
                else -> 0f
            }
        } catch (_: Exception) {
            0f
        }
        if (turn == 0f) return bitmap
        val m = Matrix().apply { postRotate(turn) }
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, m, true)
    }

    /** A transparent PNG signature would turn black as a JPEG. */
    private fun onWhite(image: Bitmap): Bitmap {
        if (!image.hasAlpha()) return image
        val out = Bitmap.createBitmap(image.width, image.height, Bitmap.Config.ARGB_8888)
        Canvas(out).apply {
            drawColor(Color.WHITE)
            drawBitmap(image, 0f, 0f, null)
        }
        return out
    }

    private fun cropTo(image: Bitmap, width: Int, height: Int): Bitmap {
        val want = width.toFloat() / height
        val have = image.width.toFloat() / image.height
        val crop = if (have > want) {
            val w = (image.height * want).roundToInt()
            Rect((image.width - w) / 2, 0, (image.width - w) / 2 + w, image.height)
        } else {
            val h = (image.width / want).roundToInt()
            Rect(0, (image.height - h) / 2, image.width, (image.height - h) / 2 + h)
        }
        val out = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        Canvas(out).drawBitmap(image, crop, Rect(0, 0, width, height), Paint(Paint.FILTER_BITMAP_FLAG))
        return out
    }

    /** Into Pictures/JobSummit, where a browser's "choose file" finds it. Returns where. */
    fun save(context: Context, bytes: ByteArray, name: String): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, name)
                put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
                put(MediaStore.Images.Media.RELATIVE_PATH, "${Environment.DIRECTORY_PICTURES}/JobSummit")
            }
            val resolver = context.contentResolver
            val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("no picture storage")
            resolver.openOutputStream(uri).use { it!!.write(bytes) }
            return "Pictures/JobSummit/$name"
        }
        @Suppress("DEPRECATION")
        val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES), "JobSummit")
        dir.mkdirs()
        File(dir, name).writeBytes(bytes)
        return "Pictures/JobSummit/$name"
    }
}
