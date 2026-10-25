package org.neforum.neforum_app

import android.content.ClipDescription
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import java.io.File
import java.io.FileNotFoundException

/**
 * Hands NEFORUM's own files to the app a hand-off goes to, as content://
 * addresses another app can read only through a grant: the files shared with
 * "neforum/share" (ShareChannel) and the photos put on the clipboard by
 * "neforum/clipboard" (ClipboardChannel). Read only; files outside NEFORUM's
 * data folder are never served. Declared in AndroidManifest.xml with the
 * authority "<applicationId>.handoff".
 */
class HandoffFileProvider : ContentProvider() {
    override fun onCreate(): Boolean = true

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? {
        val file = fileFor(uri) ?: return null
        val columns = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        val cursor = MatrixCursor(columns, 1)
        cursor.addRow(columns.map {
            when (it) {
                OpenableColumns.DISPLAY_NAME -> file.name
                OpenableColumns.SIZE -> file.length()
                else -> null
            }
        })
        return cursor
    }

    override fun getType(uri: Uri): String? = fileFor(uri)?.let { mimeTypeOf(it) }

    override fun getStreamTypes(uri: Uri, mimeTypeFilter: String): Array<String>? {
        val type = getType(uri) ?: return null
        return if (ClipDescription.compareMimeTypes(type, mimeTypeFilter)) arrayOf(type) else null
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw SecurityException("NEFORUM's hand-off files are read only.")
        val file = fileFor(uri) ?: throw FileNotFoundException(uri.toString())
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = throw UnsupportedOperationException("Read only")

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = 0

    /** The file behind [uri], only when it is inside NEFORUM's data folder. */
    private fun fileFor(uri: Uri): File? {
        val ctx = context ?: return null
        val segments = uri.pathSegments
        if (segments.size < 2 || segments[0] != ROOT) return null
        val root = dataFolder(ctx)
        val file = File(root, segments.drop(1).joinToString(File.separator)).canonicalFile
        return if (file.path.startsWith(root.canonicalPath + File.separator) && file.isFile) file else null
    }

    companion object {
        private const val ROOT = "data"

        fun authority(context: Context): String = "${context.packageName}.handoff"

        /** NEFORUM's private data folder (files, app_flutter, cache). */
        private fun dataFolder(context: Context): File = (context.filesDir.parentFile ?: context.filesDir).canonicalFile

        /** The content:// address of [file], which must be inside NEFORUM's data folder. */
        fun uriFor(context: Context, file: File): Uri {
            val base = dataFolder(context).canonicalPath + File.separator
            val path = file.canonicalPath
            require(path.startsWith(base)) { "${file.name} is not in NEFORUM's folder." }
            val builder = Uri.Builder().scheme("content").authority(authority(context)).appendPath(ROOT)
            for (part in path.substring(base.length).split(File.separatorChar)) builder.appendPath(part)
            return builder.build()
        }

        fun mimeTypeOf(file: File): String =
            MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase()) ?: "application/octet-stream"
    }
}
