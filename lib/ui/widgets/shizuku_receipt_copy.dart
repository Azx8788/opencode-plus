import '../../domain/shizuku_receipt.dart';
import '../../l10n/app_localizations.dart';

/// A result sentence for chat and the native settings diagnostics. For a
/// normal success or live command, keep the usual status and output instead.
String? shizukuReceiptCopy(ShizukuReceipt receipt, AppLocalizations l10n) =>
    switch (receipt.kind) {
      ShizukuReceiptKind.userDenied => l10n.shizukuReceiptUserDenied,
      ShizukuReceiptKind.confirmationTimedOut => l10n.shizukuReceiptTimedOut,
      ShizukuReceiptKind.notExecuted => l10n.shizukuReceiptNotExecuted,
      ShizukuReceiptKind.cancelledBeforeStart =>
        l10n.shizukuReceiptCancelledBeforeStart,
      ShizukuReceiptKind.cancelled => l10n.shizukuReceiptCancelled,
      ShizukuReceiptKind.failed => [
        l10n.shizukuReceiptFailed,
        if (receipt.exitCode case final code?) l10n.workExitCode(code),
      ].join(' '),
      ShizukuReceiptKind.unconfirmed => l10n.shizukuReceiptUnconfirmed,
      _ => null,
    };
