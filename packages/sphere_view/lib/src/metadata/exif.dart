import 'dart:typed_data';

import 'panorama_metadata.dart';

/// The EXIF tags this package writes, by their numeric value.
///
/// Named constants rather than literals because an EXIF tag number is exactly
/// the kind of magic number that is impossible to review: `0x9003` and `0x9004`
/// are `DateTimeOriginal` and `DateTimeDigitized`, look identical, and swapping
/// them produces a file that every tool reads without complaint and that says
/// something slightly untrue.
abstract final class ExifTag {
  /// IFD0 — free text; carries the station id (Phase 11 §2).
  static const int imageDescription = 0x010E;

  /// IFD0 — device manufacturer.
  static const int make = 0x010F;

  /// IFD0 — device model.
  static const int model = 0x0110;

  /// IFD0 — always 1 here. An equirectangular panorama is stored the way it is
  /// meant to be displayed, and a non-trivial orientation would rotate the
  /// image out of the mapping Math §3 fixes.
  static const int orientation = 0x0112;

  /// IFD0 — the writer, `sphere_view <version>`.
  static const int software = 0x0131;

  /// IFD0 — file change time. Same value as [dateTimeOriginal] for us.
  static const int dateTime = 0x0132;

  /// IFD0 — offset of the EXIF sub-IFD.
  static const int exifIfdPointer = 0x8769;

  /// IFD0 — offset of the GPS sub-IFD.
  static const int gpsIfdPointer = 0x8825;

  /// EXIF IFD — the four ASCII digits of the EXIF version, unterminated.
  static const int exifVersion = 0x9000;

  /// EXIF IFD — when the shutter fired. The one timestamp readers agree on.
  static const int dateTimeOriginal = 0x9003;

  /// EXIF IFD — when the image was digitised.
  static const int dateTimeDigitized = 0x9004;

  /// EXIF IFD — stored image width.
  static const int pixelXDimension = 0xA002;

  /// EXIF IFD — stored image height.
  static const int pixelYDimension = 0xA003;

  /// GPS IFD — the four version bytes, `2.3.0.0`.
  static const int gpsVersionId = 0x0000;

  /// GPS IFD — `N` or `S`.
  static const int gpsLatitudeRef = 0x0001;

  /// GPS IFD — degrees/minutes/seconds, unsigned, sign carried by the ref.
  static const int gpsLatitude = 0x0002;

  /// GPS IFD — `E` or `W`.
  static const int gpsLongitudeRef = 0x0003;

  /// GPS IFD — degrees/minutes/seconds, unsigned.
  static const int gpsLongitude = 0x0004;

  /// GPS IFD — 0 above sea level, 1 below. The sign lives here because
  /// [gpsAltitude] is an unsigned rational.
  static const int gpsAltitudeRef = 0x0005;

  /// GPS IFD — metres, unsigned.
  static const int gpsAltitude = 0x0006;

  /// GPS IFD — hours/minutes/seconds UTC.
  static const int gpsTimeStamp = 0x0007;

  /// GPS IFD — `T` for true north, `M` for magnetic.
  ///
  /// Not decoration. The heading we write is a *true* bearing whichever source
  /// produced it — a plan's north is true north, and a magnetometer reading is
  /// declination-corrected by the platform before we ever see it — so writing
  /// `M` would tell a downstream tool to apply a declination correction that
  /// has already been applied.
  static const int gpsImgDirectionRef = 0x0010;

  /// GPS IFD — the direction the image centre faces, degrees.
  static const int gpsImgDirection = 0x0011;

  /// GPS IFD — `YYYY:MM:DD`, UTC.
  static const int gpsDateStamp = 0x001D;
}

/// EXIF/TIFF field types, by their numeric value.
abstract final class ExifType {
  /// 8-bit unsigned.
  static const int byte = 1;

  /// `NUL`-terminated 7-bit ASCII.
  static const int ascii = 2;

  /// 16-bit unsigned.
  static const int short = 3;

  /// 32-bit unsigned.
  static const int long = 4;

  /// Two 32-bit unsigned: numerator, denominator.
  static const int rational = 5;

  /// Raw bytes with a tag-defined meaning.
  static const int undefined = 7;

