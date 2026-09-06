import 'dart:typed_data';

import '../../util/input_stream.dart';
import '../../util/output_stream.dart';
import 'range_decoder.dart';

// LZMA is not well specified, but useful sources to understanding it can be found at:
// https://github.com/jljusten/LZMA-SDK/blob/master/DOC/lzma-specification.txt
// https://en.wikipedia.org/wiki/Lempel%E2%80%93Ziv%E2%80%93Markov_chain_algorithm
// https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/lib/xz

// Maximum number of position states supported by the LZMA specification,
// which allows position bits in the range 0-4.
const _maxPositionStates = 1 << 4;

// Number of probability entries used per literal state.
const _literalBlockSize = 0x300;

// Maps the decoder state to the state that follows a literal packet, indexed
// by [_LzmaState.index].
const _literalNextState = <int>[0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 4, 5];

/// LZMA compression decoder, used by [XZDecoder]
class LzmaDecoder {
  // Compressed data.
  final _rc = RangeDecoder();

  // Number of bits used from [_dictionary] length for probabilities.
  int _positionBits = 2;

  // Number of bits used from [_dictionary] length for literal probabilities.
  int _literalPositionBits = 0;

  // Number of bits used from [_dictionary] for literal probabilities.
  int _literalContextBits = 3;

  // Cached masks
  int _contextShift = 5; // 8 - _literalContextBits
  int _literalPosMask = 0; // (1 << _literalPositionBits) - 1

  // Bit probabilities for determining which LZMA packet is present.
  final _nonLiteralTables = <RangeDecoderTable>[];
  late final RangeDecoderTable _repeatTable;
  late final RangeDecoderTable _repeat0Table;
  final _longRepeat0Tables = <RangeDecoderTable>[];
  late final RangeDecoderTable _repeat1Table;
  late final RangeDecoderTable _repeat2Table;

  // Bit probabilities when decoding literals. Each literal state occupies a
  // block of [_literalBlockSize] entries: 0x000-0x0ff for literals that follow
  // a literal, 0x100-0x1ff and 0x200-0x2ff for literals that follow a match,
  // selected by the corresponding bit of the match byte.
  var _literalTable = RangeDecoderTable(_literalBlockSize);

  // Decoder to read length fields in match packets.
  late final _LengthDecoder _matchLengthDecoder;

  // Decoder to read length fields in repeat packets.
  late final _LengthDecoder _repeatLengthDecoder;

  // Decoder to read distance fields in match packaets.
  late final _DistanceDecoder _distanceDecoder;

  // Distances used in matches that can be repeated.
  var _distance0 = 0;
  var _distance1 = 0;
  var _distance2 = 0;
  var _distance3 = 0;

  // Decoder state, used in range decoding.
  var state = _LzmaState.litLit;

  // Decoded data, which is able to be copied.
  var _dictionary = Uint8List(0);
  var _writePosition = 0;
  int dictionaryCap = 0;

  /// Largest match distance the stream is allowed to use, which is the
  /// dictionary size the block header declares.
  ///
  /// The dictionary buffer is deliberately larger than that, so checking a
  /// match against the buffer alone accepts streams that reach further back
  /// than they declared. Those are the streams xz itself rejects as corrupt,
  /// and accepting them is what lets a remembered distance outlive the data it
  /// pointed at. Zero means no limit, for callers that decode raw LZMA.
  int dictionaryLimit = 0;

  /// Creates an LZMA decoder.
  LzmaDecoder() {
    for (var i = 0; i < _LzmaState.values.length; i++) {
      _nonLiteralTables.add(RangeDecoderTable(_maxPositionStates));
    }
    _repeatTable = RangeDecoderTable(_LzmaState.values.length);
    _repeat0Table = RangeDecoderTable(_LzmaState.values.length);
    for (var i = 0; i < _LzmaState.values.length; i++) {
      _longRepeat0Tables.add(RangeDecoderTable(_maxPositionStates));
    }
    _repeat1Table = RangeDecoderTable(_LzmaState.values.length);
    _repeat2Table = RangeDecoderTable(_LzmaState.values.length);

    _matchLengthDecoder = _LengthDecoder(_rc);
    _repeatLengthDecoder = _LengthDecoder(_rc);
    _distanceDecoder = _DistanceDecoder(_rc);

    reset();
  }

