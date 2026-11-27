/// OpenCode 2 implementation of the protocol-neutral [ServerGateway]: the
/// live transport surface (sessions, messages, prompting, permissions,
/// providers, files, events) built on the typed v2 client in this package.
///
/// Operations beyond the live transport live in
/// `gateway_operations.dart` ([Api2OperationsGateway]).
library;

import 'dart:convert';

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../domain/models.dart';
import '../domain/long_term_memory.dart';
import '../domain/command_receipts.dart' show createCommandReceiptID;
import 'memory.dart';
import '../domain/server_gateway.dart';
import '../domain/parallel_requests.dart';
import '../domain/remote_shell.dart';
import 'client.dart';
import 'gen_ui_history.dart';
import 'gateway_events.dart';
import 'gateway_mappers.dart';
import 'models.dart';
import 'transport.dart';
import 'session_permission_policy.dart';
import 'shell_runner.dart';
import '../diagnostics/perf_trace.dart';

/// The OpenCode 2 side of the domain gateway.
///
/// Failures surface as the same [ApiException]/[ProductException] types the
/// domain expects, so existing error handling keeps working. Where the
/// server has no equivalent endpoint the method returns an inert empty
/// result or throws a typed [ProductException], and the matching
/// [ServerCapabilities] flag is false (see [api2ServerCapabilities]).
class Api2Gateway
    with Api2GenUiHistory
    implements
        ServerGateway,
        SessionSelectionGateway,
        WebSearchGateway,
        RemoteShellGateway,
        CorrelatedPromptGateway {
  final Api2Client client;

  /// Admission fence shared with the phone engine's chat path. A settled
  /// request is not proof of idle: transport failure may follow acceptance.
  Future<void> Function(String sessionID)? beforeSessionDispatch;
  void Function(String sessionID)? sessionDispatchSettled;
  Future<MemoryPromptContext?> Function(String sessionID)? memoryContext;
  Future<Map<String, dynamic>?> Function(
    String sessionID,
    String text,
    PromptDelivery? delivery,
  )?
  taskMetadata;
  void Function(
    String sessionID,
    Api2InboxItem receipt,
    Map<String, dynamic> metadata,
  )?
  onTaskPromptAccepted;
  Future<void> Function()? refreshTaskTrace;
  List<MessageWithParts> Function(List<MessageWithParts> messages)?
  recordedTiming;

  /// Notifies the app of a prompt this gateway actually accepted for dispatch.
  /// Called only for OpenCode 2 sends, with the model the caller selected;
  /// no prompt text or attachment is ever reported.
  void Function(
    String sessionID,
    ModelRef? model,
    String? agent,
    String? variant,
  )?
  onPromptDispatched;

  /// Whether the person approves [sessionID] automatically. Such a session
  /// keeps the server's own rules, so its tools never wait for this phone.
  bool Function(String sessionID)? serverRunsTools;

  Future<void> _dispatch(
    String sessionID,
    Future<void> Function() send, {
    PromptCancellation? cancel,
  }) async {
    // Before the fence: a send stopped while it waited for the connection
    // must not touch the session's admission state at all.
    cancel?.throwIfCancelled();
    await beforeSessionDispatch?.call(sessionID);
    cancel?.throwIfCancelled();
    try {
      await send();
    } finally {
      sessionDispatchSettled?.call(sessionID);
    }
  }

  Api2Gateway({required this.client});

  Api2Gateway.connect({
    required String baseUrl,
    required String password,
    String? cleartextConfirmedOrigin,
    String? certificatePinSha256,
    String? directory,
    String? workspace,
  }) : client = Api2Client.connect(
         baseUrl: baseUrl,
         password: password,
         cleartextConfirmedOrigin: cleartextConfirmedOrigin,
         certificatePinSha256: certificatePinSha256,
         directory: directory,
         workspace: workspace,
       );

  @override
  Api2Transport get transport => client.transport;

  @override
  ServerCapabilities get capabilities => api2ServerCapabilities;

  /// `POST /api/shell` for the Git page ([ServerCapabilities.remoteShell]).
  @override
  Future<RemoteShellResult> runShellCommand(
    String command, {
    String? directory,
    required Duration timeout,
  }) => Api2ShellRunner(
    client,
  ).runShellCommand(command, directory: directory, timeout: timeout);

  @override
  String? get directory => client.directory;

  @override
  String? get workspace => client.workspace;

  @override
  bool get isClosed => transport.isClosed;

  @override
  void setLocation({String? directory, String? workspace}) =>
      client.setLocation(directory: directory, workspace: workspace);

  @override
  void close() => client.close();

  Future<T> _run<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on Api2Error catch (error) {
      throw mapApi2Error(error);
    }
  }

  Map<String, dynamic> _loc([Map<String, dynamic> extra = const {}]) => {
    if (client.directory != null) 'location[directory]': client.directory,
    if (client.workspace != null) 'location[workspace]': client.workspace,
    ...extra,
  };

  // Pinned beta-18600 /api/websearch: one request, no pagination contract.
  Future<T> _webSearchRun<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on WebSearchFailure {
      rethrow;
    } on Api2Error catch (error) {
      throw WebSearchFailure(switch (error.statusCode) {
        401 || 403 => WebSearchFailureKind.authentication,
        404 || 503 => WebSearchFailureKind.unavailable,
        _ => WebSearchFailureKind.failed,
      });
    } catch (_) {
      throw const WebSearchFailure(WebSearchFailureKind.invalidResponse);
    }
  }

  void _validateWebSearchLocation(
    dynamic json,
    String? directory,
    String? workspace,
  ) {
    final location = json is Map ? json['location'] : null;
    if (location is! Map ||
        location['directory'] is! String ||
        (location['directory'] as String).isEmpty ||
        (directory != null && location['directory'] != directory) ||
        (workspace != null && location['workspaceID'] != workspace) ||
        client.directory != directory ||
        client.workspace != workspace) {
      throw const WebSearchFailure(WebSearchFailureKind.invalidResponse);
    }
  }

  @override
  Future<List<WebSearchProvider>> webSearchProviders() => _webSearchRun(
    () async {
      final directory = client.directory;
      final workspace = client.workspace;
      final json = await transport.getJson(
        '/websearch/provider',
        query: _loc(),
        receiveTimeout: const Duration(seconds: 15),
      );
      _validateWebSearchLocation(json, directory, workspace);
      final data = json is Map ? json['data'] : null;
      if (data is! List || data.length > 100) {
        throw const WebSearchFailure(WebSearchFailureKind.invalidResponse);
      }
      final seen = <String>{};
      return List.unmodifiable(
        data.map((item) {
          if (item is! Map ||
              item['id'] is! String ||
              item['name'] is! String) {
            throw const WebSearchFailure(WebSearchFailureKind.invalidResponse);
          }
          final id = item['id'] as String;
          final name = item['name'] as String;
          if (id.trim().isEmpty ||
              id.length > 200 ||
              name.trim().isEmpty ||
              name.length > 200 ||
              !seen.add(id) ||
              RegExp(r'[\x00-\x1f\x7f]').hasMatch(id + name)) {
            throw const WebSearchFailure(WebSearchFailureKind.invalidResponse);
          }
          return WebSearchProvider(id: id, name: name);
        }),
      );
    },
  );

  @override
  Future<WebSearchResponse> searchWeb(
    String query, {
    required String providerID,
  }) => _webSearchRun(() async {
    if (query.trim().isEmpty ||
        query.length > 1000 ||
        providerID.isEmpty ||
        providerID.length > 200) {
      throw const WebSearchFailure(WebSearchFailureKind.failed);
    }
    final directory = client.directory;
    final workspace = client.workspace;
    final json = await transport.postJson(
      '/websearch',
      query: _loc(),
      body: {'query': query.trim(), 'providerID': providerID},
      receiveTimeout: const Duration(seconds: 30),
    );
    _validateWebSearchLocation(json, directory, workspace);
    final data = json is Map ? json['data'] : null;
    if (data is! Map ||
        data['providerID'] != providerID ||
        data['results'] is! List ||
        (data['results'] as List).length > 100) {
      throw const WebSearchFailure(WebSearchFailureKind.invalidResponse);
    }
    final results = <WebSearchResult>[];
    for (final item in data['results'] as List) {
      if (item is! Map ||
          item['url'] is! String ||
          item['time'] is! Map ||
          (item['title'] != null && item['title'] is! String) ||
          (item['content'] != null && item['content'] is! String)) {
        throw const WebSearchFailure(WebSearchFailureKind.invalidResponse);
      }
      if ((item['url'] as String).length > 8192 ||
          ((item['title'] as String?)?.length ?? 0) > 10000 ||
          ((item['content'] as String?)?.length ?? 0) > 100000) {
        throw const WebSearchFailure(WebSearchFailureKind.invalidResponse);
      }
      final published = (item['time'] as Map)['published'];
      if (published != null && (published is! num || !published.isFinite)) {
        throw const WebSearchFailure(WebSearchFailureKind.invalidResponse);
      }
      results.add(
        WebSearchResult(
          url: item['url'] as String,
          title: item['title'] as String?,
          content: item['content'] as String?,
        ),
      );
    }
    return WebSearchResponse(
      providerID: providerID,
      results: List.unmodifiable(results),
    );
  });

  // ---------------- Health ----------------

  @override
  Future<Health> health() =>
      _run(() async => mapApi2Health(await client.health()));

  // ---------------- Sessions ----------------

  @override
  Future<List<Session>> sessions() async => (await sessionPage()).items;

  @override
  Future<ServerPage<Session>> sessionPage({String? cursor, int limit = 100}) =>
      _run(() async {
        final page = await client.sessions(
          limit: limit,
          order: 'desc',
          cursor: cursor,
        );
        return ServerPage(
          items: page.data.map(mapApi2Session).toList(),
          nextCursor: page.nextCursor?.isNotEmpty == true
              ? page.nextCursor
              : null,
        );
      });

  @override
  Future<Session> createSession() =>
      _run(() async => mapApi2Session(await client.createSession()));

  @override
  Future<Session> createSelectedSession(SessionSelection defaults) => _run(
    () async => mapApi2Session(
      await client.createSession(
        model: defaults.model == null
            ? null
            : Api2ModelRef(
                id: defaults.model!.normalized.modelID,
                providerID: defaults.model!.providerID,
                variant: defaults.variant.isEmpty ? null : defaults.variant,
              ),
        agent: defaults.agent?.isNotEmpty == true ? defaults.agent : null,
      ),
    ),
  );

  @override
  Future<void> setSessionModel(
    String sessionID,
    ModelRef model,
    String variant,
  ) => _run(
    () => client.switchModel(
      sessionID,
      Api2ModelRef(
        id: model.normalized.modelID,
        providerID: model.providerID,
        variant: variant.isEmpty ? null : variant,
      ),
    ),
  );

  @override
  Future<void> setSessionAgent(String sessionID, String agent) =>
      _run(() => client.switchAgent(sessionID, agent));

  @override
  Future<void> deleteSession(String id) => _run(() => client.deleteSession(id));

  @override
  Future<void> renameSession(String id, String title) =>
      _run(() => client.renameSession(id, title));

  @override
  Future<Session> session(String id) =>
      _run(() async => mapApi2Session(await client.session(id)));

  @override
  Future<Map<String, String>> sessionStatuses() => _run(() async {
    final active = await client.activeSessions();
    // v1 status values were compared against 'idle'; any live execution
    // entry means the session is busy.
    return {
      for (final entry in active.entries)
        entry.key: entry.value == 'idle' ? 'idle' : 'busy',
    };
  });

  @override
  Future<List<MessageWithParts>> messages(String id) async =>
      (await messagePage(id)).items;

  @override
  Future<ServerPage<MessageWithParts>> messagePage(
    String id, {
    String? cursor,
    int limit = 100,
  }) => PerfTrace.span(
    'messages.page',
    () => _messagePage(id, cursor: cursor, limit: limit),
    attrs: {'older': cursor != null, 'limit': limit},
  );

  Future<ServerPage<MessageWithParts>> _messagePage(
    String id, {
    String? cursor,
    required int limit,
  }) => _run(() async {
    final page = await client.messages(
      id,
      limit: limit,
      order: 'desc',
      cursor: cursor,
    );
    // OpenCode 2 returns a cursor even on the last page; a short page is
    // the end. Otherwise every new conversation offered "Load older
    // messages" for nothing.
    final more =
        page.nextCursor?.isNotEmpty == true && page.data.length >= limit;
    return ServerPage(
      items:
          recordedTiming?.call(
            mapApi2Messages(id, page.data.reversed.toList()),
          ) ??
          mapApi2Messages(id, page.data.reversed.toList()),
      nextCursor: more ? page.nextCursor : null,
    );
  });

  @override
  Future<List<Todo>> todos(String id) async =>
      // No todo endpoint in v2 (capability sessionTodos: false).
      const [];

  @override
  Future<List<FileDiff>> diff(String id) => _run(() async {
    // v2 dropped the session-scoped diff; the location-scoped working-tree
    // diff is the sanctioned replacement (matrix: session.diff → vcs.diff).
    final json = await transport.getJson(
      '/vcs/diff',
      query: _loc({'mode': 'working'}),
    );
    return _dataList(json, mapVcsDiffJson);
  });

  // ---------------- Prompting ----------------

  Future<Api2SessionPermissionPolicy> _readPermissionPolicy(
    String sessionID,
  ) async => Api2SessionPermissionPolicy.fromSession(
    await transport.getJson('/session/$sessionID'),
    sessionID,
  );

  /// Installs the permission mode [sessionID] needs now: the server's own
  /// rules when it is approved automatically, permission requests otherwise.
  /// Returns the session as read back, or [policy] when nothing changed.
  Future<Api2SessionPermissionPolicy> _applyPermissionMode(
    String sessionID,
    Api2SessionPermissionPolicy policy,
  ) async {
    final agent = policy.agent;
    final agentResponse = agent == null
        ? Api2SessionPermissionPolicy.defaultAgent(
            await transport.getJson('/agent', query: _loc()),
          )
        : await _readAgent(agent);
    final update = policy.updateForAgent(
      agentResponse,
      serverRuns: serverRunsTools?.call(sessionID) ?? false,
    );
    if (policy.confirms(update)) return policy;
    await transport.patchJson('/session/$sessionID', body: update);
    // A successful HTTP response alone cannot establish the permission mode.
    // Read back before any prompt, command, or offline replay can execute.
    final confirmed = await _readPermissionPolicy(sessionID);
    if (confirmed.agent != policy.agent || !confirmed.confirms(update)) {
      throw const Api2RequestError(
        'Could not turn on permission requests. Your message was not sent.',
      );
    }
    return confirmed;
  }

  /// The pinned server drops a project's services after an idle hour and
  /// boots them again on the next request; for a moment after that boot it
  /// answers 404 for an agent that exists, which failed the first message
  /// after a quiet hour. A short retry rides over the boot.
  Future<Object?> _readAgent(String agent) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await transport.getJson(
          '/agent/${Uri.encodeComponent(agent)}',
          query: _loc(),
        );
      } on Api2Error catch (error) {
        if (error.statusCode != 404 || attempt >= 2) rethrow;
        await Future<void>.delayed(agentBootRetryDelay);
      }
    }
  }

  @visibleForTesting
  static Duration agentBootRetryDelay = const Duration(milliseconds: 500);

  /// Applies a changed automatic-approval choice to a session that may be
  /// running: switched on, its waiting and later tools run without this
  /// phone; switched off, its next tools ask again.
  Future<void> syncSessionPermissions(String sessionID) => _run(() async {
    await _applyPermissionMode(
      sessionID,
      await _readPermissionPolicy(sessionID),
    );
  });

  Future<void> _prepareSessionDispatch(
    String sessionID, {
    bool allowReverted = false,
  }) async {
    final policy = await _readPermissionPolicy(sessionID);
    // The pinned server implicitly commits a stage before admitting a
    // prompt, even with resume:false. Never let Send or offline replay
    // silently perform that permanent operation.
    if (!allowReverted && policy.reverted) {
      throw ApiException(
        'Review the staged revert, then clear it or make it permanent before sending.',
        statusCode: 409,
        errorTag: 'SessionRevertPending',
      );
    }
    final confirmed = await _applyPermissionMode(sessionID, policy);
    if (!allowReverted && confirmed.reverted) {
      throw ApiException(
        'Review the staged revert, then clear it or make it permanent before sending.',
        statusCode: 409,
        errorTag: 'SessionRevertPending',
      );
    }
  }

  @override
  Future<void> promptAsync(
    String sessionID, {
    required String text,
    ModelRef? model,
    String? agent,
    String? variant,
    List<PromptAttachment> attachments = const [],
    List<PromptAgentMention> agentMentions = const [],
    PromptDelivery? delivery,
    PromptCancellation? cancel,
  }) {
    return PromptTrace.track(sessionID, () async {
      await _prompt(
        sessionID,
        messageID: null,
        text: text,
        attachments: attachments,
        agentMentions: agentMentions,
        delivery: delivery,
        cancel: cancel,
      );
      // An API send is not a model request, and admission/memory failures
      // are not sends. Only record the server's successful acknowledgement.
      onPromptDispatched?.call(sessionID, model, agent, variant);
    });
  }

  /// A protocol-legal, stable message ID for one logical send. The same ID
  /// is reused by every retry of that send, so the server's admission
  /// deduplication covers a lost acknowledgement; an edited or new prompt
  /// gets a new one.
  @override
  String createPromptMessageID() => createCommandReceiptID();

  /// Sends a prompt under a caller-chosen message ID, through the same
  /// preparation as [promptAsync] — permission mode, memory and task
  /// metadata. Offline replay uses this instead of talking to the client
  /// directly: the direct path skipped all of that, so a replayed prompt
  /// could run under the server's own allow rules while the app expected
  /// to be asked.
  @override
  Future<void> promptWithMessageID(
    String sessionID, {
    required String messageID,
    required String text,
    ModelRef? model,
    String? agent,
    String? variant,
    List<PromptAttachment> attachments = const [],
    List<PromptAgentMention> agentMentions = const [],
    PromptDelivery? delivery,
    void Function()? beforeSend,
    PromptCancellation? cancel,
  }) {
    return PromptTrace.track(sessionID, () async {
      await _prompt(
        sessionID,
        messageID: messageID,
        text: text,
        attachments: attachments,
        agentMentions: agentMentions,
        delivery: delivery,
        beforeSend: beforeSend,
        cancel: cancel,
      );
      onPromptDispatched?.call(sessionID, model, agent, variant);
    });
  }

  Future<void> _prompt(
    String sessionID, {
    required String? messageID,
    required String text,
    required List<PromptAttachment> attachments,
    required List<PromptAgentMention> agentMentions,
    required PromptDelivery? delivery,
    void Function()? beforeSend,
    PromptCancellation? cancel,
  }) => _dispatch(
    sessionID,
    cancel: cancel,
    () => _run(() async {
      // Everything in this block happens before the request exists. A failure
      // here provably sent nothing, and saying so is what lets the caller
      // restore the input instead of leaving it in review forever.
      Map<String, dynamic>? metadata;
      try {
        // Timed per phase: the send path is a chain of network and storage
        // steps whose individual cost was invisible, so "sending is slow"
        // could not be attributed to permission, memory or metadata.
        var phase = PerfTrace.nowMicros;
        await _prepareSessionDispatch(sessionID);
        PerfTrace.recordSince('prompt.prepare.permission', phase);
        cancel?.throwIfCancelled();
        final memory = memoryContext;
        if (memory != null) {
          phase = PerfTrace.nowMicros;
          await Api2Memory(client).sync(sessionID, memory);
          PerfTrace.recordSince('prompt.prepare.memory', phase);
          cancel?.throwIfCancelled();
        }
        phase = PerfTrace.nowMicros;
        metadata = await taskMetadata?.call(sessionID, text, delivery);
        PerfTrace.recordSince('prompt.prepare.metadata', phase);
        cancel?.throwIfCancelled();
        beforeSend?.call();
        cancel?.throwIfCancelled();
      } on PromptCancelledException {
        rethrow;
      } on PromptNotSentException {
        rethrow;
      } on MemoryException {
        // Already a precise "refused before sending" contract with its own
        // recovery; wrapping it would hide the failure kind from the caller.
        rethrow;
      } on Object catch (error) {
        throw PromptNotSentException(error);
      }
      // Past this point a request exists. Its outcome — including a receipt
      // that does not describe what was asked for — is never reported as
      // "not sent", because it may have been admitted.
      await _sendPrompt(
        sessionID,
        messageID: messageID,
        text: text,
        attachments: attachments,
        agentMentions: agentMentions,
        delivery: delivery,
        metadata: metadata,
        cancel: cancel,
      );
    }),
  );

  Future<void> _sendPrompt(
    String sessionID, {
    required String? messageID,
    required String text,
    required List<PromptAttachment> attachments,
    required List<PromptAgentMention> agentMentions,
    required PromptDelivery? delivery,
    required Map<String, dynamic>? metadata,
    required PromptCancellation? cancel,
  }) async {
    final token = CancelToken();
    final detach = cancel?.onCancel(() {
      if (!token.isCancelled) token.cancel('send stopped');
    });
    Api2InboxItem receipt;
    try {
      receipt = await client.prompt(
        sessionID,
        id: messageID,
        text: text,
        cancelToken: cancel == null ? null : token,
        metadata: metadata,
        delivery: switch (delivery) {
          null => null,
          PromptDelivery.steer => Api2Delivery.steer,
          PromptDelivery.queue => Api2Delivery.queue,
        },
        files: [
          for (final attachment in attachments)
            Api2PromptFile(
              uri: attachment.url,
              name: attachment.filename.isNotEmpty ? attachment.filename : null,
              mention:
                  attachment.mentionStart == null ||
                      attachment.mentionEnd == null
                  ? null
                  : Api2Mention(
                      start: attachment.mentionStart!,
                      end: attachment.mentionEnd!,
                      text: attachment.mentionText,
                    ),
            ),
        ],
        agents: [
          for (final mention in agentMentions)
            Api2PromptAgentMention(
              name: mention.name,
              mention: Api2Mention(
                start: mention.start,
                end: mention.end,
                text: mention.value,
              ),
            ),
        ],
      );
    } on Api2Error {
      // A cancelled request is not a server failure. The transport reports a
      // cancelled exchange as a network error, so the cancellation itself is
      // what decides — and because the request had already left, the server
      // may hold it: the caller must not read this as "nothing was sent".
      if (cancel?.isCancelled ?? false) {
        throw const PromptCancelledException(afterDispatch: true);
      }
      rethrow;
    } finally {
      detach?.call();
    }
    if (cancel?.isCancelled ?? false) {
      // The acknowledgement was in hand when the stop landed: the prompt is
      // admitted, whatever the person meant to stop.
      throw const PromptCancelledException(afterDispatch: true);
    }
    if (messageID != null) {
      // The receipt must describe the message that was asked for. A
      // mismatched one is not evidence of admission, and treating it as
      // success would let the queue drop an unsent prompt.
      if (receipt.id != messageID ||
          receipt.sessionID != sessionID ||
          !receipt.isPrompt) {
        throw const Api2RequestError(
          'The server acknowledged a different message than the one sent.',
        );
      }
    }
    if (metadata != null) {
      onTaskPromptAccepted?.call(sessionID, receipt, metadata);
    }
  }

  @override
  Future<void> shell(
    String sessionID, {
    required String command,
    required String agent,
    ModelRef? model,
    String? variant,
  }) => _dispatch(
    sessionID,
    () => _run(() async {
      // v2 uses its existing session selection for ordinary sends.
      await _prepareSessionDispatch(sessionID, allowReverted: true);
      await transport.postJson(
        '/session/$sessionID/shell',
        body: {'command': command},
      );
    }),
  );

  @override
  Future<void> slashCommand(
    String sessionID,
    String command,
    String args, {
    ModelRef? model,
    String? variant,
  }) => _dispatch(
    sessionID,
    () => _run(() async {
      await _prepareSessionDispatch(sessionID);
      final name = command.startsWith('/') ? command.substring(1) : command;
      final memory = memoryContext;
      if (memory != null) await Api2Memory(client).sync(sessionID, memory);
      await transport.postJson(
        '/session/$sessionID/command',
        body: {'command': name, 'text': args},
      );
    }),
  );

  @override
  Future<void> abort(String sessionID) =>
      _run(() => client.interrupt(sessionID));

  // ---------------- Permissions ----------------

  @override
  Future<List<PermissionRequest>> pendingPermissions() => _run(() async {
    final requests = await client.pendingPermissions();
    return requests.map(mapApi2PermissionRequest).toList();
  });

  @override
  Future<List<PermissionRequest>> pendingPermissionsV2() =>
      pendingPermissions();

  /// Reply to the exact pending request already resolved by the app.
  Future<void> respondToPermissionRequest(
    PermissionRequest request,
    String reply, {
    String? message,
  }) => _run(() {
    final decision = mapPermissionReply(reply);
    // Core ends the step on a bare reject. Feedback keeps the decision a
    // rejection, but lets Core give the model a tool error for this call.
    final feedback =
        decision == Api2PermissionReply.reject &&
            request.permission == 'shizuku' &&
            (message == null || message.trim().isEmpty)
        ? 'The user declined this Android shell request. Do not retry it '
              'or perform the same action through another channel.'
        : message;
    return client.replyPermission(
      request.sessionID,
      request.id,
      decision,
      message: feedback,
    );
  });

  @override
  Future<void> respondPermission(
    String requestID,
    String reply, {
    String? legacySessionID,
    String? legacyPermissionID,
    String? message,
  }) => _run(() async {
    var sessionID = legacySessionID;
    if (sessionID == null || sessionID.isEmpty) {
      // The v2 reply route is session-scoped; recover the owner from the
      // pending list when the caller only knows the request ID.
      final pending = await client.pendingPermissions();
      for (final request in pending) {
        if (request.id == requestID) {
          sessionID = request.sessionID;
          break;
        }
      }
    }
    if (sessionID == null || sessionID.isEmpty) {
      throw ApiException(
        'Permission request $requestID is no longer pending',
        statusCode: 404,
        errorTag: 'PermissionNotFoundError',
        requestID: requestID,
      );
    }
    await client.replyPermission(
      sessionID,
      requestID,
      mapPermissionReply(reply),
      message: message,
    );
  });

  @override
  Future<void> respondPermissionV2(
    String sessionID,
    String requestID,
    String reply, {
    String? message,
  }) => _run(
    () => client.replyPermission(
      sessionID,
      requestID,
      mapPermissionReply(reply),
      message: message,
    ),
  );

  // ---------------- Forms ----------------

  @override
  Future<List<Api2FormInfo>> sessionForms(String sessionID) =>
      _run(() => client.sessionForms(sessionID));

  @override
  Future<List<Api2FormInfo>> pendingForms() =>
      _run(() => client.pendingForms());

  @override
  Future<Api2FormState> formState(String sessionID, String formID) =>
      _run(() => client.formState(sessionID, formID));

  @override
  Future<void> replyForm(
    String sessionID,
    String formID,
    Map<String, dynamic> answer,
  ) => _run(() => client.replyForm(sessionID, formID, answer));

  @override
  Future<void> cancelForm(String sessionID, String formID) =>
      _run(() => client.cancelForm(sessionID, formID));

  // ---------------- Inbox ----------------

  @override
  Future<List<Api2InboxItem>> inboxItems(String sessionID) =>
      _run(() => client.inbox(sessionID));

  @override
  Future<void> cancelInboxItem(String sessionID, String inboxID) =>
      _run(() => client.cancelInboxItem(sessionID, inboxID));

  @override
  Future<void> steerInboxItem(String sessionID, String inboxID) =>
      _run(() => client.steerInboxItem(sessionID, inboxID));

  @override
  Future<void> queueInboxItem(String sessionID, String inboxID) =>
      _run(() => client.queueInboxItem(sessionID, inboxID));

  // ---------------- Questions ----------------
  //
  // v1 questions were replaced by v2 forms, whose typed multi-field answers
  // do not fit the legacy string[][] reply contract. These stay inert
  // (capability legacyQuestionRequests: false); the forms UI arrives in a
  // later slice.

  @override
  Future<List<Map<String, dynamic>>> pendingQuestionsV2() async => const [];

  @override
  Future<void> answerQuestionV2(
    String sessionID,
    String requestID,
    List<List<String>> answers,
  ) => Future.error(
    const ProductException('Question dialogs are unavailable on this server'),
  );

  @override
  Future<void> rejectQuestionV2(String sessionID, String requestID) =>
      Future.error(
        const ProductException(
          'Question dialogs are unavailable on this server',
        ),
      );

  // ---------------- Providers / agents ----------------

  @override
  Future<ProvidersResponse> providers() => _run(() async {
    final (providers, models, defaultModel) = await waitForRequests(
      client.providers(),
      client.models(),
      client.defaultModel(),
    );
    return mapApi2Providers(
      providers: providers,
      models: models,
      defaultModel: defaultModel,
    );
  });

  @override
  Future<ProvidersResponse> configuredProviders() => providers();

  @override
  Future<List<AgentInfo>> agents() => _run(() async {
    final agents = await client.agents();
    return [
      for (final agent in agents)
        if (agent.selectable) mapApi2Agent(agent),
    ];
  });

  // ---------------- Files ----------------

  @override
  Future<List<FileNode>> listFiles(String path) => _run(() async {
    final entries = await client.fsList(path.isEmpty ? '.' : path);
    return entries.map(mapApi2FsEntry).toList();
  });

  @override
  Future<FileContent> fileContent(String path) => _run(() async {
    final bytes = await client.fsReadBytes(path);
    final looksBinary = bytes.take(8192).contains(0);
    if (looksBinary) {
      return FileContent(
        base64Encode(bytes),
        type: 'binary',
        encoding: 'base64',
        mimeType: _mimeForPath(path),
      );
    }
    return FileContent(utf8.decode(bytes, allowMalformed: true));
  });

  @override
  Future<List<String>> findFile(String query) => _run(() async {
    final entries = await client.fsFind(query, type: 'file');
    return [for (final entry in entries) entry.path];
  });

  @override
  Future<List<FindMatch>> findText(String pattern) async =>
      // No workspace text search in v2 (capability textSearch: false); the
      // one v1 declaration had no consumer either.
      const [];

  // ---------------- Events ----------------

  @override
  LiveEventChannel openEventChannel({
    required void Function(EventEnvelope event) onEvent,
    required void Function(StreamStatus status) onStatus,
    void Function(Object error)? onError,
  }) => Api2LiveEventChannel(
    transport: transport,
    onEvent: onEvent,
    onStatus: onStatus,
    onError: onError,
    directoryFilter: () => client.directory,
  );

  @override
  LiveEventChannel openGlobalEventChannel({
    required void Function(EventEnvelope event) onEvent,
    required void Function(StreamStatus status) onStatus,
    void Function(Object error)? onError,
  }) => Api2LiveEventChannel(
    transport: transport,
    onEvent: onEvent,
    onStatus: onStatus,
    onError: onError,
    global: true,
  );

  // ---------------- helpers ----------------

  static List<T> _dataList<T>(
    dynamic json,
    T Function(Map<String, dynamic>) parse,
  ) {
    final data = json is Map<String, dynamic> ? json['data'] : null;
    if (data is! List) return const [];
    final out = <T>[];
    for (final item in data) {
      if (item is Map) {
        try {
          out.add(parse(Map<String, dynamic>.from(item)));
        } catch (_) {}
      }
    }
    return out;
  }

  static String? _mimeForPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.bmp')) return 'image/bmp';
    if (lower.endsWith('.pdf')) return 'application/pdf';
    return null;
  }
}
