import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../../util/archive_exception.dart';
import '../../util/chunked_sink.dart';
import '../../util/input_memory_stream.dart';
import '../../util/output_memory_stream.dart';
import '../bzip2_decoder.dart';
import '../bzip2_encoder.dart';
import 'bz2_bit_reader.dart';
import 'bzip2.dart';

/// {@macro archive.codecs.general}
///
/// {@macro archive.codecs.without_on_done}
/// {@macro archive.yield_codecs.decoder}
/// {@macro archive.converters.encoder}
class BZip2Codec extends Codec<List<int>, List<int>> {
  /// Checks the CRC of every block and of the stream. On by default: a stream
  /// reader releases the compressed bytes before the check runs, so it cannot
  /// be run again later
  final bool verify;

  /// Hundreds of thousands of bytes a block, one to nine
  final int blockSize100k;

  const BZip2Codec({this.verify = true, this.blockSize100k = 9});

  @override
  BZip2DecoderConverter get decoder => BZip2DecoderConverter(verify: verify);

  @override
  BZip2EncoderConverter get encoder =>
      BZip2EncoderConverter(blockSize100k: blockSize100k);
}

/// {@macro archive.codecs.general}
///
/// {@macro archive.codecs.without_on_done}
/// {@macro archive.yield_codecs.decoder}
/// {@macro archive.converters.encoder}
const bzip2Codec = BZip2Codec();

/// {@macro archive.codecs.without_on_done}
/// {@macro archive.yield_codecs.decoder}
class BZip2DecoderConverter extends ChunkedConverter {
  final bool verify;

  const BZip2DecoderConverter({this.verify = true});

  /// {@macro archive.codecs.chunked_conversion}
  @override
  ByteConversionSink startChunkedConversion(Sink<List<int>> sink) =>
      FailOnceSink(BZip2ChunkedDecoder(
          sink is ByteConversionSink ? sink : ByteConversionSink.from(sink),
          verify: verify));
}

/// {@macro archive.codecs.without_on_done}
/// {@macro archive.converters.encoder}
class BZip2EncoderConverter extends ChunkedConverter {
  final int blockSize100k;

  const BZip2EncoderConverter({this.blockSize100k = 9});

  @override
  ByteConversionSink startChunkedConversion(Sink<List<int>> sink) =>
      FailOnceSink(BZip2ChunkedEncoder(
          sink is ByteConversionSink ? sink : ByteConversionSink.from(sink),
          blockSize100k: blockSize100k));
}

/// Writes a bzip2 archive over data that arrives in pieces.
///
/// Buffers data until a block is full, then encodes it.
/// This guarantees the exact same output as calling `encodeBytes` on
/// [BZip2Encoder]. It only keeps one block in memory at a time, regardless of
/// the overall file size.
class BZip2ChunkedEncoder extends ChunkedSink {
  final int blockSize100k;

  BZip2ChunkedEncoder(super.output, {this.blockSize100k = 9}) {
    if (blockSize100k < 1 || blockSize100k > 9) {
      throw ArgumentError.value(
          blockSize100k, 'blockSize100k', 'Must be 1 to 9');
    }
  }

  late final _out = SinkOutputStream(output);
  final _encoder = BZip2Encoder();
  var _started = false;

  @override
  void step() {
    _begin();
    while (available > 0) {
      final piece = view(available);
      var at = 0;
      var full = false;
      while (at < piece.length && !full) {
        full = _encoder.addByte(piece[at]);
        at++;
      }
      skip(at);
      if (full) {
        _endBlock();
      }
    }
  }

  @override
  void finish() {
    _begin();
    // Skip writing if no bytes reached this block. This indicates it's the
    // last block or it doesn't exist at all
    _endBlock();
    _encoder.endStream();
    _out.flush();
  }

  void _endBlock() {
    if (!_encoder.endBlock()) {
      throw ArchiveException('bzip2: a block could not be coded');
    }
  }

  void _begin() {
    if (_started) {
      return;
    }
    _started = true;
    _encoder.beginStream(_out, blockSize100k: blockSize100k);
  }
}

/// Decodes a bzip2 stream chunk by chunk.
///
/// bzip2 lacks length headers and byte alignment, so blocks are found by
/// searching for markers. This class holds just one block in and one block out
/// at a time to minimize memory usage.
///
/// Block data can sometimes accidentally match the marker pattern. When we hit
/// a fake marker, decoding fails and we resume scanning. Because of this, we
/// wait to emit any output until the entire block is successfully decoded.
class BZip2ChunkedDecoder extends ChunkedSink {
  final bool verify;

  BZip2ChunkedDecoder(super.output, {this.verify = true});

  late final _sink = SinkOutputStream(output);
  final _decoder = BZip2Decoder();

  _Stage _stage = _Stage.signature;

  /// Current bit offset in the pending data. Once a block is done,
  /// we drop the bytes we've already read
  var _bitAt = 0;

