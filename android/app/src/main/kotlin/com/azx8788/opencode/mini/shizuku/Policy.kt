package com.azx8788.opencode.mini.shizuku

/** Risk is classification, not a shell sandbox. Unverified commands still ask. */
internal object CommandPolicy {
    enum class Risk { GREEN, BLUE, YELLOW, RED }

    data class Decision(val risk: Risk, val kind: String, val readOnly: Boolean = false)
    data class Admission(val automatic: Boolean, val allowDelaySeconds: Int)

    const val DIAGNOSTIC = "id; getprop ro.build.version.release"
    private val safeWord = Regex("[A-Za-z0-9_./:=,@%+~-]+")
    private val namespace = setOf("system", "secure", "global")
    private val packageLists = setOf("packages", "permissions", "libraries", "features", "users", "instrumentation")
    private val sensitivePath = Regex(
        "(?i)(^|/)(data|metadata|expand)(/|$)|" +
            "(^|/)(\\.env|\\.ssh|id_rsa|id_ed25519|credentials?)(/|$)|" +
            "(^|[./_-])(secret|token|password|api[_-]?key)([./_-]|$)|" +
            "^ro\\.(serialno|boot\\.)|^persist\\.",
    )

    fun admission(decision: Decision, directReadOnly: Boolean, advanced: Boolean, delaySeconds: Int): Admission =
        Admission(
            automatic = (directReadOnly && decision.readOnly) || (advanced && decision.risk != Risk.RED),
            allowDelaySeconds = if (advanced && decision.risk == Risk.RED) 3 else delaySeconds,
        )

    fun inspect(command: String): Decision {
        val normalized = command.trim()
        if (isSafeReadOnly(normalized)) return Decision(Risk.GREEN, "read_only", readOnly = true)

        val lower = normalized.lowercase()
        // These patterns improve warning labels; none of them grants execution.
        if (Regex("\\b(reboot|shutdown|halt|wipe|mkfs|dd)\\b").containsMatchIn(lower)) {
            return Decision(Risk.RED, "catastrophic_destructive_or_privilege")
        }
        if (Regex("\\b(rm|rmdir|shred|unlink|force-stop|disable|disable-user|uninstall|suspend|clear)\\b")
                .containsMatchIn(lower)) return Decision(Risk.RED, "delete_stop_or_remove")
        if (Regex("\\b(su|mount|umount|setenforce|chmod|chown|restorecon|magisk|setprop)\\b")
                .containsMatchIn(lower)) return Decision(Risk.RED, "privilege_escalation_or_system")

        val words = simpleWords(normalized) ?: return Decision(Risk.RED, "unverified_shell")
        val args = words.drop(1)
        if (sensitiveRead(words)) return Decision(Risk.RED, "sensitive_read")
        val write = when (words[0]) {
            "settings" -> (args.size == 4 && args[0] == "put" && args[1] in namespace) ||
                (args.size == 3 && args[0] == "delete" && args[1] in namespace)
            "appops" -> (args.size == 4 && args[0] == "set") ||
                (args.size in 2..3 && args[0] == "reset")
            "am" -> args.isNotEmpty() && args[0] in setOf("start", "startservice", "broadcast")
            "pm" -> args.isNotEmpty() && args[0] in setOf("install", "install-existing", "enable", "enable-user")
            "cmd" -> args.size >= 2 && args[0] == "package" &&
                args[1] in setOf("install-existing", "set-enabled-setting", "set-harmful-app-warning")
            else -> false
        }
        if (write) return Decision(Risk.YELLOW, "write_or_configuration")
        val lowImpact = when (words[0]) {
            "sleep" -> args.size == 1 && args[0].toLongOrNull()?.let { it in 0..120 } == true
            "echo" -> true
            "true", "false" -> args.isEmpty()
            else -> false
        }
        return if (lowImpact) Decision(Risk.BLUE, "low_impact") else Decision(Risk.RED, "unverified_shell")
    }

    /**
     * Direct reads are exact query forms, not matches for a word like `cat`
     * somewhere in a script. Arbitrary scripts and service-specific subcommands
     * remain available via explicit red confirmation (also in advanced mode).
     */
    fun isSafeReadOnly(command: String): Boolean {
        val normalized = command.trim()
        if (normalized == DIAGNOSTIC) return true // exactly these two fixed reads
        val words = simpleWords(normalized) ?: return false
        val args = words.drop(1)
        return when (words[0]) {
            "id", "whoami", "uname", "date", "uptime", "free", "df", "ps", "top", "mount" -> args.isEmpty()
            "getprop" -> args.size <= 1 && args.all { it.matches(Regex("[A-Za-z0-9_.-]+")) } &&
                args.none { sensitivePath.containsMatchIn(it) }
            "ls" -> args.all(::readArgument) && !sensitiveRead(words)
            "cat", "head", "tail", "du", "stat", "wc" -> args.isNotEmpty() && args.all(::readArgument) && !sensitiveRead(words)
            "grep" -> args.size >= 2 && args.all(::readArgument) && !sensitiveRead(words)
            // e.g. `dumpsys battery set level 1` can mutate service state.
            "dumpsys" -> args.size == 1 && (args[0] == "-l" || args[0].matches(Regex("[A-Za-z0-9_.-]+")))
            "settings" -> args.size == 3 && args[0] == "get" && args[1] in setOf("system", "global") &&
                readArgument(args[2]) && !sensitiveRead(words)
            "appops" -> args.size in 2..3 && args[0] == "get" && args.drop(1).all(::readArgument)
            "pm" -> packageQuery(args)
            "cmd" -> args.firstOrNull() == "package" && packageQuery(args.drop(1))
            else -> false
        }
    }

    private fun packageQuery(args: List<String>): Boolean = when (args.firstOrNull()) {
        "list" -> args.size in 2..5 && args[1] in packageLists && args.drop(2).all(::readArgument)
        "path", "dump" -> args.size == 2 && !args[1].startsWith("-") && readArgument(args[1])
        else -> false
    }

    private fun readArgument(value: String): Boolean =
        safeWord.matches(value) && !value.startsWith("--") && !value.startsWith("-exec")

    private fun sensitiveRead(words: List<String>): Boolean {
        if (words.firstOrNull() == "settings" && words.getOrNull(1) == "get" && words.getOrNull(2) == "secure") {
            return true
        }
        return words.drop(1).any(sensitivePath::containsMatchIn)
    }

    private fun simpleWords(command: String): List<String>? {
        // Splitting only ASCII spaces/tabs means a newline/control character,
        // expansion, glob, quote, redirect or operator fails safeWord validation.
        if (command.isEmpty() || command.length > 16 * 1024) return null
        val words = command.split(Regex("[ \\t]+"))
        return words.takeIf { it.isNotEmpty() && it.all(safeWord::matches) }
    }
}
