import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/domain/shizuku_receipt.dart';

void main() {
  test('only explicit native refusal is labelled as user denial', () {
    for (final entry in const {
      'confirmation_user_denied': ShizukuReceiptKind.userDenied,
      'confirmation_timeout': ShizukuReceiptKind.confirmationTimedOut,
      'confirmation_denied_or_timeout': ShizukuReceiptKind.notExecuted,
      'overlay_permission_missing': ShizukuReceiptKind.notExecuted,
      'confirmation_unavailable': ShizukuReceiptKind.notExecuted,
      'busy': ShizukuReceiptKind.notExecuted,
    }.entries) {
      expect(
        ShizukuReceipt.fromMap({
          'state': 'denied',
          'reason': entry.key,
          'executionStage': 'not_dispatched',
        })?.kind,
        entry.value,
      );
    }
  });

  test(
    'unknown outcomes cannot be guessed from a previous progress update',
    () {
      final receipt = ShizukuReceipt.forTool(
        'shizuku_exec',
        output: 'Tool execution interrupted',
        metadata: const {
          'android': {
            'operationId': 'original-operation',
            'state': 'waiting',
            'executionStage': 'not_dispatched',
          },
        },
        inFlight: false,
      );
      expect(receipt?.kind, ShizukuReceiptKind.unconfirmed);
      expect(receipt?.operationId, 'original-operation');
      expect(
        ShizukuReceipt.forTool('shizuku_exec', inFlight: false)?.kind,
        ShizukuReceiptKind.unconfirmed,
      );
    },
  );

  test('final Android receipt beats stale live metadata', () {
    final receipt = ShizukuReceipt.forTool(
      'shizuku_exec',
      output: jsonEncode({
        'protocolVersion': 1,
        'environment': 'android',
        'state': 'denied',
        'reason': 'confirmation_user_denied',
        'operationId': 'original-operation',
        'executionStage': 'not_dispatched',
      }),
      metadata: const {
        'android': {'state': 'waiting'},
      },
      inFlight: false,
    );
    expect(receipt?.kind, ShizukuReceiptKind.userDenied);
  });

  test('JSON success with empty stdout and stderr is still a result', () {
    expect(
      ShizukuReceipt.forTool(
        'shizuku_exec',
        output: const {
          'protocolVersion': 1,
          'environment': 'android',
          'state': 'succeeded',
          'stdout': '',
          'stderr': '',
          'exitCode': 0,
        },
        inFlight: false,
      )?.kind,
      ShizukuReceiptKind.succeeded,
    );
  });

  test('contradictory receipts do not prove refusal or success', () {
    for (final value in const [
      {
        'state': 'denied',
        'reason': 'confirmation_user_denied',
        'executionStage': 'dispatched',
      },
      {'state': 'succeeded', 'exitCode': 1},
    ]) {
      expect(
        ShizukuReceipt.fromMap(value)?.kind,
        ShizukuReceiptKind.unconfirmed,
      );
    }
  });

  test('cancellation before start is distinct from command termination', () {
    expect(
      ShizukuReceipt.fromMap({
        'state': 'cancelled',
        'reason': 'cancelled_before_dispatch',
      })?.kind,
      ShizukuReceiptKind.cancelledBeforeStart,
    );
    expect(
      ShizukuReceipt.fromMap({'state': 'cancelled', 'reason': 'cancelled'})
          ?.kind,
      ShizukuReceiptKind.cancelled,
    );
  });

  test(
    'Core rejection of result inspection cannot imply the command did not run',
    () {
      expect(
        ShizukuReceipt.forTool(
          'shizuku_result',
          inFlight: false,
          declined: true,
        ),
        isNull,
      );
      expect(ShizukuReceipt.forTool('shell', inFlight: false), isNull);
    },
  );
}