  void trimDictionary(int maxSize) {
    final threshold = maxSize + (maxSize >> 2);
    if (_writePosition <= threshold) return;

    final alignBits = _positionBits > _literalPositionBits
        ? _positionBits
        : _literalPositionBits;
    final posMask = (1 << alignBits) - 1;
    final alignment = _writePosition & posMask;
    final keepBytes = maxSize + alignment;

    final start = _writePosition - keepBytes;
    _dictionary.setRange(0, keepBytes, _dictionary, start);
    _writePosition = keepBytes;
  }

  // Reset the decoder.
  void reset(
      {int? positionBits,
      int? literalPositionBits,
      int? literalContextBits,
      bool resetDictionary = false}) {
    _positionBits = positionBits ?? _positionBits;
    _literalPositionBits = literalPositionBits ?? _literalPositionBits;
    _literalContextBits = literalContextBits ?? _literalContextBits;

    _contextShift = 8 - _literalContextBits;
    _literalPosMask = (1 << _literalPositionBits) - 1;

    state = _LzmaState.litLit;
    _distance0 = 0;
    _distance1 = 0;
    _distance2 = 0;
    _distance3 = 0;

    final maxLiteralStates = 1 << (_literalPositionBits + _literalContextBits);
    final literalTableLength = maxLiteralStates * _literalBlockSize;
    if (_literalTable.table.length != literalTableLength) {
      _literalTable = RangeDecoderTable(literalTableLength);
    }

    for (final table in _nonLiteralTables) {
      table.reset();
    }
    _repeatTable.reset();
    _repeat0Table.reset();
    for (final table in _longRepeat0Tables) {
      table.reset();
    }
    _repeat1Table.reset();
    _repeat2Table.reset();
    _literalTable.reset();

    _matchLengthDecoder.reset();
    _repeatLengthDecoder.reset();
    _distanceDecoder.reset();

    if (resetDictionary) {
      _dictionary = Uint8List(0);
      _writePosition = 0;
    }
  }

  // Expands the dictionary so that [uncompressedLength] more bytes fit after
  // the current write position, and returns the write position from before the
  // expansion, which is where the new data starts.
  int _reserve(int uncompressedLength) {
    final initialSize = _writePosition;
    final finalSize = initialSize + uncompressedLength;
    if (finalSize > _dictionary.length) {
      var newLen = _dictionary.isEmpty ? finalSize : _dictionary.length;
      while (newLen < finalSize) {
        newLen *= 2;
      }

      if (dictionaryCap > 0 &&
          newLen > dictionaryCap &&
          dictionaryCap >= finalSize) {
        newLen = dictionaryCap;
      }

      final newDictionary = Uint8List(newLen);
      if (_writePosition > 0) {
        newDictionary.setRange(0, _writePosition, _dictionary);
      }
      _dictionary = newDictionary;
    }
    return initialSize;
  }

  // Decodes packets (literal, match or repeat) until the write position
  // reaches [finalSize].
  @pragma('vm:unsafe:no-bounds-checks')
  void _decodePackets(int finalSize) {
    final positionMask = (1 << _positionBits) - 1;
    while (_writePosition < finalSize) {
      if (_rc.isOverrun) {
        throw RangeError('LZMA data is truncated or corrupt');
      }
      final posState = _writePosition & positionMask;
      if (_rc.readBitRaw(_nonLiteralTables[state.index].table, posState) == 0) {
        _decodeLiteral();
      } else if (_rc.readBitRaw(_repeatTable.table, state.index) == 0) {
        _decodeMatch(posState);
      } else {
        _decodeRepeat(posState);
      }
    }
  }

