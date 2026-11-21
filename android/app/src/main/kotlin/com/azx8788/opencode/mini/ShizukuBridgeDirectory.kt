package com.azx8788.opencode.mini

import java.io.File
import java.nio.file.Files

/** Only an empty app-owned directory is recoverable after a crash before marker creation. */
internal object ShizukuBridgeDirectory {
    private const val MARKER = "shizuku-bridge-v1\n"

    fun prepare(directory: File, validateDirectory: (File) -> Unit, validateMarker: (File) -> Unit) {
        check(!Files.isSymbolicLink(directory.toPath()))
        if (!directory.exists()) check(directory.mkdirs())
        check(directory.canonicalFile == directory.absoluteFile && directory.isDirectory)
        val marker = File(directory, "opencode-plus-owned")
        check(!Files.isSymbolicLink(marker.toPath()))
        val recoverable = !marker.exists()
        if (recoverable) check(checkNotNull(directory.list()).isEmpty())
        else checkMarker(marker, validateMarker)
        validateDirectory(directory)
        if (recoverable) {
            ShizukuOperationJournal.atomicFile(marker, MARKER)
            checkMarker(marker, validateMarker)
        }
    }

    private fun checkMarker(marker: File, validateMarker: (File) -> Unit) {
        validateMarker(marker)
        check(marker.readText() == MARKER)
    }
}