  /// Bytes per element, by type.
  static int sizeOf(int type) => switch (type) {
    byte || ascii || undefined => 1,
    short => 2,
    long => 4,
    rational => 8,
    _ => throw ArgumentError.value(type, 'type', 'unsupported EXIF type'),
  };
}

/// One field, ready to be laid out.
class _Entry {
  _Entry(this.tag, this.type, this.count, this.bytes);

  final int tag;
  final int type;
  final int count;

  /// The value, already encoded, unpadded. Goes inline when four bytes or
  /// fewer and into the data area otherwise.
  final Uint8List bytes;

  bool get isInline => bytes.length <= 4;
}

/// Builds a little-endian TIFF block for an `APP1`/EXIF segment.
///
/// Written by hand rather than pulled in from a package because the set of
/// fields is tiny and fixed, and because every EXIF library that writes has to
/// also read, which is the large and dangerous half. Ten tags across three IFDs
/// is less code than the binding would be.
class ExifBuilder {
  /// Creates an empty builder.
  ExifBuilder();

  final List<_Entry> _ifd0 = [];
  final List<_Entry> _exif = [];
  final List<_Entry> _gps = [];

  /// Adds an ASCII field. [value] is truncated to ASCII; the `NUL` terminator
  /// is added here and counted, as the spec requires.
  void _ascii(List<_Entry> ifd, int tag, String value) {
    final chars = <int>[
      for (final c in value.codeUnits) if (c >= 0x20 && c < 0x7F) c,
      0x00,
    ];
    ifd.add(_Entry(tag, ExifType.ascii, chars.length, Uint8List.fromList(chars)));
  }

  /// Adds a `SHORT`.
  void _short(List<_Entry> ifd, int tag, int value) {
    final b = ByteData(2)..setUint16(0, value, Endian.little);
    ifd.add(_Entry(tag, ExifType.short, 1, b.buffer.asUint8List()));
  }

  /// Adds a `LONG`.
  void _long(List<_Entry> ifd, int tag, int value) {
    final b = ByteData(4)..setUint32(0, value, Endian.little);
    ifd.add(_Entry(tag, ExifType.long, 1, b.buffer.asUint8List()));
  }

  /// Adds raw [values] as `BYTE`s.
  void _bytes(List<_Entry> ifd, int tag, List<int> values) {
    ifd.add(
      _Entry(tag, ExifType.byte, values.length, Uint8List.fromList(values)),
    );
  }

  /// Adds raw [values] as `UNDEFINED`.
  void _undefined(List<_Entry> ifd, int tag, List<int> values) {
    ifd.add(
      _Entry(tag, ExifType.undefined, values.length, Uint8List.fromList(values)),
    );
  }

  /// Adds one or more `RATIONAL`s from already-split numerator/denominator
  /// pairs.
  void _rationals(List<_Entry> ifd, int tag, List<(int, int)> values) {
    final b = ByteData(8 * values.length);
    for (var i = 0; i < values.length; i++) {
      b.setUint32(i * 8, values[i].$1, Endian.little);
      b.setUint32(i * 8 + 4, values[i].$2, Endian.little);
    }
    ifd.add(
      _Entry(tag, ExifType.rational, values.length, b.buffer.asUint8List()),
    );
  }

  /// Splits [degrees] into the unsigned degree/minute/second rationals EXIF
  /// wants for a coordinate.
  ///
  /// Seconds keep four decimal places, which is ~3 mm of latitude — well past
  /// what any receiver on a tablet delivers, and cheap.
  static List<(int, int)> dmsRationals(double degrees) {
    final total = degrees.abs();
    final d = total.floor();
    final minutesFull = (total - d) * 60.0;
    final m = minutesFull.floor();
    final seconds = (minutesFull - m) * 60.0;
    return [(d, 1), (m, 1), ((seconds * 10000).round(), 10000)];
  }

  /// A rational approximating [value] with [denominator] as the fixed divisor.
  static (int, int) fixedRational(double value, {int denominator = 1000}) =>
      ((value * denominator).round(), denominator);

