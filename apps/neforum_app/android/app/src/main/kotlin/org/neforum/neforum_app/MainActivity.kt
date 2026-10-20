package org.neforum.neforum_app

import android.app.Activity
import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private var pendingPick: MethodChannel.Result? = null
    private var pendingIsFile = false
    private val io = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "neforum/syncfolder")
            .setMethodCallHandler { call, result -> handleSyncFolder(call, result) }
    }

    /**
     * "neforum/syncfolder": the sync file in a location picked with Android's
     * file picker (lib/platform/files_app_folder.dart). A folder ("Choose
     * folder": phone storage that Syncthing or another sync app keeps in sync,
     * the Nextcloud app...), or the sync file itself, for apps that only let
     * other apps open and save single files (Google Drive, OneDrive, Dropbox...).
     * Access survives restarts through a persisted URI permission. An empty
     * file counts as no sync file yet.
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
                putExtra(Intent.EXTRA_TITLE, "NEFORUM.neforumsync")
            }
            else -> Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
        }
        intent.addFlags(
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
        )
        pendingPick = result
        pendingIsFile = mode != "folder"
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
        val rw = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        try {
            contentResolver.takePersistableUriPermission(uri, rw)
        } catch (e: SecurityException) {
            // The app offering the location gave only this session's access:
            // it works until NEFORUM restarts, then asks to choose it again.
        }
        val name = SyncStorage(contentResolver).displayName(uri, pendingIsFile)
            ?: if (pendingIsFile) "NEFORUM.neforumsync" else "folder"
        result.success(mapOf("bookmark" to uri.toString(), "name" to name, "path" to uri.toString(), "file" to pendingIsFile))
    }

    companion object {
        private const val PICK_REQUEST = 52_780
    }
}

class SyncConflictException(message: String) : Exception(message)

/** Reads and writes the sync file through the Storage Access Framework. */
class SyncStorage(private val resolver: ContentResolver) {
    fun run(call: MethodCall, target: Uri, isFile: Boolean, name: String): Any? = when (call.method) {
        "read" -> {
            val doc = locate(target, isFile, name)
            val version = doc?.let { version(it) }
            if (doc == null || version == null) null
            else mapOf("bytes" to (resolver.openInputStream(doc)?.use { it.readBytes() } ?: ByteArray(0)), "version" to version)
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
                if (isFile) throw IOException("The sync file is gone: choose it again in Settings > Sync.")
                val parent = DocumentsContract.buildDocumentUriUsingTree(target, DocumentsContract.getTreeDocumentId(target))
                doc = DocumentsContract.createDocument(resolver, parent, "application/octet-stream", name)
                    ?: throw IOException("Could not create $name in the folder.")
            }
            writeAll(doc, bytes)
            version(doc) ?: ""
        }
        "list" -> if (isFile) emptyList<String>() else children(target).map { it.first }
        "delete" -> {
            if (!isFile) locate(target, false, name)?.let { DocumentsContract.deleteDocument(resolver, it) }
            null
        }
        else -> throw IOException("Unknown request ${call.method}")
    }

    fun displayName(uri: Uri, isFile: Boolean): String? {
        val doc = if (isFile) uri else DocumentsContract.buildDocumentUriUsingTree(uri, DocumentsContract.getTreeDocumentId(uri))
        return try {
            resolver.query(doc, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) c.getString(0) else null
            }
        } catch (e: Exception) {
            null
        }
    }

    /** "Replace the contents": "wt" truncates; some apps only know "w". */
    private fun writeAll(doc: Uri, bytes: ByteArray) {
        val stream = try {
            resolver.openOutputStream(doc, "wt")
        } catch (e: Exception) {
            resolver.openOutputStream(doc, "w")
        } ?: throw IOException("Could not open the sync file for writing.")
        stream.use { it.write(bytes) }
    }

    private fun locate(target: Uri, isFile: Boolean, name: String): Uri? {
        if (isFile) return target
        val id = children(target).firstOrNull { it.first == name }?.second ?: return null
        return DocumentsContract.buildDocumentUriUsingTree(target, id)
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

    /** Modification time and size; null when the file is missing or empty. */
    private fun version(doc: Uri): String? {
        return try {
            resolver.query(
                doc,
                arrayOf(DocumentsContract.Document.COLUMN_LAST_MODIFIED, DocumentsContract.Document.COLUMN_SIZE),
                null, null, null
            )?.use { c ->
                if (!c.moveToFirst()) return null
                val modified = if (c.isNull(0)) 0L else c.getLong(0)
                val size = if (c.isNull(1)) -1L else c.getLong(1)
                if (size == 0L) null else "$modified:$size"
            }
        } catch (e: java.io.FileNotFoundException) {
            null
        }
    }
}
