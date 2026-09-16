package com.lzhuofei.extraviewer

import android.content.ContentResolver
import android.net.Uri
import android.provider.DocumentsContract
import java.io.Closeable

/** One directory cursor; the durable traversal queue belongs to Dart/SQLite. */
class SafDirectoryReader(resolver: ContentResolver, private val uri: Uri) : Closeable {
    private val cursor = resolver.query(
        DocumentsContract.buildChildDocumentsUriUsingTree(uri, DocumentsContract.getDocumentId(uri)),
        MainActivity.DIRECTORY_PROJECTION, null, null, null,
    ) ?: throw IllegalStateException("Directory provider returned no cursor")

    fun readPage(): Map<String, Any> {
        val entries = mutableListOf<Map<String, Any>>()
        while (entries.size < 200) {
            if (!cursor.moveToNext()) return mapOf("entries" to entries, "complete" to true)
            val id = cursor.getString(0) ?: throw IllegalStateException("Directory entry has no ID")
            val name = cursor.getString(1)?.takeIf { it.isNotBlank() }
                ?: throw IllegalStateException("Directory entry has no name")
            entries += mapOf(
                "locator" to DocumentsContract.buildDocumentUriUsingTree(uri, id).toString(),
                "name" to name,
                "directory" to (cursor.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR),
                "size" to if (cursor.isNull(3)) 0L else cursor.getLong(3),
                "modified" to if (cursor.isNull(4)) 0L else cursor.getLong(4),
            )
        }
        return mapOf("entries" to entries, "complete" to false)
    }

    override fun close() = cursor.close()
}