  Uint8List decodeUncompressed(InputStream input, int uncompressedLength) {
    final inputData = input.readBytes(uncompressedLength);
    final initialSize = _reserve(uncompressedLength);

    final inputBytes = inputData.toUint8List();
    _dictionary.setAll(initialSize, inputBytes);
    _writePosition += uncompressedLength;

    return inputBytes;
  }

  // Decode [input] which contains compressed LZMA data that unpacks to
  // [uncompressedLength] bytes.
  //
  // The result is copied out of the dictionary, because [trimDictionary] may
  // move the dictionary contents afterwards. Prefer [decodeToOutput] when the
  // data is only going to be appended to an [OutputStream].
  Uint8List decode(InputStream input, int uncompressedLength) {
    _rc.setBuffer(input.toUint8List());
    _rc.initialize();

    final initialSize = _reserve(uncompressedLength);
    _decodePackets(initialSize + uncompressedLength);

    return _dictionary.sublist(initialSize, _writePosition);
  }

  // When decoding has been properly finished, [RangeDecoder.code] is always
  // zero unless the input stream is corrupt. Only meaningful for data that was
  // decoded to its full length, so LZMA2, where every chunk carries its
  // uncompressed size, rather than a plain LZMA stream that may stop early.
  bool get isRangeCoderFinished => _rc.code == 0;

  // Decode [input], which contains compressed LZMA data that unpacks to
  // [uncompressedLength] bytes, appending the result directly to [output].
  //
  // This avoids the intermediate copy [decode] has to make. The view handed to
  // [OutputStream.writeBytes] does not outlive the call, so a later
  // [trimDictionary] cannot invalidate it.
  void decodeToOutput(
      InputStream input, int uncompressedLength, OutputStream output) {
    _rc.setBuffer(input.toUint8List());
    _rc.initialize();

    final initialSize = _reserve(uncompressedLength);
    _decodePackets(initialSize + uncompressedLength);

    output.writeBytes(
        Uint8List.sublistView(_dictionary, initialSize, _writePosition));
  }

  // Returns true if the previous packet seen was a literal. The first seven
  // entries of [_LzmaState] are exactly the states reached after a literal, so
  // this relies on the declaration order of that enum.
  @pragma('vm:prefer-inline')
  bool _prevPacketIsLiteral() => state.index < 7;

  // Decode a packet containing a literal byte.
  @pragma('vm:unsafe:no-bounds-checks')
  void _decodeLiteral() {
    // Get probabilities based on previous byte written.
    final prevByte = _writePosition > 0 ? _dictionary[_writePosition - 1] : 0;
    final low = prevByte >> _contextShift;
    final high = (_writePosition & _literalPosMask) << _literalContextBits;
    final baseIndex = (low + high) * _literalBlockSize;
    final probs = _literalTable.table;

    int value;
    if (_prevPacketIsLiteral()) {
      value = _rc.decodeByte(probs, baseIndex);
    } else {
      // Bounds checks are off in this method, so this index has to be checked
      // the way [_repeatData] checks its own. It can go negative even though
      // the distance was in range when it was used: [trimDictionary] moves the
      // write position back without adjusting the remembered distances.
      final matchIndex = _writePosition - _distance0 - 1;
      if (matchIndex < 0) {
        throw RangeError('LZMA match byte refers outside the dictionary');
      }
      value = _rc.decodeMatchedByte(probs, baseIndex, _dictionary[matchIndex]);
    }

    // Add new byte to the output.
    _dictionary[_writePosition] = value;
    _writePosition++;

    // Update state.
    state = _LzmaState.values[_literalNextState[state.index]];
  }

  // Decode a packet that matches some already decoded data.
  void _decodeMatch(int posState) {
    final length = _matchLengthDecoder.readLength(posState);
    final distance = _distanceDecoder.readDistance(length);

    _repeatData(distance, length);

    _distance3 = _distance2;
    _distance2 = _distance1;
    _distance1 = _distance0;
    _distance0 = distance;

    state =
        _prevPacketIsLiteral() ? _LzmaState.litMatch : _LzmaState.nonLitMatch;
  }

