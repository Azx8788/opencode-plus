part of 'pickers.dart';

extension _ModelReasoning on _ModelCatalogViewState {
  List<String> _extraEfforts(CatalogModel model) =>
      (widget.saveReasoningEffort != null ||
          (!widget.controller.isIsolated && _canEditWindow))
      ? additionalReasoningEfforts(model)
      : const [];

  /// A menu entry absent from the server's catalog is an explicit override.
  /// Save it before selecting it; never just draw Max and send an unknown ID.
  Future<bool> _prepareReasoningChoice(ModelRef model, String variant) async {
    if (variant.isEmpty) return true;
    final controller = widget.controller;
    final scope = _scopedSessionID;
    bool sameScope() =>
        mounted &&
        identical(widget.controller, controller) &&
        scope == _scopedSessionID &&
        _sameScope;
    CatalogModel? current() => controller
        .catalogForSession(scope)
        ?.models
        .where((m) => m.providerID == model.providerID && m.id == model.modelID)
        .firstOrNull;
    bool offered() =>
        current()?.variants.any((v) => v.id == variant && !v.disabled) ?? false;
    if (offered()) return true;
    final row = current();
    if (row == null || !_extraEfforts(row).contains(variant)) {
      _set(() => _saveError = _strings.chatErrorVariantUnavailable);
      return false;
    }
    try {
      final write = widget.saveReasoningEffort;
      if (write != null) {
        await write(model, variant);
      } else {
        final profile = controller.profile;
        if (profile == null || !sameScope()) return false;
        final directory = controller.directory;
        final workspace = controller.workspace;
        await BuiltinProviderStore(linux: BuiltinLinux()).setModelReasoningEffort(
          model.providerID,
          model.modelID,
          variant,
        );
        if (!sameScope()) return false;
        final reloaded = await reloadServerConfig(
          baseUrl: profile.baseUrl,
          password: profile.password,
          username: profile.username.isEmpty ? 'opencode' : profile.username,
          cleartextConfirmedOrigin: profile.cleartextConfirmedOrigin,
          certificatePinSha256: profile.certificatePinSha256,
          directory: directory,
          workspace: workspace,
        );
        if (!sameScope()) return false;
        if (!reloaded) {
          _set(() => _saveError = _strings.modelEffortSavedNotLoaded);
          return false;
        }
        await controller.refreshCatalog();
      }
      if (!sameScope()) return false;
      if (!offered()) {
        _set(() => _saveError = _strings.modelEffortSavedNotLoaded);
        return false;
      }
      return true;
    } catch (_) {
      if (mounted) _set(() => _saveError = _strings.modelEffortSaveFailed);
      return false;
    }
  }
}
