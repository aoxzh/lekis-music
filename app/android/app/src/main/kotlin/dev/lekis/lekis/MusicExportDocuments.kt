package dev.lekis.lekis

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.webkit.MimeTypeMap
import java.io.File
import java.io.IOException

internal object MusicExportDocuments {
    fun publish(context: Context, tree: Uri, path: String): Uri {
        require(tree.scheme == "content" && DocumentsContract.isTreeUri(tree))
        val file = File(path).canonicalFile
        val staging = file.parentFile ?: throw IOException("Missing export folder")
        require(staging.parentFile == context.cacheDir.canonicalFile &&
            staging.name.startsWith("lekis-export-") && file.isFile)
        val resolver = context.contentResolver
        val id = DocumentsContract.getTreeDocumentId(tree)
        val parent = DocumentsContract.buildDocumentUriUsingTree(tree, id)
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, id)
        val columns = arrayOf(Document.COLUMN_DISPLAY_NAME)
        val listing = resolver.query(children, columns, null, null, null)
            ?: throw IOException("Cannot read destination folder")
        listing.use {
            while (it.moveToNext()) {
                if (it.getString(0) == file.name) throw IOException("File already exists: ${file.name}")
            }
        }
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase())
            ?: "application/octet-stream"
        val document = DocumentsContract.createDocument(resolver, parent, mime, file.name)
            ?: throw IOException("Cannot create destination file")
        try {
            val created = resolver.query(document, columns, null, null, null)?.use {
                if (it.moveToFirst()) it.getString(0) else null
            }
            if (created != file.name) throw IOException("The provider could not preserve the filename: ${file.name}")
            val output = resolver.openOutputStream(document, "w") ?: throw IOException("Cannot open destination file")
            output.use { sink -> file.inputStream().use { it.copyTo(sink) } }
            return document
        } catch (error: Exception) {
            runCatching { DocumentsContract.deleteDocument(resolver, document) }
            throw error
        }
    }
}
