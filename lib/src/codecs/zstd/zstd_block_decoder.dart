import 'dart:typed_data';

import '../../util/archive_exception.dart';
import 'zstd_constants.dart';
import 'zstd_dictionary.dart';
import 'zstd_literals.dart';
import 'zstd_sequences.dart';
import 'zstd_window.dart';

class ZstdBlockException extends ArchiveException {
  ZstdBlockException(super.message);
  @override
  String toString() => 'ZstdBlockException: $message';
}

/// Decodes the blocks of one frame. The entropy tables it holds persist from
/// one block to the next. Repeat modes refer back to them
class ZstdBlockDecoder {
  final ZstdLiterals _literals = ZstdLiterals();
  final ZstdSequences _sequences = ZstdSequences();

  /// Set by [decode] to whether the block just read was the frame's last
  bool isLast = false;

  void reset(ZstdDictionary? dictionary) {
    _literals.reset();
    _sequences.reset();
    isLast = false;
    if (dictionary != null && dictionary.hasEntropy) {
      _literals.loadDictionary(dictionary);
      _sequences.loadDictionary(dictionary);
    }
  }

  /// Reads the block at [start] into [window] and returns its total size
  /// Decodes one block. [body] and [bodyAt] name where its payload is, which a
  /// streamed frame points at its own storage rather than copying
  int decode(Uint8List src, int start, int end, ZstdWindow window,
      Uint32List rep, int blockSizeMax,
      {Uint8List? body, int bodyAt = 0}) {
    if (start + 3 > end) {
      _blockHeaderIsTruncated();
    }
    final header = src[start] | (src[start + 1] << 8) | (src[start + 2] << 16);
    isLast = header & 1 != 0;
    final type = (header >> 1) & 3;
    final size = header >> 3;
    final int at;
    if (body != null) {
      src = body;
      at = bodyAt;
      end = bodyAt + (type == zstdBlockRle ? 1 : size);
    } else {
      at = start + 3;
    }

    if (size > blockSizeMax) {
      _blockTooLarge(size);
    }

    switch (type) {
      case zstdBlockRaw:
        if (at + size > end) {
          _rawBlockIsTruncated();
        }
        window.reserve(size);
        final out = window.position;
        window.buffer.setRange(out, out + size, src, at);
        window.position = out + size;
        return 3 + size;

      case zstdBlockRle:
        if (at >= end) {
          _rleBlockByteIs();
        }
        window.reserve(size);
        final out = window.position;
        window.buffer.fillRange(out, out + size, src[at]);
        window.position = out + size;
        return 4;

      case zstdBlockCompressed:
        if (at + size > end) {
          _compressedBlockIsTruncated();
        }
        final blockEnd = at + size;
        // Literals are stored after the space reserved for this block's output,
        // so the sequence loop reads and writes through one view
        window.reserve(blockSizeMax * 2 + zstdCopySlack * 2);
        final literalsSize = _literals.decode(src, at, blockEnd, blockSizeMax,
            window.buffer, window.position + blockSizeMax + zstdCopySlack);
        _sequences.decode(src, at + literalsSize, blockEnd, _literals, window,
            rep, blockSizeMax);
        return 3 + size;

      default:
        _reservedBlockType();
    }
  }
}

/// Every throw here is moved out of line: inline, the exception's own
/// construction puts an allocation and a call into a function that is
/// otherwise straight-line work, and costs registers where nothing throws
@pragma('vm:never-inline')
Never _blockHeaderIsTruncated() =>
    throw ZstdBlockException('Block header is truncated');

@pragma('vm:never-inline')
Never _rawBlockIsTruncated() =>
    throw ZstdBlockException('Raw block is truncated');

@pragma('vm:never-inline')
Never _rleBlockByteIs() =>
    throw ZstdBlockException('RLE block byte is missing');

@pragma('vm:never-inline')
Never _compressedBlockIsTruncated() =>
    throw ZstdBlockException('Compressed block is truncated');

@pragma('vm:never-inline')
Never _reservedBlockType() => throw ZstdBlockException('Reserved block type');

@pragma('vm:never-inline')
Never _blockTooLarge(int size) =>
    throw ZstdBlockException('Block of $size bytes exceeds the block limit');
