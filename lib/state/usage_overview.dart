import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_timezone/flutter_timezone.dart';

import '../domain/server_gateway.dart';
import '../domain/usage_dashboard.dart';
import 'connection.dart';

enum UsageScope { allProjects, currentProject }

class UsageProjectUnavailable implements Exception {
  const UsageProjectUnavailable();
}

class UsageTimezoneUnavailable implements Exception {
  const UsageTimezoneUnavailable();
}

class UsageRefreshInterrupted implements Exception {
  const UsageRefreshInterrupted();
}

class UsageSnapshot {
  final UsageStatistics statistics;
  final UsageQuery query;
  final UsageRange range;
  final UsageScope scope;
  final String? projectName;
  final DateTime fetchedAt;
  const UsageSnapshot({
    required this.statistics,
    required this.query,
    required this.range,
    required this.scope,
    this.projectName,
    required this.fetchedAt,
  });
}

/// A retained usage page belongs to one connection location. Filter changes
/// supersede old reads; refreshing the same filters can retain visible totals.
class UsageOverview extends ChangeNotifier {
  final ConnectionController connection;
  final DateTime Function() clock;
  final Future<String> Function() timezoneLoader;
  final int _location;
  int _request = 0;
  bool _disposed = false;
  bool detached = false;
  bool loading = false;
  Object? error;
  UsageSnapshot? snapshot;
  UsageSnapshot? lifetime;
  Object? lifetimeError;
  bool lifetimeLoading = false;
  UsageTrendPlan? trendPlan;
  List<UsageTrendPoint> trend = const [];
  bool trendLoading = false;
  int trendFinished = 0;
  int _summaryRequest = 0;
  int _trendRequest = 0;
  // Cache belongs to this location/controller only, never another profile.
  final _trendCache = <(int, int, String?, String), UsageStatistics>{};
  int _activeReads = 0;
  final List<Future<void> Function()> _pendingReads = [];
  UsageRange range = UsageRange.thirtyDays;
  UsageScope scope = UsageScope.allProjects;
  String? _providerFilter;
  String _modelSearch = '';
  int filterRevision = 0;

  String? get providerFilter => _providerFilter;
  String get modelSearch => _modelSearch;
  bool get hasInspectionFilters =>
      _providerFilter != null || _modelSearch.isNotEmpty;

  List<UsageModel> get matchingModels {
    final query = _modelSearch.trim().toLowerCase();
    return List.unmodifiable(
      (snapshot?.statistics.models ?? const <UsageModel>[]).where((model) {
        return (_providerFilter == null ||
                model.providerID == _providerFilter) &&
            (query.isEmpty ||
                [
                  model.providerID,
                  model.modelID,
                  model.variant ?? '',
                ].any((value) => value.toLowerCase().contains(query)));
      }),
    );
  }

  void setProviderFilter(String? value) {
    if (_disposed || detached || _providerFilter == value) return;
    _providerFilter = value;
    notifyListeners();
  }

  void setModelSearch(String value) {
    if (_disposed || detached || _modelSearch == value) return;
    _modelSearch = value;
    notifyListeners();
  }

  void _resetInspectionFilters() {
    _providerFilter = null;
    _modelSearch = '';
    filterRevision++;
  }

  void clearInspectionFilters() {
    if (_disposed || detached) return;
    _resetInspectionFilters();
    notifyListeners();
  }

  UsageOverview(
    this.connection, {
    DateTime Function()? clock,
    Future<String> Function()? timezoneLoader,
  }) : _location = connection.locationRevision,
       clock = clock ?? DateTime.now,
       timezoneLoader = timezoneLoader ?? _deviceTimezone {
    connection.addListener(_connectionChanged);
  }

  static Future<String> _deviceTimezone() async {
    try {
      final identifier = (await FlutterTimezone.getLocalTimezone()).identifier
          .trim();
      if (identifier.isNotEmpty && identifier != 'Etc/Unknown') {
        return identifier;
      }
    } catch (_) {}
    throw const UsageTimezoneUnavailable();
  }

