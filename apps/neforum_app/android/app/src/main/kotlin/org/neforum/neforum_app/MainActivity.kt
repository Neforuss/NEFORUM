package org.neforum.neforum_app

import android.app.Activity
import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.FileOutputStream
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private var pendingPick: MethodChannel.Result? = null
    private var pendingMode = "folder"
    private val io = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Set up again (the activity was recreated): a pick the previous
        // engine waited for hears "cancelled" rather than nothing.
        pendingPick?.let { earlier ->
            pendingPick = null
            try {
                earlier.success(null)
            } catch (e: Exception) {
                // That engine is gone.
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "neforum/syncfolder")
            .setMethodCallHandler { call, result -> handleSyncFolder(call, result) }
        VideoCompositor(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
    }

    /**
     * "neforum/syncfolder": the sync file in a location picked with Android's
     * file picker (lib/platform/files_app_folder.dart). A folder ("Choose
     * folder": phone storage that Syncthing or another sync app keeps in sync,
     * the Nextcloud app...), or the sync file itself, for apps that only let
     * other apps open and save single files (Google Drive, OneDrive, Dropbox...).
     * Access survives restarts through a persisted URI permission. An empty
     * file counts as no sync file yet. "probe" tells whether NEFORUM may
     * change the location without changing anything.
     */
    private fun handleSyncFolder(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "pick") {
            pick(call.argument<String>("mode") ?: "folder", result)
            return
        }
        val bookmark = call.argument<String>("bookmark")
        if (bookmark.isNullOrEmpty()) {
            result.error("bookmark", "No folder was chosen.", null)
            return
        }
        val target = Uri.parse(bookmark)
        val isFile = call.argument<Boolean>("file") ?: false
        val name = call.argument<String>("name") ?: ""
        io.execute {
            try {
                val out = SyncStorage(contentResolver).run(call, target, isFile, name)
                runOnUiThread { result.success(out) }
            } catch (e: SyncConflictException) {
                runOnUiThread { result.error("conflict", e.message, null) }
            } catch (e: SyncLocationException) {
                runOnUiThread { result.error("bookmark", e.message, null) }
            } catch (e: SecurityException) {
                runOnUiThread {
                    result.error("bookmark", "Android no longer lets NEFORUM use this location: choose it again in Settings > Sync.", null)
                }
            } catch (e: Exception) {
                runOnUiThread { result.error("io", e.message ?: e.toString(), null) }
            }
        }
    }

    private fun pick(mode: String, result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.success(null)
            return
        }
        val intent = when (mode) {
            "file" -> Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
            }
            "create" -> Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "application/octet-stream"
                putExtra(Intent.EXTRA_TITLE, SYNC_FILE_NAME)
            }
            else -> Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
        }
        intent.addFlags(
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
        )
        pendingPick = result
        pendingMode = mode
        try {
            startActivityForResult(intent, PICK_REQUEST)
        } catch (e: Exception) {
            pendingPick = null
            result.error("picker", "No file picker is available: ${e.message}", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PICK_REQUEST) return
        val result = pendingPick ?: return
        pendingPick = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        val isFile = pendingMode != "folder"
        if (!isFile && !DocumentsContract.isTreeUri(uri)) {
            // Another app answered the folder request with a single file or
            // an address of its own: the folder calls would fail on it.
            result.error(
                "picker",
                "This file picker did not return a folder NEFORUM can use: choose the folder with Android's own picker, or use Choose the sync file instead.",
                null
            )
            return
        }
        val storage = SyncStorage(contentResolver)
        val shown = storage.displayName(uri, isFile)
        if (pendingMode == "create" && shown != null && shown != SYNC_FILE_NAME) {
            // "Keep both" next to an existing sync file, or the app renamed
            // it: the other devices would never find that copy. Apps that
            // allow two files with the same name (Google Drive) save a second
            // NEFORUM.neforumsync instead, which cannot be caught here.
            io.execute { storage.deleteIfEmpty(uri) }
            result.error(
                "picker",
                "The file was saved as \"$shown\", so your other devices would not find it. " +
                    "If $SYNC_FILE_NAME is already there, use Choose the sync file. Otherwise create it again with that exact name.",
                null
            )
            return
        }
        val rw = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        try {
            contentResolver.takePersistableUriPermission(uri, rw)
        } catch (e: SecurityException) {
            // The app offering the location gave only this session's access:
            // it works until NEFORUM restarts, then asks to choose it again.
        }
        val name = shown ?: if (isFile) SYNC_FILE_NAME else "folder"
        result.success(mapOf("bookmark" to uri.toString(), "name" to name, "path" to uri.toString(), "file" to isFile))
    }

    companion object {
        private const val PICK_REQUEST = 52_780

        /** kSyncFileName in neforum_core. */
        private const val SYNC_FILE_NAME = "NEFORUM.neforumsync"
    }
}