  /// Encodes [metadata] as a TIFF block.
  ///
  /// The returned bytes start at the `II` byte-order mark, which is where an
  /// EXIF reader starts and what every offset inside is relative to.
  Uint8List buildTiff(PanoramaMetadata metadata) {
    _ifd0.clear();
    _exif.clear();
    _gps.clear();

    if (metadata.stationId != null) {
      _ascii(_ifd0, ExifTag.imageDescription, metadata.stationId!);
    }
    if (metadata.make != null) _ascii(_ifd0, ExifTag.make, metadata.make!);
    if (metadata.model != null) _ascii(_ifd0, ExifTag.model, metadata.model!);
    _short(_ifd0, ExifTag.orientation, 1);
    _ascii(_ifd0, ExifTag.software, metadata.software);
    final stamp = metadata.capturedAt;
    if (stamp != null) _ascii(_ifd0, ExifTag.dateTime, formatExifDateTime(stamp));

    // 0232 — the version this field set conforms to. Written as four ASCII
    // digits in an UNDEFINED field, which is the one place EXIF asks for a
    // string without a terminator.
    _undefined(_exif, ExifTag.exifVersion, '0232'.codeUnits);
    if (stamp != null) {
      _ascii(_exif, ExifTag.dateTimeOriginal, formatExifDateTime(stamp));
      _ascii(_exif, ExifTag.dateTimeDigitized, formatExifDateTime(stamp));
    }
    _long(_exif, ExifTag.pixelXDimension, metadata.fullWidth);
    _long(_exif, ExifTag.pixelYDimension, metadata.fullHeight);

    final location = metadata.location;
    final heading = metadata.heading;
    if (location != null || heading.isKnown) {
      _bytes(_gps, ExifTag.gpsVersionId, const [2, 3, 0, 0]);
    }
    if (location != null) {
      _ascii(_gps, ExifTag.gpsLatitudeRef, location.latitudeDegrees >= 0 ? 'N' : 'S');
      _rationals(_gps, ExifTag.gpsLatitude, dmsRationals(location.latitudeDegrees));
      _ascii(
        _gps,
        ExifTag.gpsLongitudeRef,
        location.longitudeDegrees >= 0 ? 'E' : 'W',
      );
      _rationals(
        _gps,
        ExifTag.gpsLongitude,
        dmsRationals(location.longitudeDegrees),
      );
      final altitude = location.altitudeMeters;
      if (altitude != null) {
        _bytes(_gps, ExifTag.gpsAltitudeRef, [altitude >= 0 ? 0 : 1]);
        _rationals(_gps, ExifTag.gpsAltitude, [fixedRational(altitude.abs())]);
      }
      final fixTime = location.timestampUtc?.toUtc();
      if (fixTime != null) {
        _rationals(_gps, ExifTag.gpsTimeStamp, [
          (fixTime.hour, 1),
          (fixTime.minute, 1),
          (fixTime.second, 1),
        ]);
        _ascii(
          _gps,
          ExifTag.gpsDateStamp,
          '${_pad(fixTime.year, 4)}:${_pad(fixTime.month, 2)}:'
          '${_pad(fixTime.day, 2)}',
        );
      }
    }
    if (heading.isKnown) {
      // True, not magnetic — see the note on the tag. Both of our sources are
      // already true bearings.
      _ascii(_gps, ExifTag.gpsImgDirectionRef, 'T');
      _rationals(_gps, ExifTag.gpsImgDirection, [
        fixedRational(heading.degrees!, denominator: 100),
      ]);
    }

    return _layout();
  }

  /// Formats [when] as EXIF's `YYYY:MM:DD HH:MM:SS`, in local time as the spec
  /// intends.
  static String formatExifDateTime(DateTime when) {
    final t = when.toLocal();
    return '${_pad(t.year, 4)}:${_pad(t.month, 2)}:${_pad(t.day, 2)} '
        '${_pad(t.hour, 2)}:${_pad(t.minute, 2)}:${_pad(t.second, 2)}';
  }

  static String _pad(int v, int width) => v.toString().padLeft(width, '0');

