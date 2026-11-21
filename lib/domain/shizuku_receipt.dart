import 'dart:convert';

/// The Android command outcome, not the status of the enclosing AI tool call.
enum ShizukuReceiptKind {
  pending,
  waiting,
  running,
  succeeded,
  userDenied,
  confirmationTimedOut,
  notExecuted,
  cancelledBeforeStart,
  cancelled,
  failed,
  unconfirmed,
}

class ShizukuReceipt {
  const ShizukuReceipt(this.kind, {this.operationId, this.exitCode});

  final ShizukuReceiptKind kind;
  final String? operationId;
  final int? exitCode;

  static bool handlesTool(String name) =>
      name == 'shizuku_exec' || name == 'shizuku_result';

  static final _id = RegExp(r'^[A-Za-z0-9_-]{1,80}$');

  static ShizukuReceipt? fromMap(Object? value) {
    if (value is! Map) return null;
    final id = value['operationId'];
    final exit = value['exitCode'];
    final kind = _kind(value);
    if (kind == null) return null;
    return ShizukuReceipt(
      kind,
      operationId: id is String && _id.hasMatch(id) ? id : null,
      exitCode: exit is int ? exit : null,
    );
  }

  static ShizukuReceiptKind? _kind(Map value) {
    // A contradictory receipt must not claim either consent or no execution.
    if (value['executionStage'] == 'dispatched' &&
        (value['state'] == 'denied' || value['state'] == 'not_executed')) {
      return ShizukuReceiptKind.unconfirmed;
    }
    if (value['state'] == 'succeeded' &&
        value['exitCode'] != null &&
        value['exitCode'] != 0) {
      return ShizukuReceiptKind.unconfirmed;
    }
    if (value['executionStage'] == 'dispatched' &&
        value['state'] == 'cancelled' &&
        const {
          'cancelled_before_admission',
          'cancelled_before_dispatch',
          'interrupted_before_dispatch',
        }.contains(value['reason'])) {
      return ShizukuReceiptKind.unconfirmed;
    }
    return switch ((value['state'], value['reason'])) {
      ('queued', _) => ShizukuReceiptKind.pending,
      ('waiting', _) => ShizukuReceiptKind.waiting,
      ('running', _) => ShizukuReceiptKind.running,
      ('succeeded', _) => ShizukuReceiptKind.succeeded,
      ('denied', 'confirmation_user_denied') => ShizukuReceiptKind.userDenied,
      ('denied', 'confirmation_timeout') =>
        ShizukuReceiptKind.confirmationTimedOut,
      ('denied' || 'not_executed', _) => ShizukuReceiptKind.notExecuted,
      (
        'cancelled',
        'cancelled_before_admission' ||
            'cancelled_before_dispatch' ||
            'cancelled_before_start' ||
            'interrupted_before_dispatch',
      ) =>
        ShizukuReceiptKind.cancelledBeforeStart,
      ('cancelled', _) => ShizukuReceiptKind.cancelled,
      ('failed', 'process_start_failed') => ShizukuReceiptKind.notExecuted,
      ('failed', _) => ShizukuReceiptKind.failed,
      ('unknown', _) => ShizukuReceiptKind.unconfirmed,
      _ => null,
    };
  }

  /// Only an Android receipt can establish the command outcome. The enclosing
  /// tool's `executed` flag and the last progress update do not prove it.
  static ShizukuReceipt? forTool(
    String name, {
    Object? output,
    Object? metadata,
    required bool inFlight,
    bool declined = false,
  }) {
    if (!handlesTool(name) || declined) return null;
    Object? decoded = output;
    if (output is String && output.length <= 786432) {
      try {
        decoded = jsonDecode(output);
      } on FormatException {
        decoded = null;
      }
    }
    ShizukuReceipt? receipt;
    if (decoded is Map &&
        decoded['protocolVersion'] == 1 &&
        decoded['environment'] == 'android') {
      receipt = fromMap(decoded);
    }
    if (receipt == null && metadata is Map) {
      receipt = fromMap(metadata['android']);
    }
    if (!inFlight && (receipt == null || receipt.isLive)) {
      return ShizukuReceipt(
        ShizukuReceiptKind.unconfirmed,
        operationId: receipt?.operationId,
      );
    }
    return receipt;
  }

  bool get isLive =>
      kind == ShizukuReceiptKind.pending ||
      kind == ShizukuReceiptKind.waiting ||
      kind == ShizukuReceiptKind.running;
}
