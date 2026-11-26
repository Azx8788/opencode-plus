import 'package:flutter/foundation.dart';

/// How well a channel can do something, from "the platform does this natively"
/// down to "this build cannot".
///
/// The point of the middle states is honesty: a QQ group can receive an image
/// only through the platform's media upload flow ([extension]), a Telegram
/// bot can edit its own messages but a OneBot implementation may or may not
/// ([unverified]). Collapsing all of that into a bool is how a UI ends up
/// promising something the channel will silently drop.
enum CapabilityStatus {
  /// The platform provides it and the adapter implements it.
  native,

  /// Possible through a platform extension the adapter implements, with
  /// conditions (media upload, an approval, a paid tier).
  extension,

  /// Only by the application composing several native calls; the adapter
  /// does that, and the result may differ from a native feature.
  application,

  /// The platform does not offer it. Never attempted, never pretended.
  unsupported,

  /// The platform documents it but this build has not proven it against a
  /// real account. Treated as unavailable until verified.
  unverified,
}

@immutable
class CapabilitySpec {
  const CapabilitySpec(
    this.status, {
    this.note,
    this.requiresPermission = false,
    this.limit,
  });

  const CapabilitySpec.unsupported([this.note])
    : status = CapabilityStatus.unsupported,
      requiresPermission = false,
      limit = null;

  const CapabilitySpec.unverified([this.note])
    : status = CapabilityStatus.unverified,
      requiresPermission = false,
      limit = null;

  final CapabilityStatus status;

  /// One sentence a settings page can show as-is. Written for the person
  /// configuring the channel, not for a log.
  final String? note;

  /// True when the platform grants this per bot, in its console, after review.
  final bool requiresPermission;

  /// A platform limit worth stating next to the capability (character count,
  /// replies per window).
  final String? limit;

  bool get usable =>
      status == CapabilityStatus.native ||
      status == CapabilityStatus.extension ||
      status == CapabilityStatus.application;

  Map<String, Object?> toJson() => {
    'status': status.name,
    if (note != null) 'note': note,
    if (requiresPermission) 'requiresPermission': true,
    if (limit != null) 'limit': limit,
  };
}

/// The operations the shared layers may ask a channel to perform.
enum ChannelCapability {
  directMessage,
  groupMessage,
  activeMessage,
  passiveReply,
  image,
  file,
  voice,
  messageReply,
  messageEdit,
  messageRecall,
  messageQuery,
  longText,
}

/// A channel's honest answer about what it can do.
///
/// Every provider declares all twelve capabilities. A missing entry reads as
/// [CapabilityStatus.unsupported] so a new capability added to the enum can
/// never be assumed present by accident.
@immutable
class ChannelCapabilities {
  const ChannelCapabilities(this._specs);

  final Map<ChannelCapability, CapabilitySpec> _specs;

  CapabilitySpec spec(ChannelCapability capability) =>
      _specs[capability] ?? const CapabilitySpec.unsupported();

  CapabilityStatus statusOf(ChannelCapability capability) =>
      spec(capability).status;

  bool supports(ChannelCapability capability) => spec(capability).usable;

  /// Capabilities a settings page must show as unavailable, with the reason
  /// the provider gave.
  Map<ChannelCapability, CapabilitySpec> get unavailable => {
    for (final capability in ChannelCapability.values)
      if (!supports(capability)) capability: spec(capability),
  };

  /// Everything a channel can do, for the settings summary.
  Map<ChannelCapability, CapabilitySpec> get all => {
    for (final capability in ChannelCapability.values)
      capability: spec(capability),
  };

  Map<String, Object?> toJson() => {
    for (final entry in all.entries) entry.key.name: entry.value.toJson(),
  };

  /// Reads a capability profile back from [toJson]; unknown keys are ignored,
  /// so an older stored profile never breaks a newer build.
  factory ChannelCapabilities.fromJson(Map<String, Object?> json) {
    final specs = <ChannelCapability, CapabilitySpec>{};
    for (final capability in ChannelCapability.values) {
      final raw = json[capability.name];
      if (raw is! Map) continue;
      final status = CapabilityStatus.values.firstWhere(
        (value) => value.name == raw['status'],
        orElse: () => CapabilityStatus.unsupported,
      );
      specs[capability] = CapabilitySpec(
        status,
        note: raw['note']?.toString(),
        requiresPermission: raw['requiresPermission'] == true,
        limit: raw['limit']?.toString(),
      );
    }
    return ChannelCapabilities(specs);
  }
}
