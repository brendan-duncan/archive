import 'dart:typed_data';

import 'archive_exception.dart';
import 'input_stream.dart';
import 'output_stream.dart';

/// Passes writes on to [output] until more than [maxLength] bytes have been
/// written, then throws.
///
/// Decoders that turn an [ArchiveException] into a false return would hide
/// the limit being reached, so [decodeLimited] checks [exceeded] afterwards.
class LimitedOutputStream extends OutputStream {
  final OutputStream output;
  final int maxLength;
  int _written = 0;
  bool exceeded = false;

  LimitedOutputStream(this.output, this.maxLength)
      : super(byteOrder: output.byteOrder);

  void _add(int count) {
    _written += count;
    if (_written > maxLength) {
      exceeded = true;
      throw ArchiveException(
          'The decoded data is larger than the $maxLength bytes allowed');
    }
  }

  @override
  int get length => output.length;

  @override
  void open() => output.open();

  @override
  Future<void> close() => output.close();

  @override
  void closeSync() => output.closeSync();

  @override
  bool get isOpen => output.isOpen;

  @override
  void clear() => output.clear();

  @override
  void flush() => output.flush();

  @override
  void writeByte(int value) {
    _add(1);
    output.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _add(length ?? bytes.length);
    output.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    _add(stream.length);
    output.writeStream(stream);
  }

  @override
  void writeBackReference(int distance, int count) {
    _add(count);
    output.writeBackReference(distance, count);
  }

  @override
  Uint8List subset(int start, [int? end]) => output.subset(start, end);
}

/// Runs [decode] on [output], or on [output] limited to [maxLength] bytes
/// when it is given, throwing an [ArchiveException] if the limit was passed.
bool decodeLimited(OutputStream output, int? maxLength,
    bool Function(OutputStream output) decode) {
  if (maxLength == null) {
    return decode(output);
  }
  if (maxLength < 0) {
    throw ArgumentError.value(maxLength, 'maxOutputSize', 'is negative');
  }
  final limited = LimitedOutputStream(output, maxLength);
  final bool result;
  try {
    result = decode(limited);
  } catch (_) {
    if (limited.exceeded) {
      throw ArchiveException(
          'The decoded data is larger than the $maxLength bytes allowed');
    }
    rethrow;
  }
  if (limited.exceeded) {
    throw ArchiveException(
        'The decoded data is larger than the $maxLength bytes allowed');
  }
  return result;
}