  void _connectionChanged() {
    if (_disposed || connection.locationRevision == _location) return;
    detached = true;
    _resetInspectionFilters();
    _request++;
    snapshot = null;
    lifetime = null;
    lifetimeError = null;
    lifetimeLoading = false;
    _summaryRequest++;
    _clearTrend();
    _trendCache.clear();
    error = null;
    loading = false;
    notifyListeners();
  }

  Future<void> setRange(UsageRange value) async {
    if (_disposed || detached) return;
    if (range == value) return;
    range = value;
    _resetInspectionFilters();
    snapshot = null;
    await _refresh(force: false);
  }

  Future<void> setScope(UsageScope value) async {
    if (_disposed || detached) return;
    if (scope == value) return;
    scope = value;
    _resetInspectionFilters();
    snapshot = null;
    lifetime = null;
    lifetimeError = null;
    lifetimeLoading = false;
    _summaryRequest++;
    await _refresh(force: false);
  }

  bool _current(int request) =>
      !_disposed &&
      !detached &&
      request == _request &&
      connection.locationRevision == _location;

  Future<void> refresh() => _refresh(force: true);

  Future<void> _refresh({required bool force}) async {
    if (_disposed || detached) return;
    final request = ++_request;
    if (force) {
      _trendCache.clear();
      _summaryRequest++;
      lifetimeLoading = false;
    }
    _clearTrend();
    final selectedRange = range;
    final selectedScope = scope;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final repository = await connection.prepareActionRepository();
      if (!_current(request)) return;
      if (repository == null) throw const UsageRefreshInterrupted();
      if (repository is! UsageStatisticsGateway ||
          !(repository as UsageStatisticsGateway).usageStatisticsSupported) {
        throw const UsageUnsupported();
      }
      final timezone = await timezoneLoader();
      if (!_current(request)) return;
      final project = selectedScope == UsageScope.currentProject
          ? await repository.loadCurrentProject()
          : null;
      if (!_current(request)) return;
      if (selectedScope == UsageScope.currentProject &&
          (project == null || project.id.isEmpty)) {
        throw const UsageProjectUnavailable();
      }
      // A wake or reload may replace the transport without changing location.
      // Do not dispatch this request through an object retired during setup.
      if (!identical(repository, connection.repository)) {
        throw const UsageRefreshInterrupted();
      }
      final now = clock().toLocal();
      final query = UsageQuery.forRange(
        selectedRange,
        now: now,
        timezone: timezone,
        projectID: project?.id,
      );
      final cachedSummary = lifetime;
      if (!lifetimeLoading &&
          (force ||
              cachedSummary == null ||
              cachedSummary.query.projectID != query.projectID ||
              cachedSummary.query.timezone != query.timezone ||
              clock().difference(cachedSummary.fetchedAt) >=
                  const Duration(minutes: 2))) {
        unawaited(
          _loadLifetime(
            repository as UsageStatisticsGateway,
            query,
            selectedScope,
            project?.name,
          ),
        );
      }
      final previous = snapshot;
      if (previous != null &&
          (previous.query.projectID != query.projectID ||
              previous.query.timezone != query.timezone)) {
        snapshot = null;
        _resetInspectionFilters();
        notifyListeners();
      }
      final statistics = await (repository as UsageStatisticsGateway)
          .loadUsageStatistics(query);
      if (!_current(request)) return;
      if (!identical(repository, connection.repository)) {
        throw const UsageRefreshInterrupted();
      }
      snapshot = UsageSnapshot(
        statistics: statistics,
        query: query,
        range: selectedRange,
        scope: selectedScope,
        projectName: project?.name,
        fetchedAt: clock(),
      );
      unawaited(loadTrend());
    } catch (failure) {
      if (_current(request)) error = failure;
    } finally {
      if (_current(request)) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> _loadLifetime(
    UsageStatisticsGateway gateway,
    UsageQuery selected,
    UsageScope selectedScope,
    String? projectName,
  ) async {
    final request = ++_summaryRequest;
    lifetimeLoading = true;
    lifetimeError = null;
    try {
      final query = UsageQuery(
        to: selected.to,
        timezone: selected.timezone,
        projectID: selected.projectID,
      );
      final statistics = await gateway.loadUsageStatistics(query);
      if (_disposed || detached || request != _summaryRequest) return;
      if (!identical(gateway, connection.repository))
        throw const UsageRefreshInterrupted();
      lifetime = UsageSnapshot(
        statistics: statistics,
        query: query,
        range: UsageRange.allTime,
        scope: selectedScope,
        projectName: projectName,
        fetchedAt: clock(),
      );
    } catch (failure) {
      if (!_disposed && !detached && request == _summaryRequest)
        lifetimeError = failure;
    } finally {
      if (!_disposed && !detached && request == _summaryRequest) {
        lifetimeLoading = false;
        notifyListeners();
      }
    }
  }

  void _clearTrend() {
    _trendRequest++;
    trend = const [];
    trendPlan = null;
    trendLoading = false;
    trendFinished = 0;
  }

  /// Two workers across superseded ranges, not two new workers per tap.
  /// Old requests may finish, but do not dispatch further reads or paint data.
  Future<T> _limited<T>(Future<T> Function() read) {
    final completer = Completer<T>();
    _pendingReads.add(() async {
      try {
        completer.complete(await read());
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    _pumpReads();
    return completer.future;
  }

  void _pumpReads() {
    while (_activeReads < 2 && _pendingReads.isNotEmpty) {
      final read = _pendingReads.removeAt(0);
      _activeReads++;
      unawaited(
        read().whenComplete(() {
          _activeReads--;
          _pumpReads();
        }),
      );
    }
  }

  Future<void> loadTrend() async {
    final current = snapshot;
    final gateway = connection.repository;
    if (_disposed ||
        detached ||
        current == null ||
        gateway is! UsageStatisticsGateway)
      return;
    final request = ++_trendRequest;
    final plan = UsageTrendPlan.forStatistics(
      current.statistics,
      current.range,
    );
    trendPlan = plan;
    trend = [
      for (final bucket in plan.buckets) UsageTrendPoint(bucket: bucket),
    ];
    trendLoading = trend.isNotEmpty;
    trendFinished = 0;
    notifyListeners();
    var next = 0;
    bool valid() =>
        !_disposed &&
        !detached &&
        request == _trendRequest &&
        identical(snapshot, current) &&
        identical(gateway, connection.repository);
    Future<void> worker() async {
      while (valid() && next < plan.buckets.length) {
        final index = next++;
        final bucket = plan.buckets[index];
        final query = bucket.query(current.query);
        final key = (query.from!, query.to, query.projectID, query.timezone);
        try {
          final cached = _trendCache[key];
          final stats =
              cached ??
              await _limited(() async {
                if (!valid()) throw const UsageRefreshInterrupted();
                return (gateway as UsageStatisticsGateway).loadUsageStatistics(
                  query,
                );
              });
          if (!valid()) return;
          // A narrower server response is not a zero/complete day.
          if (stats.from != query.from || stats.to != query.to) {
            throw const FormatException('Incomplete usage bucket');
          }
          _trendCache[key] = stats;
          while (_trendCache.length > 96)
            _trendCache.remove(_trendCache.keys.first);
          trend[index] = UsageTrendPoint(bucket: bucket, statistics: stats);
        } catch (_) {
          if (!valid()) return;
          trend[index] = UsageTrendPoint(bucket: bucket, failed: true);
        }
        trendFinished++;
        notifyListeners();
      }
    }

    await Future.wait([worker(), worker()]);
    if (valid()) {
      trendLoading = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _request++;
    _summaryRequest++;
    _trendRequest++;
    connection.removeListener(_connectionChanged);
    super.dispose();
  }
}