  Uint8List _layout() {
    // Sub-IFD pointers have to be present in IFD0 before the sizes are known,
    // and their values are only known once the sizes are. So they go in with a
    // placeholder and are patched afterwards — the entry is a fixed-width LONG
    // either way, so adding it does not change any offset.
    final hasExif = _exif.isNotEmpty;
    final hasGps = _gps.isNotEmpty;
    if (hasExif) _long(_ifd0, ExifTag.exifIfdPointer, 0);
    if (hasGps) _long(_ifd0, ExifTag.gpsIfdPointer, 0);

    for (final ifd in [_ifd0, _exif, _gps]) {
      ifd.sort((a, b) => a.tag.compareTo(b.tag));
    }

    int ifdBytes(List<_Entry> ifd) {
      var n = 2 + 12 * ifd.length + 4;
      for (final e in ifd) {
        if (!e.isInline) n += e.bytes.length + (e.bytes.length.isOdd ? 1 : 0);
      }
      return n;
    }

    const headerSize = 8;
    final ifd0Offset = headerSize;
    final exifOffset = ifd0Offset + ifdBytes(_ifd0);
    final gpsOffset = exifOffset + (hasExif ? ifdBytes(_exif) : 0);
    final total = gpsOffset + (hasGps ? ifdBytes(_gps) : 0);

    if (hasExif) _patchLong(_ifd0, ExifTag.exifIfdPointer, exifOffset);
    if (hasGps) _patchLong(_ifd0, ExifTag.gpsIfdPointer, gpsOffset);

    final out = Uint8List(total);
    final view = ByteData.sublistView(out);
    // "II" — little-endian. Chosen over "MM" for no reason beyond that every
    // device we ship on is little-endian, so the encoder and the debugger agree.
    out[0] = 0x49;
    out[1] = 0x49;
    view.setUint16(2, 0x002A, Endian.little);
    view.setUint32(4, ifd0Offset, Endian.little);

    _writeIfd(out, view, _ifd0, ifd0Offset);
    if (hasExif) _writeIfd(out, view, _exif, exifOffset);
    if (hasGps) _writeIfd(out, view, _gps, gpsOffset);
    return out;
  }

  void _patchLong(List<_Entry> ifd, int tag, int value) {
    for (final e in ifd) {
      if (e.tag == tag) {
        ByteData.sublistView(e.bytes).setUint32(0, value, Endian.little);
        return;
      }
    }
  }

  void _writeIfd(
    Uint8List out,
    ByteData view,
    List<_Entry> ifd,
    int offset,
  ) {
    view.setUint16(offset, ifd.length, Endian.little);
    var entry = offset + 2;
    var data = offset + 2 + 12 * ifd.length + 4;
    for (final e in ifd) {
      view.setUint16(entry, e.tag, Endian.little);
      view.setUint16(entry + 2, e.type, Endian.little);
      view.setUint32(entry + 4, e.count, Endian.little);
      if (e.isInline) {
        out.setRange(entry + 8, entry + 8 + e.bytes.length, e.bytes);
      } else {
        view.setUint32(entry + 8, data, Endian.little);
        out.setRange(data, data + e.bytes.length, e.bytes);
        data += e.bytes.length + (e.bytes.length.isOdd ? 1 : 0);
      }
      entry += 12;
    }
    // Next-IFD offset. Zero: we write no IFD1, because IFD1 is the thumbnail
    // and a thumbnail of an equirectangular panorama is a wide smear that some
    // galleries will show in preference to the real image.
    view.setUint32(offset + 2 + 12 * ifd.length, 0, Endian.little);
  }
}

/// A field read back out of an EXIF block.
class ExifField {
  /// Creates a field.
  const ExifField(this.tag, this.type, this.values);

  /// The tag number.
  final int tag;

  /// The EXIF type.
  final int type;

  /// Decoded values: `int` for the integer types, `String` for ASCII, and a
  /// `(num, den)` record per element for rationals.
  final List<Object> values;

  /// The ASCII value, terminator stripped, or `null` for a non-ASCII field.
  String? get asString =>
      type == ExifType.ascii && values.isNotEmpty ? values.first as String : null;

  /// The first value as an `int`, for the integer types.
  int? get asInt => values.isEmpty || values.first is! int
      ? null
      : values.first as int;

  /// The first rational as a `double`.
  double? get asDouble {
    if (values.isEmpty) return null;
    final v = values.first;
    if (v is int) return v.toDouble();
    if (v is (int, int)) return v.$2 == 0 ? null : v.$1 / v.$2;
    return null;
  }

