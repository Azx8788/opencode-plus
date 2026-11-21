package com.azx8788.opencode.mini

import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ShizukuBridgeDirectoryTest {
    @get:Rule val temporary = TemporaryFolder()

    private fun validateDirectory(file: File) {
        check(file.isDirectory && !Files.isSymbolicLink(file.toPath()))
    }

    private fun validateMarker(file: File) {
        check(file.isFile && !Files.isSymbolicLink(file.toPath()) && file.length() in 1L..80L)
    }

    @Test fun emptyOwnedDirectoryLeftByInterruptedInitializationIsRecoverable() {
        val directory = temporary.newFolder("socket-dir")
        ShizukuBridgeDirectory.prepare(directory, ::validateDirectory, ::validateMarker)
        assertEquals("shizuku-bridge-v1\n", File(directory, "opencode-plus-owned").readText())
    }

    @Test fun populatedDirectoryWithoutMarkerRemainsRejected() {
        val directory = temporary.newFolder("foreign-dir")
        File(directory, "foreign").writeText("keep")
        assertThrows(IllegalStateException::class.java) {
            ShizukuBridgeDirectory.prepare(directory, ::validateDirectory, ::validateMarker)
        }
        assertTrue(File(directory, "foreign").exists())
        assertFalse(File(directory, "opencode-plus-owned").exists())
    }

    @Test fun symlinkedDirectoryAndMarkerRemainRejected() {
        val target = temporary.newFolder("target")
        val directoryLink = File(temporary.root, "directory-link")
        Files.createSymbolicLink(directoryLink.toPath(), target.toPath())
        assertThrows(IllegalStateException::class.java) {
            ShizukuBridgeDirectory.prepare(directoryLink, ::validateDirectory, ::validateMarker)
        }

        val markerDir = temporary.newFolder("marker-dir")
        val markerTarget = File(temporary.root, "marker-target").apply { writeText("shizuku-bridge-v1\n") }
        Files.createSymbolicLink(File(markerDir, "opencode-plus-owned").toPath(), markerTarget.toPath())
        assertThrows(IllegalStateException::class.java) {
            ShizukuBridgeDirectory.prepare(markerDir, ::validateDirectory, ::validateMarker)
        }
    }
}
