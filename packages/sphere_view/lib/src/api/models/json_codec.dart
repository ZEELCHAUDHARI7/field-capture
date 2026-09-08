/// Shared decoding helpers for the model layer.
///
/// Exists because JSON is the ABI (architecture §6.4) *and* the on-disk bundle
/// format (§6.6), so every model is parsed from untyped maps in two different
/// contexts. Centralising the `num`-to-`double` widening and the "wrong type"
/// error text stops each model from inventing its own, and keeps a malformed
/// `bundle.json` producing one recognisable exception instead of a
/// `_TypeError` from somewhere deep in a constructor.
library;

/// Thrown when a JSON payload is structurally valid but does not describe the
/// model being asked for — a missing field, a wrong type, an unknown
/// discriminator, or a `schema_version` we cannot read.
class SphereJsonFormatException implements Exception {
  /// Creates an exception describing why [context] could not be decoded.
  const SphereJsonFormatException(this.context, this.message);

  /// The model or field being decoded, e.g. `CameraIntrinsics.fx`.
  final String context;

  /// What was wrong with it.
  final String message;

  @override
  String toString() => 'SphereJsonFormatException($context): $message';
}

/// Reads a required `double`, widening ints written by other JSON encoders.
///
/// `jsonEncode(3.0)` emits `3.0`, but a hand-written bundle or a C++ writer may
/// emit `3`. Both must decode to the same value or offline replay silently
/// diverges from the device.
double jsonDouble(Map<String, Object?> json, String key, {String? context}) {
  final v = json[key];
  if (v is num) return v.toDouble();
  throw SphereJsonFormatException(
    context == null ? key : '$context.$key',
    'expected a number, got ${v.runtimeType}',
  );
}

/// Reads an optional `double`; `null` and a missing key are the same thing.
double? jsonDoubleOrNull(
  Map<String, Object?> json,
  String key, {
  String? context,
}) {
  final v = json[key];
  if (v == null) return null;
  if (v is num) return v.toDouble();
  throw SphereJsonFormatException(
    context == null ? key : '$context.$key',
    'expected a number or null, got ${v.runtimeType}',
  );
}

/// Reads a required `int`.
int jsonInt(Map<String, Object?> json, String key, {String? context}) {
  final v = json[key];
  if (v is int) return v;
  if (v is double && v == v.roundToDouble()) return v.toInt();
  throw SphereJsonFormatException(
    context == null ? key : '$context.$key',
    'expected an integer, got ${v.runtimeType}',
  );
}

/// Reads an optional `int`.
int? jsonIntOrNull(Map<String, Object?> json, String key, {String? context}) {
  final v = json[key];
  if (v == null) return null;
  return jsonInt(json, key, context: context);
}

/// Reads a required `String`.
String jsonString(Map<String, Object?> json, String key, {String? context}) {
  final v = json[key];
  if (v is String) return v;
  throw SphereJsonFormatException(
    context == null ? key : '$context.$key',
    'expected a string, got ${v.runtimeType}',
  );
}

/// Reads an optional `String`; `null` and a missing key are both `null`.
String? jsonStringOrNull(
  Map<String, Object?> json,
  String key, {
  String? context,
}) {
  final v = json[key];
  if (v == null) return null;
  if (v is String) return v;
  throw SphereJsonFormatException(
    context == null ? key : '$context.$key',
    'expected a string or null, got ${v.runtimeType}',
  );
}

/// Reads a required `bool`.
bool jsonBool(Map<String, Object?> json, String key, {String? context}) {
  final v = json[key];
  if (v is bool) return v;
  throw SphereJsonFormatException(
    context == null ? key : '$context.$key',
    'expected a bool, got ${v.runtimeType}',
  );
}

/// Reads a required nested object.
Map<String, Object?> jsonObject(
  Map<String, Object?> json,
  String key, {
  String? context,
}) {
  final v = json[key];
  if (v is Map) return v.cast<String, Object?>();
  throw SphereJsonFormatException(
    context == null ? key : '$context.$key',
    'expected an object, got ${v.runtimeType}',
  );
}

/// Reads an optional nested object.
Map<String, Object?>? jsonObjectOrNull(
  Map<String, Object?> json,
  String key, {
  String? context,
}) {
  final v = json[key];
  if (v == null) return null;
  return jsonObject(json, key, context: context);
}

/// Reads a required list, mapping each element with [item].
List<T> jsonList<T>(
  Map<String, Object?> json,
  String key,
  T Function(Object? element) item, {
  String? context,
}) {
  final v = json[key];
  if (v is List) return v.map(item).toList(growable: false);
  throw SphereJsonFormatException(
    context == null ? key : '$context.$key',
    'expected a list, got ${v.runtimeType}',
  );
}

/// Reads a required list of `double`.
List<double> jsonDoubleList(
  Map<String, Object?> json,
  String key, {
  String? context,
}) => jsonList<double>(json, key, (e) {
  if (e is num) return e.toDouble();
  throw SphereJsonFormatException(
    context == null ? key : '$context.$key',
    'expected a list of numbers, found ${e.runtimeType}',
  );
}, context: context);

/// Reads a required list of `int`.
List<int> jsonIntList(
  Map<String, Object?> json,
  String key, {
  String? context,
}) => jsonList<int>(json, key, (e) {
  if (e is int) return e;
  throw SphereJsonFormatException(
    context == null ? key : '$context.$key',
    'expected a list of integers, found ${e.runtimeType}',
  );
}, context: context);

/// Reads a required list of `String`.
List<String> jsonStringList(
  Map<String, Object?> json,
  String key, {
  String? context,
}) => jsonList<String>(json, key, (e) {
  if (e is String) return e;
  throw SphereJsonFormatException(
    context == null ? key : '$context.$key',
    'expected a list of strings, found ${e.runtimeType}',
  );
}, context: context);

/// Reads an enum by its `name`, so the wire format survives reordering the
/// declaration — the one exception is `StitchStage`, whose *ordinal* is part of
/// the native ABI and is documented as such at its declaration.
T jsonEnum<T extends Enum>(
  Map<String, Object?> json,
  String key,
  List<T> values, {
  String? context,
}) {
  final name = jsonString(json, key, context: context);
  for (final v in values) {
    if (v.name == name) return v;
  }
  throw SphereJsonFormatException(
    context == null ? key : '$context.$key',
    'unknown value "$name"; expected one of ${values.map((v) => v.name).join(', ')}',
  );
}

/// Order-sensitive list equality, used by every model's `==`.
bool listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Order-sensitive list hash, paired with [listEquals].
int listHash<T>(List<T> list) => Object.hashAll(list);

/// Deep structural equality for the untyped `deviceInfo` map.
///
/// `Map.==` is identity, so without this a round-tripped bundle would never
/// compare equal to the original — which is exactly the property
/// `bundle_roundtrip_test` is built to prove.
bool deepEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key)) return false;
      if (!deepEquals(a[key], b[key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// Order-insensitive deep hash, paired with [deepEquals].
int deepHash(Object? value) {
  if (value is Map) {
    var h = 0;
    for (final entry in value.entries) {
      // XOR so the hash does not depend on iteration order.
      h ^= Object.hash(entry.key, deepHash(entry.value));
    }
    return h;
  }
  if (value is List) {
    return Object.hashAll(value.map(deepHash));
  }
  return value.hashCode;
}
