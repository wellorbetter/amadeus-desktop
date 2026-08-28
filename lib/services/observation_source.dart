/// A read-only capability that lets the agent observe part of the user's
/// current context. Observation is intentionally separate from memory:
/// sources provide ephemeral facts, while the memory layer decides what is
/// worth retaining and gives the user deletion controls.
abstract interface class ObservationSource {
  String get id;
  String get displayName;
  bool get hasData;

  Future<bool> refresh();

  /// A privacy-filtered, compact representation suitable for prompt context.
  String summary();
}