  final _scan = Bz2MarkerScan();

  var _retryAt = 0;

  var _maxBlockBytes = 0;

  var _combinedCrc = 0;
  var _storedBlockCrc = 0;
  var _streams = 0;

  @override
  void step() {
    while (true) {
      switch (_stage) {
        case _Stage.signature:
          // After a stream bzip2 1.0.8 reads BZh and a digit from 1 to 9.
          // If byte differs, bzip2 ignores the rest and exits with 0. The rest
          // is trailing garbage
          if (_streams > 0 &&
              BZip2.breaksSignature(view(available < 4 ? available : 4))) {
            _stage = _Stage.trailing;
            continue;
          }
          if (available < 4) {
            // Fails immediately on a bad signature byte, instead of waiting
            // for more data
            final head = view(available);
            for (var i = 0; i < head.length; i++) {
              if (head[i] != BZip2.bzhSignature[i]) {
                throw ArchiveException('bzip2: not a bzip2 archive');
              }
            }
            return;
          }
          _readSignature();
        case _Stage.blockMarker:
          if (!_has(48)) {
            return;
          }
          _readBlockMarker();
        case _Stage.blockCrc:
          if (!_has(32)) {
            return;
          }
          _storedBlockCrc = _readBits(32);
          // The block ends at the next marker, which we start looking
          // for from here
          _resetScan();
          _stage = _Stage.blockBody;
        case _Stage.blockBody:
          if (!_readBlockBody()) {
            return;
          }
          if (unitAtATime) {
            return;
          }
        case _Stage.streamCrc:
          if (!_has(32)) {
            return;
          }
          _readStreamCrc();
        case _Stage.streamEnd:
          // Support concatenated archives (standard 'bzip2 -d' behavior).
          // We just keep reading until the input ends
          if (available == 0) {
            return;
          }
          _stage = _Stage.signature;
        case _Stage.trailing:
          skip(available);
          return;
      }
    }
  }

  @override
  void finish() {
    if (_stage == _Stage.blockBody && _retryAt > 0) {
      _retryAt = 0;
      _resetScan();
      step();
    }
    if (_stage != _Stage.trailing &&
        (_stage != _Stage.streamEnd || available != 0)) {
      throw ArchiveException('bzip2: unexpected end of archive');
    }
    if (_streams == 0) {
      throw ArchiveException('bzip2: no archive, the input is empty');
    }
    _sink.flush();
  }

  /// True if we have at least [count] bits left to read
  bool _has(int count) => (_bitAt + count + 7) >> 3 <= available;

  /// Reads [count] bits (max 32) and moves forward
  int _readBits(int count) {
    final bytes = view(available);
    var value = 0;
    for (var i = 0; i < count; i++) {
      final at = _bitAt + i;
      value = ((value << 1) | ((bytes[at >> 3] >> (7 - (at & 7))) & 1)) &
          0xffffffff;
    }
    _bitAt += count;
    return value;
  }

  void _readSignature() {
    final field = view(4);
    if (field[0] != BZip2.bzhSignature[0] ||
        field[1] != BZip2.bzhSignature[1] ||
        field[2] != BZip2.bzhSignature[2]) {
      throw ArchiveException('bzip2: not a bzip2 archive');
    }
    final blockSize100k = field[3] - BZip2.hdr0;
    if (blockSize100k < 1 || blockSize100k > 9) {
      throw ArchiveException(
          'bzip2: the signature does not have a valid block size');
    }
    skip(4);
    _maxBlockBytes = blockSize100k * 250000 + 65536;
    _decoder.beginStream(blockSize100k);
    _combinedCrc = 0;
    _bitAt = 0;
    _resetScan();
    _stage = _Stage.blockMarker;
  }

  void _readBlockMarker() {
    final high = _readBits(24);
    final low = _readBits(24);
    if (high == _compressedHigh && low == _compressedLow) {
      _stage = _Stage.blockCrc;
      return;
    }
    if (high == _eosHigh && low == _eosLow) {
      _stage = _Stage.streamCrc;
      return;
    }
    throw ArchiveException('bzip2: a block does not carry a valid marker');
  }