  /// Degrees/minutes/seconds recombined into signed degrees, given [ref].
  double? asCoordinate(String? ref) {
    if (values.length < 3) return null;
    double part(int i) {
      final v = values[i];
      if (v is (int, int)) return v.$2 == 0 ? 0 : v.$1 / v.$2;
      return 0;
    }

    final magnitude = part(0) + part(1) / 60.0 + part(2) / 3600.0;
    return (ref == 'S' || ref == 'W') ? -magnitude : magnitude;
  }

  @override
  String toString() => 'ExifField(0x${tag.toRadixString(16)}, $values)';
}

/// An independent reader for the EXIF blocks this package writes.
///
/// "Independent" is the point (Phase 11 §2's first test): it walks the bytes
/// with its own offset arithmetic and its own type table rather than sharing
/// any structure with [ExifBuilder], so a round trip through the two proves the
/// file is right rather than proving that one piece of code agrees with itself.
/// It reads both byte orders even though we only write one, for the same
/// reason.
class ExifReader {
  /// Parses a TIFF block — the bytes after the `Exif\0\0` header.
  ///
  /// Returns `null` if the block is not a TIFF at all. Malformed entries are
  /// skipped rather than thrown on: a reader that gives up on the whole block
  /// because of one bad field is how a single vendor's odd tag hides every
  /// other tag in the file.
  static Map<int, ExifField>? parseTiff(Uint8List tiff) {
    if (tiff.length < 8) return null;
    final Endian endian;
    if (tiff[0] == 0x49 && tiff[1] == 0x49) {
      endian = Endian.little;
    } else if (tiff[0] == 0x4D && tiff[1] == 0x4D) {
      endian = Endian.big;
    } else {
      return null;
    }
    final view = ByteData.sublistView(tiff);
    if (view.getUint16(2, endian) != 0x002A) return null;

    final fields = <int, ExifField>{};
    final visited = <int>{};
    void readIfd(int offset) {
      if (offset <= 0 || offset + 2 > tiff.length) return;
      if (!visited.add(offset)) return; // a pointer loop is a malformed file
      final count = view.getUint16(offset, endian);
      if (offset + 2 + 12 * count + 4 > tiff.length) return;
      for (var i = 0; i < count; i++) {
        final entry = offset + 2 + 12 * i;
        final tag = view.getUint16(entry, endian);
        final type = view.getUint16(entry + 2, endian);
        final n = view.getUint32(entry + 4, endian);
        final int size;
        try {
          size = ExifType.sizeOf(type) * n;
        } on ArgumentError {
          continue; // a type we do not know about; skip the field, keep going
        }
        final valueOffset =
            size <= 4 ? entry + 8 : view.getUint32(entry + 8, endian);
        if (valueOffset + size > tiff.length) continue;
        final values = _decode(view, endian, type, n, valueOffset);
        fields[tag] = ExifField(tag, type, values);
        if (tag == ExifTag.exifIfdPointer || tag == ExifTag.gpsIfdPointer) {
          readIfd(view.getUint32(entry + 8, endian));
        }
      }
    }

    readIfd(view.getUint32(4, endian));
    return fields;
  }

  static List<Object> _decode(
    ByteData view,
    Endian endian,
    int type,
    int count,
    int offset,
  ) {
    switch (type) {
      case ExifType.ascii:
        final chars = <int>[];
        for (var i = 0; i < count; i++) {
          final c = view.getUint8(offset + i);
          if (c == 0) break;
          chars.add(c);
        }
        return [String.fromCharCodes(chars)];
      case ExifType.byte:
      case ExifType.undefined:
        return [for (var i = 0; i < count; i++) view.getUint8(offset + i)];
      case ExifType.short:
        return [
          for (var i = 0; i < count; i++) view.getUint16(offset + i * 2, endian),
        ];
      case ExifType.long:
        return [
          for (var i = 0; i < count; i++) view.getUint32(offset + i * 4, endian),
        ];
      case ExifType.rational:
        return [
          for (var i = 0; i < count; i++)
            (
              view.getUint32(offset + i * 8, endian),
              view.getUint32(offset + i * 8 + 4, endian),
            ),
        ];
      default:
        return const [];
    }
  }
}