class SyncConflictException(message: String) : Exception(message)

/** The picked location is not there any more: choose it again. */
class SyncLocationException(message: String) : Exception(message)

/** Reads and writes the sync file through the Storage Access Framework. */
class SyncStorage(private val resolver: ContentResolver) {
    fun run(call: MethodCall, target: Uri, isFile: Boolean, name: String): Any? = when (call.method) {
        "probe" -> probe(target, isFile)
        "read" -> {
            val doc = locate(target, isFile, name)
            val version = doc?.let { version(it) }
            if (doc == null || version == null) null
            else mapOf("bytes" to readAll(doc), "version" to version)
        }
        "write" -> {
            val bytes = call.argument<ByteArray>("bytes") ?: throw IOException("Nothing to write.")
            val force = call.argument<Boolean>("force") ?: false
            val ifMatch = call.argument<String>("ifMatch")
            var doc = locate(target, isFile, name)
            if (!force && doc?.let { version(it) } != ifMatch) {
                throw SyncConflictException("The sync file changed while NEFORUM was writing it.")
            }
            if (doc == null) {
                // A picked file that is gone already failed in locate().
                if (isFile) throw SyncLocationException(FILE_GONE)
                val parent = DocumentsContract.buildDocumentUriUsingTree(target, DocumentsContract.getTreeDocumentId(target))
                doc = DocumentsContract.createDocument(resolver, parent, "application/octet-stream", name)
                    ?: throw IOException("Could not create $name in the folder.")
            }
            try {
                writeAll(doc, bytes)
            } catch (e: java.io.FileNotFoundException) {
                // The picked file went away in the meantime.
                if (isFile) throw SyncLocationException(FILE_GONE)
                throw e
            }
            version(doc) ?: ""
        }
        "list" -> if (isFile) emptyList<String>() else children(target).map { it.first }
        "delete" -> {
            if (!isFile) locate(target, false, name)?.let { DocumentsContract.deleteDocument(resolver, it) }
            null
        }
        else -> throw IOException("Unknown request ${call.method}")
    }