  /// Decodes the block starting at [_bitAt] once we've found its end marker.
  /// Returns false if we're still waiting for more data.
  bool _readBlockBody() {
    while (true) {
      final limit = (_bitAt >> 3) + _maxBlockBytes + 7;
      if (!_scan.locate(view(available), min(available, limit))) {
        if (available - (_bitAt >> 3) > _maxBlockBytes) {
          throw ArchiveException('bzip2: a block is malformed');
        }
        return false;
      }
      if (available < _retryAt) {
        continue;
      }
      final held = OutputMemoryStream();
      _sink.divert = held;
      var crc = 0;
      try {
        crc = _decodeInto();
      } on _NeedMore {
        // False alarm: the data accidentally looked like a marker.
        // We skip it and slide the window forward by one bit. Next decode waits
        // until buffered input doubles or finish() retries
        _sink.divert = null;
        _retryAt = available * 2;
        continue;
      } finally {
        _sink.divert = null;
      }
      if (crc < 0) {
        throw ArchiveException('bzip2: a block is malformed');
      }
      if (verify && crc != _storedBlockCrc) {
        throw ArchiveChecksumException('bzip2: block checksum does not match');
      }
      _combinedCrc = ((_combinedCrc << 1) | (_combinedCrc >> 31)) & 0xffffffff;
      _combinedCrc ^= crc;
      _emit(held.getBytes());
      _drop();
      _retryAt = 0;
      _stage = _Stage.blockMarker;
      return true;
    }
  }

  /// Decodes all received data for the block, leaving [_bitAt] exactly
  /// at the start of the next block
  int _decodeInto() {
    final bytes = view(available);
    final from = _bitAt >> 3;
    final input = _BitInput(Uint8List.sublistView(bytes, from));
    final reader = Bz2BitReader(input, readPastEnd: true);
    final offset = _bitAt & 7;
    if (offset > 0) {
      reader.readBits(offset);
    }
    final crc = _decoder.decodeBlock(reader, _sink);
    _bitAt = (from << 3) + (input.position << 3) - reader.bitsLeft;
    return crc;
  }

  void _readStreamCrc() {
    final stored = _readBits(32);
    if (verify && stored != _combinedCrc) {
      throw ArchiveChecksumException('bzip2: stream checksum does not match');
    }
    // After the checksum, we skip padding to the end of the byte,
    // followed by the rest of the input
    _bitAt = (_bitAt + 7) & ~7;
    _drop();
    _streams++;
    _stage = _Stage.streamEnd;
  }

  /// Decoding can inflate a 900 KiB block into tens of megabytes.
  /// We emit the result in standard chunks to match other codecs
  void _emit(Uint8List bytes) {
    for (var at = 0; at < bytes.length; at += _piece) {
      final end = at + _piece < bytes.length ? at + _piece : bytes.length;
      output.add(Uint8List.sublistView(bytes, at, end));
    }
  }

  /// Removes fully read bytes from the buffer and resets the marker search
  void _drop() {
    final bytes = _bitAt >> 3;
    if (bytes > 0) {
      skip(bytes);
      _bitAt -= bytes << 3;
    }
    _resetScan();
  }

  void _resetScan() {
    _scan.start(_bitAt);
  }
}

/// Finds bzip2 block and end-of-stream markers in input that arrives in pieces
class Bz2MarkerScan {
  /// Where the search for the next marker has reached, and the last 48 bits it
  /// has seen, split into two 24-bit halves to stay within 32 bits
  var _scanAt = 0;
  var _scanHigh = 0;
  var _scanLow = 0;
  var _scanFilled = 0;

  /// Index of the next bit [locate] will read.
  int get position => _scanAt;

  /// Restarts the marker search from bit [at].
  void start(int at) {
    _scanAt = at;
    _resetRegister();
  }

  void _resetRegister() {
    _scanHigh = 0;
    _scanLow = 0;
    _scanFilled = 0;
  }

  /// Looks for the next block or end-of-stream marker.
  /// Returns false if not found yet
  bool locate(Uint8List bytes, int available) {
    final end = available << 3;
    while (_scanAt < end) {
      final bit = (bytes[_scanAt >> 3] >> (7 - (_scanAt & 7))) & 1;
      _scanHigh = ((_scanHigh << 1) | (_scanLow >> 23)) & 0xffffff;
      _scanLow = ((_scanLow << 1) | bit) & 0xffffff;
      _scanAt++;
      if (_scanFilled < 48) {
        _scanFilled++;
        // The 48th bit completes the first window, so that one is compared too
        if (_scanFilled < 48) {
          continue;
        }
      }
      if ((_scanHigh == _compressedHigh && _scanLow == _compressedLow) ||
          (_scanHigh == _eosHigh && _scanLow == _eosLow)) {
        return true;
      }
    }
    return false;
  }
}

const _compressedHigh = 0x314159;
const _compressedLow = 0x265359;
const _eosHigh = 0x177245;
const _eosLow = 0x385090;

/// Thrown when block decoder needs more input than has arrived so far
class _NeedMore implements Exception {
  const _NeedMore();
}

class _BitInput extends InputMemoryStream {
  _BitInput(super.bytes);

  @override
  int readByte() {
    if (isEOS) {
      throw const _NeedMore();
    }
    return super.readByte();
  }
}

/// Maximum size of one output chunk is 64 KiB, same as gzip and xz
const _piece = 1 << 16;

enum _Stage {
  signature,
  blockMarker,
  blockCrc,
  blockBody,
  streamCrc,
  streamEnd,
  trailing,
}
