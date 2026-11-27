package org.levarac.beid.persistence

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import java.io.File
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertSame
import kotlin.test.assertTrue

/**
 * beid#722 item 5: the Sigil presence file is on this device only.
 *
 * The mechanism is the location, not a backup rule: `Context.noBackupFilesDir`
 * is excluded from Auto Backup and from device-to-device transfer on every
 * API level this app supports (minSdk 26), and "always excluded even if you
 * try to include them" (developer.android.com/identity/data/autobackup).
 * Every other store lives under `filesDir`, which IS backed up; this test
 * fails if the presence file ever moves there.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class SigilPresenceStoreBackupExclusionTest {
    private val context: Context = ApplicationProvider.getApplicationContext()

    @Test
    fun theDeviceStoreIsOneInstancePerProcess() {
        assertSame(SigilPresenceStore.forDevice(context), SigilPresenceStore.forDevice(context))
    }

    @Test
    fun theDeviceStoreLivesUnderNoBackupFilesDirAndNotUnderFilesDir() {
        val file = SigilPresenceStore.forDevice(context).file.canonicalFile
        val noBackup = context.noBackupFilesDir.canonicalFile
        val files = context.filesDir.canonicalFile
        assertNotEquals(noBackup, files)
        assertTrue(file.toPath().startsWith(noBackup.toPath()), "$file is not under $noBackup")
        assertFalse(file.toPath().startsWith(files.toPath()), "$file is under the backed-up $files")
        assertEquals(SigilPresenceStore.defaultFile(context.noBackupFilesDir).canonicalFile, file)
    }

    @Test
    fun theProductionCoordinatorTakesTheDeviceStoreAndNoOtherConstructionExists() {
        // The production `EventJoinCoordinator(context)` cannot be built in a
        // JVM test (it constructs a real BarnardEngine), so its one wiring line
        // is pinned by source: it must use `forDevice`, and no main-source file
        // other than the store itself may construct a store at another path.
        val root = File("src/main/kotlin")
        val coordinator = root.resolve("org/levarac/beid/sensing/EventJoinCoordinator.kt").readText()
        val productionConstructor = coordinator.substringAfter("constructor(context: Context) : this(")
            .substringBefore("\n    )")
        assertTrue(
            productionConstructor.contains("sigilPresenceStore = SigilPresenceStore.forDevice(context)"),
            "the production constructor must wire the noBackupFilesDir store",
        )
        val constructions = root.walkTopDown().filter { it.isFile && it.extension == "kt" }
            .filter { it.name != "SigilPresenceStore.kt" }
            .filter { Regex("""SigilPresenceStore\(""").containsMatchIn(it.readText()) }
            .map { it.name }
            .toList()
        assertEquals(emptyList(), constructions, "a store must only be made through forDevice")
    }
}
