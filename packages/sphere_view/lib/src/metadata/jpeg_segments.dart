import 'dart:convert';
import 'dart:typed_data';

/// One JPEG marker segment: the marker byte and its payload, length prefix
/// stripped.
///
/// Only the segments *before* the start of scan are modelled. Everything from
/// `SOS` onwards — the scan header, the entropy-coded data with its stuffed
/// `FF 00` bytes and restart markers, and `EOI` — is carried verbatim as
/// [JpegFile.scan] and never interpreted. That split is deliberate: this file
/// exists to insert and replace metadata, and the one way to corrupt a JPEG
/// while doing that is to re-encode something you did not need to touch.
class JpegSegment {
  /// Creates a segment.
  const JpegSegment(this.marker, this.payload);

  /// The second byte of the marker — `0xE0` for `APP0`, `0xE1` for `APP1`, and
  /// so on. The leading `0xFF` is implied.
  final int marker;

  /// The segment body, **excluding** the two-byte big-endian length that
  /// precedes it on disk. Empty for a marker that carries no payload.
  final Uint8List payload;

  /// `SOI`, the two bytes every JPEG starts with.
  static const int soi = 0xD8;

  /// `EOI`.
  static const int eoi = 0xD9;

  /// `SOS` — start of scan. Everything after it is entropy-coded.
  static const int sos = 0xDA;

  /// `APP0`, which is where a JFIF header lives.
  static const int app0 = 0xE0;

  /// `APP1`, which is where both EXIF and XMP live.
  static const int app1 = 0xE1;

  /// The `APP1` header that identifies an EXIF segment, `NUL`-padded.
  static final Uint8List exifHeader = Uint8List.fromList(
    'Exif'.codeUnits + [0x00, 0x00],
  );

  /// The `APP1` header that identifies a standard (non-extended) XMP packet.
  ///
  /// The trailing `NUL` is part of the identifier, not a separator, and a
  /// reader that matches without it will also match `…/xap/1.0/Extension\0` —
  /// the *extended* XMP segment, which is a different thing and must not be
  /// replaced by this one.
  static final Uint8List xmpHeader = Uint8List.fromList(
    'http://ns.adobe.com/xap/1.0/'.codeUnits + [0x00],
  );

  /// The largest payload a segment can hold: the length field counts itself,
  /// so `2 + payload.length` must fit in 16 bits.
  static const int maxPayloadBytes = 0xFFFF - 2;

  /// Whether this is the `APP1` segment holding EXIF.
  bool get isExif => marker == app1 && _startsWith(payload, exifHeader);

  /// Whether this is the `APP1` segment holding the main XMP packet.
  bool get isXmp => marker == app1 && _startsWith(payload, xmpHeader);

  /// The XMP packet text.
  ///
  /// Decoded as UTF-8, which is what the XMP specification mandates and what
  /// the packet's own header declares. `String.fromCharCodes` would appear to
  /// work — our own packet is ASCII apart from the byte-order mark the
  /// `<?xpacket?>` wrapper carries — and would then quietly mangle the first
  /// packet anybody else wrote, or the first station id with an accent in it.
  String get xmpPacket {
    if (!isXmp) throw StateError('not an XMP APP1 segment');
    return utf8.decode(
      Uint8List.sublistView(payload, xmpHeader.length),
      // A malformed byte is not a reason to refuse to read a panorama: this is
      // the one place the package is handed arbitrary bytes from outside it.
      allowMalformed: true,
    );
  }

  /// The TIFF block inside an EXIF segment — the bytes an EXIF parser starts
  /// at, with the `Exif\0\0` header removed.
  Uint8List get exifTiff {
    if (!isExif) throw StateError('not an EXIF APP1 segment');
    return Uint8List.sublistView(payload, exifHeader.length);
  }

  /// Builds an `APP1` segment from [header] and [body].
  ///
  /// Throws [ArgumentError] when the result would not fit in one segment.
  /// Phase 11 §2 says to assert this rather than assume it: our packet is
  /// about 1 KB, but a caller that starts writing a long `ImageDescription`
  /// would otherwise produce a file whose length field has silently wrapped,
  /// which is not a JPEG any more and does not announce itself as one.
  factory JpegSegment.buildApp1(Uint8List header, Uint8List body) {
    final payload = Uint8List(header.length + body.length)
      ..setRange(0, header.length, header)
      ..setRange(header.length, header.length + body.length, body);
    if (payload.length > maxPayloadBytes) {
      throw ArgumentError(
        'an APP1 segment holds at most $maxPayloadBytes bytes and this one '
        'needs ${payload.length}. A packet this large needs the extended-XMP '
        'split, which this package deliberately does not implement — the '
        'GPano block is ~1 KB and anything near 64 KB means something is '
        'wrong upstream, not that a bigger segment is needed.',
      );
    }
    return JpegSegment(app1, payload);
  }

  static bool _startsWith(Uint8List haystack, Uint8List needle) {
    if (haystack.length < needle.length) return false;
    for (var i = 0; i < needle.length; i++) {
      if (haystack[i] != needle[i]) return false;
    }
    return true;
  }

