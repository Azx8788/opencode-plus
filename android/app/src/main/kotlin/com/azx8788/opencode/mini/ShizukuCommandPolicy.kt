package com.azx8788.opencode.mini

/**
 * Every command reaches the user. The policy only decides the colour and how
 * long the "Allow" button stays disabled so a tap is deliberate, not a reflex.
 *
 * Risk → colour → delay:
 *   GREEN  → read-only / identity        → 10s
 *   BLUE   → informational / low impact   → 10s
 *   YELLOW → write / config / app control → 10s
 *   RED    → destructive / privilege      → 10s
 *
 * No command is silently allowed. No command is silently blocked: even a RED
 * command shows the overlay with full text so the person sees what was
 * requested and why it is dangerous, then chooses.
 */
internal object ShizukuCommandPolicy {
    enum class Risk { GREEN, BLUE, YELLOW, RED }

    data class Decision(
        val risk: Risk,
        val kind: String,
        /** Seconds the Allow button waits before becoming tappable. */
        val allowDelaySeconds: Int = 10,
    )

    fun inspect(command: String): Decision {
        val lc = command.lowercase()

        // Catastrophic patterns: still shown, never auto-run.
        val catastrophic = Regex(
            "\\b(rm\\s+(-[a-z]*r[a-z]*\\s+)?/(\\s|$)|" +
            "dd\\s+if=.*of=/dev/(block|mmc)|" +
            "mkfs\\.\\w+|wipe|format\\s+/dev/|" +
            "(reboot|shutdown|halt)\\b|" +
            "setenforce\\s+0|" +
            "\\b(su|sh)\\s+-c\\b)"
        )

        val destructive = Regex(
            "\\b(rm|rmdir|shred|unlink)\\b|" +
            "(force-stop|disable|disable-user|uninstall|suspend|clear)\\b|" +
            "\\b(pm\\s+(clear|uninstall|disable))\\b"
        )

        val privilege = Regex(
            "\\b(su|mount|umount|setenforce|setprop\\s+persist\\.|" +
            "chmod|chown|restorecon|magisk)\\b"
        )

        val write = Regex(
            "\\b(settings\\s+(put|delete|secure|global|system))\\b|" +
            "\\b(appops\\s+(set|reset))\\b|" +
            "\\b(install|push|pull|am\\s+(start|broadcast|force-stop))\\b|" +
            "\\b(cmd\\s+(notification|activity|package))\\b|" +
            "[>]|\\|(te|tee)|>>"
        )

        val read = Regex(
            "\\b(id|whoami|getprop|dumpsys|pm\\s+(list|dump|path)|" +
            "ls|cat|head|tail|grep|find|du|df|ps|top|" +
            "settings\\s+get|appops\\s+get|cmd\\s+statusbar)\\b"
        )

        val risk = when {
            catastrophic.containsMatchIn(lc) -> Risk.RED
            destructive.containsMatchIn(lc) -> Risk.RED
            privilege.containsMatchIn(lc) -> Risk.RED
            write.containsMatchIn(lc) -> Risk.YELLOW
            read.containsMatchIn(lc) -> Risk.GREEN
            else -> Risk.BLUE
        }

        val kind = when {
            catastrophic.containsMatchIn(lc) -> "catastrophic_destructive_or_privilege"
            destructive.containsMatchIn(lc) -> "delete_stop_or_remove"
            privilege.containsMatchIn(lc) -> "privilege_escalation_or_system"
            write.containsMatchIn(lc) -> "write_or_configuration"
            read.containsMatchIn(lc) -> "read_only"
            else -> "unrecognized_shell"
        }

        // Unified 10-second delay for every command regardless of risk.
        return Decision(risk, kind, 10)
    }
}