  // Decode a packet that repeats a match already done.
  void _decodeRepeat(int posState) {
    int distance;
    if (_rc.readBitRaw(_repeat0Table.table, state.index) == 0) {
      if (_rc.readBitRaw(_longRepeat0Tables[state.index].table, posState) ==
          0) {
        _repeatData(_distance0, 1);
        state = _prevPacketIsLiteral()
            ? _LzmaState.litShortRep
            : _LzmaState.nonLitRep;
        return;
      } else {
        distance = _distance0;
      }
    } else if (_rc.readBitRaw(_repeat1Table.table, state.index) == 0) {
      distance = _distance1;
      _distance1 = _distance0;
      _distance0 = distance;
    } else if (_rc.readBitRaw(_repeat2Table.table, state.index) == 0) {
      distance = _distance2;
      _distance2 = _distance1;
      _distance1 = _distance0;
      _distance0 = distance;
    } else {
      distance = _distance3;
      _distance3 = _distance2;
      _distance2 = _distance1;
      _distance1 = _distance0;
      _distance0 = distance;
    }

    var length = _repeatLengthDecoder.readLength(posState);
    _repeatData(distance, length);

    // Update state.
    state =
        _prevPacketIsLiteral() ? _LzmaState.litLongRep : _LzmaState.nonLitRep;
  }

  // Repeat decompressed data, starting [distance] bytes back from the end of
  // the buffer and copying [length] bytes.
  @pragma('vm:unsafe:no-bounds-checks')
  void _repeatData(int distance, int length) {
    final src = _writePosition - distance - 1;
    if (src < 0 ||
        _writePosition + length > _dictionary.length ||
        (dictionaryLimit > 0 && distance >= dictionaryLimit)) {
      throw RangeError('LZMA match refers outside the dictionary');
    }
    if (distance == 0) {
      // A run of a single repeated byte, which is common in padded binaries.
      _dictionary.fillRange(
          _writePosition, _writePosition + length, _dictionary[src]);
      _writePosition += length;
    } else if (distance >= length) {
      if (length <= 16) {
        var s = src;
        var d = _writePosition;
        final end = d + length;
        while (d < end) {
          _dictionary[d++] = _dictionary[s++];
        }
        _writePosition = end;
      } else {
        _dictionary.setRange(
            _writePosition, _writePosition + length, _dictionary, src);
        _writePosition += length;
      }
    } else {
      final end = _writePosition + length;
      var s = src;
      var d = _writePosition;
      while (d < end) {
        _dictionary[d++] = _dictionary[s++];
      }
      _writePosition = end;
    }
  }
}

// The decoder state which tracks the sequence of LZMA packets received.
enum _LzmaState {
  litLit,
  matchLitLit,
  repLitLit,
  shortRepLitLit,
  matchLit,
  repLit,
  shortRepLit,
  litMatch,
  litLongRep,
  litShortRep,
  nonLitMatch,
  nonLitRep
}

// Decodes match/repeat length fields from LZMA data.
class _LengthDecoder {
  // Data being read from.
  final RangeDecoder _input;

  // Bit probabilities for every form of the length field.
  final RangeDecoderTable _table = RangeDecoderTable(lengthProbsLength);

  _LengthDecoder(this._input);

  // Reset this decoder.
  void reset() {
    _table.reset();
  }

  // Read a length field.
  @pragma('vm:prefer-inline')
  int readLength(int posState) => _input.decodeLength(_table.table, posState);
}

// Decodes match distance fields from LZMA data.
class _DistanceDecoder {
  // Data being read from.
  final RangeDecoder _input;

  // Bit probabilities for the slot, the slot 4-13 suffixes and the aligned
  // bits.
  final RangeDecoderTable _table = RangeDecoderTable(distanceProbsLength);

  _DistanceDecoder(this._input);

  // Reset this decoder.
  void reset() {
    _table.reset();
  }

  // Reads a distance field.
  // [length] is a match length (minimum of 2).
  @pragma('vm:prefer-inline')
  int readDistance(int length) {
    var distState = length - 2;
    if (distState > 3) {
      distState = 3;
    }
    return _input.decodeDistance(_table.table, distState);
  }
}
