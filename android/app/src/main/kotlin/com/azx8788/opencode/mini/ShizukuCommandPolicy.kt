package com.azx8788.opencode.mini

/** Classifies for presentation; only the narrow grammar below is direct-read eligible. */
internal object ShizukuCommandPolicy {
    enum class Risk { GREEN, BLUE, YELLOW, RED }

    data class Decision(
        val risk: Risk,
        val kind: String,
        val readOnly: Boolean,
    )

    // Shell operators, substitutions, quotes, globs, escapes and control chars
    // are not accepted in the direct-read path. They remain eligible for an
    // explicit overlay confirmation as arbitrary shell commands.
    private val shellSyntax = Regex("[;&|<>`$(){}\\[\\]\\\\\\n\\r\"']")
    private val safeWord = Regex("[A-Za-z0-9_./:=,@%+~-]+")

    fun inspect(command: String): Decision {
        val lower = command.lowercase()
        val catastrophic = Regex(
            "\\b(rm\\s+(-[a-z]*r[a-z]*\\s+)?/(\\s|$)|" +
                "dd\\s+if=.*of=/dev/(block|mmc)|mkfs\\.\\w+|wipe|format\\s+/dev/|" +
                "(reboot|shutdown|halt)\\b|setenforce\\s+0|\\b(su|sh)\\s+-c\\b)",
        )
        val destructive = Regex(
            "\\b(rm|rmdir|shred|unlink)\\b|" +
                "(force-stop|disable|disable-user|uninstall|suspend|clear)\\b|" +
                "\\b(pm\\s+(clear|uninstall|disable))\\b",
        )
        val privilege = Regex(
            "\\b(su|mount|umount|setenforce|setprop\\s+persist\\.|" +
                "chmod|chown|restorecon|magisk)\\b",
        )
        val write = Regex(
            "\\b(settings\\s+(put|delete|secure|global|system))\\b|" +
                "\\b(appops\\s+(set|reset))\\b|" +
                "\\b(install|push|pull|am\\s+(start|broadcast|force-stop))\\b|" +
                "\\b(cmd\\s+(notification|activity|package))\\b|[>]|\\|(te|tee)|>>",
        )
        val read = Regex(
            "\\b(id|whoami|getprop|dumpsys|pm\\s+(list|dump|path)|" +
                "ls|cat|head|tail|grep|find|du|df|ps|top|settings\\s+get|" +
                "appops\\s+get|cmd\\s+statusbar)\\b",
        )

        val risk = when {
            catastrophic.containsMatchIn(lower) || destructive.containsMatchIn(lower) ||
                privilege.containsMatchIn(lower) -> Risk.RED
            write.containsMatchIn(lower) -> Risk.YELLOW
            isSafeReadOnly(command) -> Risk.GREEN
            read.containsMatchIn(lower) -> Risk.GREEN
            else -> Risk.BLUE
        }
        val kind = when (risk) {
            Risk.RED -> when {
                catastrophic.containsMatchIn(lower) -> "catastrophic_destructive_or_privilege"
                privilege.containsMatchIn(lower) -> "privilege_escalation_or_system"
                else -> "delete_stop_or_remove"
            }
            Risk.YELLOW -> "write_or_configuration"
            Risk.GREEN -> "read_only"
            Risk.BLUE -> "unrecognized_shell"
        }
        return Decision(risk, kind, isSafeReadOnly(command))
    }

    /**
     * Conservative direct-read grammar. It intentionally recognizes only a
     * fixed set of query forms and simple tokens, never shell composition.
     * Everything else can still run after the normal warning overlay.
     */
    fun isSafeReadOnly(command: String): Boolean {
        val normalized = command.trim()
        if (normalized.isEmpty() || normalized.length > 16 * 1024 || shellSyntax.containsMatchIn(normalized)) return false

        // The settings diagnostics contain exactly two known read-only calls.
        if (normalized == "id; getprop ro.build.version.release") return true

        val words = normalized.split(Regex("\\s+")).filter(String::isNotEmpty)
        if (words.isEmpty() || words.any { !safeWord.matches(it) }) return false
        val commandName = words[0]
        val args = words.drop(1)
        return when (commandName) {
            "id", "whoami", "uname", "date", "uptime", "free", "df", "ps", "top", "mount" -> args.isEmpty()
            "getprop" -> args.size <= 1 && args.all { it.matches(Regex("[A-Za-z0-9_.-]+")) }
            "ls", "cat", "head", "tail", "du", "stat", "wc" -> args.isNotEmpty() && args.all(::safeReadArgument)
            "grep" -> args.size >= 2 && args.none { it == "-exec" || it.startsWith("--") } && args.all(::safeReadArgument)
            "dumpsys" -> args.size in 1..3 && args.all(::safeReadArgument)
            "settings" -> args.size == 3 && args[0] == "get" &&
                args[1] in setOf("system", "secure", "global") && safeReadArgument(args[2])
            "appops" -> args.size in 2..3 && args[0] == "get" && args.drop(1).all(::safeReadArgument)
            "pm" -> args.size in 1..4 && when (args[0]) {
                "list" -> args.drop(1).all(::safeReadArgument)
                "path" -> args.size == 2 && safeReadArgument(args[1])
                "dump" -> args.size == 2 && safeReadArgument(args[1])
                else -> false
            }
            "cmd" -> args.size in 2..4 && args[0] == "package" && args[1] == "list" && args.drop(2).all(::safeReadArgument)
            else -> false
        }
    }

    private fun safeReadArgument(value: String): Boolean =
        safeWord.matches(value) && !value.startsWith("-exec") && !value.startsWith("--")
}