  @override
  String toString() => 'JpegSegment(0x${marker.toRadixString(16)}, '
      '${payload.length} bytes)';
}

/// Thrown when a file that was supposed to be a JPEG is not one.
class JpegFormatException implements Exception {
  /// Creates the exception.
  const JpegFormatException(this.message);

  /// What was wrong.
  final String message;

  @override
  String toString() => 'JpegFormatException: $message';
}

/// A JPEG split into its leading marker segments and its untouched scan.
///
/// The only operations offered are the ones Phase 11 §2 needs — insert a
/// segment immediately after `SOI`, and replace an existing one — because
/// those are the only ones that can be performed without decoding anything.
class JpegFile {
  const JpegFile._(this.segments, this.scan);

  /// The marker segments between `SOI` and the start of scan, in file order.
  final List<JpegSegment> segments;

  /// Everything from the `SOS` marker to the end of the file, byte for byte.
  final Uint8List scan;

  /// Splits [bytes] at the start of scan.
  ///
  /// Throws [JpegFormatException] if [bytes] is not a JPEG or is truncated.
  factory JpegFile.parse(Uint8List bytes) {
    if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != JpegSegment.soi) {
      throw const JpegFormatException('the file does not begin with SOI');
    }
    final segments = <JpegSegment>[];
    var i = 2;
    while (true) {
      if (i + 1 >= bytes.length) {
        throw const JpegFormatException(
          'the file ended in the middle of the marker segments, before any '
          'scan data',
        );
      }
      if (bytes[i] != 0xFF) {
        throw JpegFormatException(
          'expected a marker at byte $i but found '
          '0x${bytes[i].toRadixString(16)}',
        );
      }
      // Any number of 0xFF fill bytes may precede a marker (ITU T.81 B.1.1.3).
      var j = i;
      while (j < bytes.length && bytes[j] == 0xFF) {
        j++;
      }
      if (j >= bytes.length) {
        throw const JpegFormatException('the file ended on a fill byte');
      }
      final marker = bytes[j];
      if (marker == JpegSegment.sos) {
        // The scan starts at the marker itself, fill bytes dropped — they are
        // padding, and reproducing them exactly is not required of a writer.
        return JpegFile._(segments, Uint8List.sublistView(bytes, j - 1));
      }
      if (marker == JpegSegment.eoi) {
        // A JPEG with no scan at all. Legal to represent; nothing to insert
        // into, but the caller gets a faithful round trip.
        return JpegFile._(segments, Uint8List.sublistView(bytes, j - 1));
      }
      if (j + 2 >= bytes.length) {
        throw const JpegFormatException('a segment has no length field');
      }
      final length = (bytes[j + 1] << 8) | bytes[j + 2];
      if (length < 2 || j + 1 + length > bytes.length) {
        throw JpegFormatException(
          'segment 0x${marker.toRadixString(16)} declares $length bytes, '
          'which runs past the end of the file',
        );
      }
      segments.add(
        JpegSegment(
          marker,
          Uint8List.sublistView(bytes, j + 3, j + 1 + length),
        ),
      );
      i = j + 1 + length;
    }
  }

  /// The single XMP segment, or `null` when the file has none.
  JpegSegment? get xmpSegment {
    for (final s in segments) {
      if (s.isXmp) return s;
    }
    return null;
  }

  /// The single EXIF segment, or `null` when the file has none.
  JpegSegment? get exifSegment {
    for (final s in segments) {
      if (s.isExif) return s;
    }
    return null;
  }

  /// Returns a copy with every segment matching [where] removed and [replacements]
  /// inserted **immediately after `SOI`**, ahead of any `APP0`/JFIF or
  /// `APP1`/EXIF the encoder wrote.
  ///
  /// Position matters and is not cosmetic (Phase 11 §2). Some readers only scan
  /// the first few segments before deciding a file has no XMP, and a packet
  /// appended after the quantisation tables is a packet those readers will not
  /// find. Removing first rather than appending matters for the same reason
  /// from the other direction: two XMP packets in one file make several readers
  /// ignore both, so a second write must replace rather than accumulate.
  JpegFile withLeadingSegments(
    List<JpegSegment> replacements, {
    required bool Function(JpegSegment) where,
  }) {
    final kept = [
      for (final s in segments)
        if (!where(s)) s,
    ];
    return JpegFile._([...replacements, ...kept], scan);
  }

  /// Re-serialises to a valid JPEG.
  Uint8List toBytes() {
    var total = 2 + scan.length;
    for (final s in segments) {
      total += 4 + s.payload.length;
    }
    final out = Uint8List(total);
    var i = 0;
    out[i++] = 0xFF;
    out[i++] = JpegSegment.soi;
    for (final s in segments) {
      final length = s.payload.length + 2;
      out[i++] = 0xFF;
      out[i++] = s.marker;
      out[i++] = (length >> 8) & 0xFF;
      out[i++] = length & 0xFF;
      out.setRange(i, i + s.payload.length, s.payload);
      i += s.payload.length;
    }
    out.setRange(i, i + scan.length, scan);
    return out;
  }
}