    /** The name the app shows for the picked file or folder; null when it does not tell. Never throws. */
    fun displayName(uri: Uri, isFile: Boolean): String? {
        return try {
            val doc = if (isFile) uri else DocumentsContract.buildDocumentUriUsingTree(uri, DocumentsContract.getTreeDocumentId(uri))
            resolver.query(doc, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) c.getString(0) else null
            }
        } catch (e: Exception) {
            null
        }
    }

    /** Removes a file "create" saved under another name, only while it is empty. */
    fun deleteIfEmpty(doc: Uri) {
        try {
            if (size(doc) == 0L) DocumentsContract.deleteDocument(resolver, doc)
        } catch (e: Exception) {
            // Left behind: it is empty.
        }
    }

    /**
     * Whether NEFORUM may change the picked file, or add files to the picked
     * folder, asked without changing anything: the flags the app reports for
     * it, or, for a file whose app reports none, whether it opens for writing.
     */
    private fun probe(target: Uri, isFile: Boolean): Boolean {
        val doc = if (isFile) target else DocumentsContract.buildDocumentUriUsingTree(target, DocumentsContract.getTreeDocumentId(target))
        val gone = (if (isFile) "The sync file" else "The folder") + " is gone: choose it again in Settings > Sync."
        val flags: Int? = try {
            val cursor = resolver.query(doc, arrayOf(DocumentsContract.Document.COLUMN_FLAGS), null, null, null)
                ?: throw SyncLocationException(gone)
            cursor.use { c ->
                if (!c.moveToFirst()) throw SyncLocationException(gone)
                if (c.isNull(0)) null else c.getInt(0)
            }
        } catch (e: java.io.FileNotFoundException) {
            throw SyncLocationException(gone)
        } catch (e: IllegalArgumentException) {
            null // No document flags at this address.
        }
        if (flags != null) {
            val needed = if (isFile) DocumentsContract.Document.FLAG_SUPPORTS_WRITE else DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE
            return (flags and needed) != 0
        }
        // For a folder, the probe file the app writes next tells.
        if (!isFile) return true
        return try {
            resolver.openFileDescriptor(doc, "rw")?.use { true } ?: false
        } catch (e: Exception) {
            false
        }
    }

    /**
     * "Replace the contents": "wt" truncates; some apps only know "w", which
     * can keep the end of a longer old file, and some ignore the "t". So the
     * file is also cut to the new length through the descriptor, when it is a
     * real file, and the length is checked after closing. A wrong length gets
     * one more cut ("rw") rather than leaving the new start with the old end;
     * only when that does not help either does the write fail.
     */
    private fun writeAll(doc: Uri, bytes: ByteArray) {
        val expected = bytes.size.toLong()
        val pfd = try {
            resolver.openFileDescriptor(doc, "wt")
        } catch (e: Exception) {
            null // This app does not know "wt" (or the file is gone: "w" says so too).
        } ?: resolver.openFileDescriptor(doc, "w") ?: throw IOException("Could not open the sync file for writing.")
        ParcelFileDescriptor.AutoCloseOutputStream(pfd).use { out ->
            out.write(bytes)
            out.flush()
            cut(out, expected)
        }
        if (hasLength(doc, expected)) return
        try {
            resolver.openFileDescriptor(doc, "rw")?.let { again ->
                ParcelFileDescriptor.AutoCloseOutputStream(again).use { cut(it, expected) }
            }
        } catch (e: Exception) {
            // The app does not open it that way: the check below decides.
        }
        if (!hasLength(doc, expected)) throw IOException("The cloud app did not replace the whole file.")
    }

    /**
     * Cuts the file behind [out] to [length] when it is longer. A pipe or a
     * proxy descriptor has nothing to cut: the length check afterwards tells.
     */
    private fun cut(out: FileOutputStream, length: Long) {
        try {
            val channel = out.channel
            if (channel.size() > length) channel.truncate(length)
        } catch (e: Exception) {
            // Not a real file.
        }
    }

    /**
     * Whether the file is [expected] bytes long: the size the app reports,
     * or, when it reports none (or not yet the new one), the file read back.
     */
    private fun hasLength(doc: Uri, expected: Long): Boolean =
        size(doc) == expected || readAll(doc).size.toLong() == expected

    private fun readAll(doc: Uri): ByteArray =
        resolver.openInputStream(doc)?.use { it.readBytes() } ?: throw IOException("Could not read the sync file.")

    /** The size the app reports; null when it does not tell. */
    private fun size(doc: Uri): Long? = try {
        resolver.query(doc, arrayOf(DocumentsContract.Document.COLUMN_SIZE), null, null, null)?.use { c ->
            if (c.moveToFirst() && !c.isNull(0)) c.getLong(0) else null
        }
    } catch (e: Exception) {
        null
    }

    /**
     * The sync file: the picked file itself, or the one named [name] in the
     * picked folder (null when there is none yet). A picked file that is gone
     * is not "no sync file yet": it has to be chosen again.
     */
    private fun locate(target: Uri, isFile: Boolean, name: String): Uri? {
        if (isFile) {
            if (!exists(target)) throw SyncLocationException(FILE_GONE)
            return target
        }
        val id = children(target).firstOrNull { it.first == name }?.second ?: return null
        return DocumentsContract.buildDocumentUriUsingTree(target, id)
    }

    /** Whether the app still has the document: no cursor, no row or "not found" means gone. */
    private fun exists(doc: Uri): Boolean = try {
        resolver.query(doc, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID), null, null, null)?.use { c ->
            c.moveToFirst()
        } ?: false
    } catch (e: java.io.FileNotFoundException) {
        false
    } catch (e: IllegalArgumentException) {
        true // No document columns at this address: reading or writing it tells.
    }

    /** (display name, document id) of each file in the picked folder. */
    private fun children(tree: Uri): List<Pair<String, String>> {
        val uri = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        val out = mutableListOf<Pair<String, String>>()
        resolver.query(
            uri,
            arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_DOCUMENT_ID),
            null, null, null
        )?.use { c ->
            while (c.moveToNext()) {
                val id = c.getString(1)
                if (id != null) out.add(Pair(c.getString(0) ?: "", id))
            }
        }
        return out
    }

    /**
     * Modification time and size. When the app reports no size, the contents
     * are read instead: empty counts as no sync file, and when there is no
     * modification time either, a hash of them ("h:...") stands in, so
     * changes still show. null when the file is missing or empty.
     */
    private fun version(doc: Uri): String? {
        val (modified, size) = try {
            resolver.query(
                doc,
                arrayOf(DocumentsContract.Document.COLUMN_LAST_MODIFIED, DocumentsContract.Document.COLUMN_SIZE),
                null, null, null
            )?.use { c ->
                if (!c.moveToFirst()) return null
                Pair(if (c.isNull(0)) null else c.getLong(0), if (c.isNull(1)) null else c.getLong(1))
            } ?: return null
        } catch (e: java.io.FileNotFoundException) {
            return null
        }
        if (size == 0L) return null
        if (size == null) {
            val bytes = try {
                readAll(doc)
            } catch (e: java.io.FileNotFoundException) {
                return null
            }
            if (bytes.isEmpty()) return null
            if (modified == null) {
                return "h:" + MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 0xff) }
            }
        }
        return "${modified ?: 0L}:${size ?: -1L}"
    }

    private companion object {
        /** A picked sync file the app no longer has ("bookmark" on the Dart side). */
        const val FILE_GONE = "The sync file is gone: choose it again in Settings > Sync."
    }
}
