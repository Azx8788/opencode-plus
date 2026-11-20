package com.azx8788.opencode.mini.shizuku

import org.junit.Assert.*
import org.junit.Test

class CommandPolicyTest {
    @Test fun `fixed queries are direct reads including diagnostic`() {
        for (command in listOf("id", "getprop ro.build.version.release", "ls -la /sdcard", "cat /proc/version",
                "dumpsys battery", "pm list packages", "cmd package list packages", "settings get global airplane_mode_on",
                CommandPolicy.DIAGNOSTIC)) {
            assertTrue(command, CommandPolicy.isSafeReadOnly(command))
            assertEquals(command, CommandPolicy.Risk.GREEN, CommandPolicy.inspect(command).risk)
        }
    }

    @Test fun `read keywords do not bless mutating service subcommands or scripts`() {
        for (command in listOf("dumpsys battery set level 1", "dumpsys battery reset", "date 010112002026",
                "id; touch /sdcard/file", "cat /proc/version | sh", "ls $(touch /sdcard/file)", "cat `id`",
                "python -c 'print(1)'", "sh -c id", "./script", "echo read\nrm file", "find / -exec rm file +")) {
            assertFalse(command, CommandPolicy.isSafeReadOnly(command))
            assertEquals(command, CommandPolicy.Risk.RED, CommandPolicy.inspect(command).risk)
        }
    }

    @Test fun `sensitive reads are never direct or advanced-auto`() {
        for (command in listOf("cat /data/system/users/0/settings_ssaid.xml", "cat /sdcard/.env",
                "cat /home/oc/.ssh/id_rsa", "getprop ro.serialno", "settings get secure android_id")) {
            val decision = CommandPolicy.inspect(command)
            assertFalse(command, decision.readOnly)
            assertEquals(command, CommandPolicy.Risk.RED, decision.risk)
            assertFalse(command, CommandPolicy.admission(decision, true, true, 10).automatic)
        }
    }

    @Test fun `settings delete is yellow while setprop remains red`() {
        assertEquals(CommandPolicy.Risk.YELLOW,
            CommandPolicy.inspect("settings delete global test_key").risk)
        assertEquals(CommandPolicy.Risk.RED,
            CommandPolicy.inspect("setprop ro.debuggable 1").risk)
    }

    @Test fun `ordinary mode auto runs reads only when enabled`() {
        for (command in listOf("id", "echo ok", "settings put global airplane_mode_on 1", "rm file")) {
            val decision = CommandPolicy.inspect(command)
            val admitted = CommandPolicy.admission(decision, true, false, 10)
            assertEquals(command, decision.readOnly, admitted.automatic)
            assertFalse(CommandPolicy.admission(decision, false, false, 10).automatic)
        }
    }

    @Test fun `advanced mode auto runs reviewed green blue yellow but never red`() {
        for (command in listOf("id", "sleep 10", "settings put global airplane_mode_on 1", "appops set com.example CAMERA allow")) {
            val decision = CommandPolicy.inspect(command)
            assertTrue(command, CommandPolicy.admission(decision, false, true, 10).automatic)
        }
        for (command in listOf("rm file", "am force-stop com.example", "su -c id", "sh -c id", "echo ok > file", "unknown-command")) {
            val admission = CommandPolicy.admission(CommandPolicy.inspect(command), true, true, 10)
            assertFalse(command, admission.automatic)
            assertEquals(command, 3, admission.allowDelaySeconds)
        }
    }
}
