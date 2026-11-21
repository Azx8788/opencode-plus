package com.azx8788.opencode.mini

import org.junit.Assert.*
import org.junit.Test

class ShizukuCommandPolicyTest {
    @Test fun `fixed queries are direct reads including diagnostic`() {
        for (command in listOf("id", "getprop ro.build.version.release", "ls -la /sdcard", "cat /proc/version",
                "dumpsys battery", "pm list packages", "cmd package list packages", "settings get global airplane_mode_on",
                ShizukuCommandPolicy.DIAGNOSTIC)) {
            assertTrue(command, ShizukuCommandPolicy.isSafeReadOnly(command))
            assertEquals(command, ShizukuCommandPolicy.Risk.GREEN, ShizukuCommandPolicy.inspect(command).risk)
        }
    }

    @Test fun `read keywords do not bless mutating service subcommands or scripts`() {
        for (command in listOf("dumpsys battery set level 1", "dumpsys battery reset", "date 010112002026",
                "id; touch /sdcard/file", "cat /proc/version | sh", "ls $(touch /sdcard/file)", "cat `id`",
                "python -c 'print(1)'", "sh -c id", "./script", "echo read\nrm file", "find / -exec rm file +")) {
            assertFalse(command, ShizukuCommandPolicy.isSafeReadOnly(command))
            assertEquals(command, ShizukuCommandPolicy.Risk.RED, ShizukuCommandPolicy.inspect(command).risk)
        }
    }

    @Test fun `sensitive reads are never direct or advanced-auto`() {
        for (command in listOf("cat /data/system/users/0/settings_ssaid.xml", "cat /sdcard/.env",
                "cat /home/oc/.ssh/id_rsa", "cat /proc/self/environ", "cat /proc/123/cmdline",
                "cat /proc/1/mem", "getprop ro.serialno", "settings get secure android_id")) {
            val decision = ShizukuCommandPolicy.inspect(command)
            assertFalse(command, decision.readOnly)
            assertEquals(command, ShizukuCommandPolicy.Risk.RED, decision.risk)
            assertFalse(command, ShizukuCommandPolicy.admission(decision, true, true, 10).automatic)
        }
    }

    @Test fun `settings delete is yellow while setprop remains red`() {
        assertEquals(ShizukuCommandPolicy.Risk.YELLOW,
            ShizukuCommandPolicy.inspect("settings delete global test_key").risk)
        assertEquals(ShizukuCommandPolicy.Risk.RED,
            ShizukuCommandPolicy.inspect("setprop ro.debuggable 1").risk)
    }

    @Test fun `ordinary mode auto runs reads only when enabled`() {
        for (command in listOf("id", "echo ok", "settings put global airplane_mode_on 1", "rm file")) {
            val decision = ShizukuCommandPolicy.inspect(command)
            val admitted = ShizukuCommandPolicy.admission(decision, true, false, 10)
            assertEquals(command, decision.readOnly, admitted.automatic)
            assertFalse(ShizukuCommandPolicy.admission(decision, false, false, 10).automatic)
        }
    }

    @Test fun `advanced mode auto runs reviewed green blue yellow but never red`() {
        for (command in listOf("id", "sleep 10", "settings put global airplane_mode_on 1", "appops set com.example CAMERA allow")) {
            val decision = ShizukuCommandPolicy.inspect(command)
            assertTrue(command, ShizukuCommandPolicy.admission(decision, false, true, 10).automatic)
        }
        for (command in listOf("rm file", "am force-stop com.example", "su -c id", "sh -c id", "echo ok > file", "unknown-command")) {
            val admission = ShizukuCommandPolicy.admission(ShizukuCommandPolicy.inspect(command), true, true, 10)
            assertFalse(command, admission.automatic)
            assertEquals(command, 3, admission.allowDelaySeconds)
        }
    }
}
