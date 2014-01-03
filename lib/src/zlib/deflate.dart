part of archive;

class Deflate {
  static const int UNCOMPRESSED = 0;
  static const int FIXED_HUFFMAN = 1;
  static const int DYNAMIC_HUFFMAN = 2;

  final InputBuffer input;
  final _BitStream output;

  /**
   * [data] should be either a List<int> or InputBuffer.
   * TODO compression is defaulted to FIXED_HUFFMAN since DYNAMIC_HUFFMAN
   * is causing problems for some decompressors.  Need to fix DYNAMIC_HUFFMAN.
   */
  Deflate(data, {int type: FIXED_HUFFMAN, int blockSize: 0xffff}) :
    input = data is InputBuffer ? data : new InputBuffer(data),
    output = new _BitStream(data.length) {
    int len = input.length;
    while (!input.isEOF) {
      InputBuffer inputBlock = input.subset(null, blockSize);
      input.position += input.length;
      switch (type) {
        case UNCOMPRESSED:
          _addUncompressedBlock(inputBlock, output, input.isEOF);
          break;
        case FIXED_HUFFMAN:
          _addFixedHuffmanBlock(inputBlock, output, input.isEOF);
          break;
        case DYNAMIC_HUFFMAN:
          _addDynamicHuffmanBlock(inputBlock, output, input.isEOF);
          break;
        default:
          throw new ArchiveException('Invalid compression type');
      }
    }
  }

  /**
   * Get the decompressed data.
   */
  List<int> getBytes() {
    return output.finish();
  }

  void _addUncompressedBlock(InputBuffer input, _BitStream output,
                             bool isEnd) {
    // Block Header
    int bfinal = isEnd ? 1 : 0;
    int btype = UNCOMPRESSED;
    output.writeBits(bfinal | (btype << 1), 3);

    // Block Size
    int len = input.length;
    output.writeUint16(len);
    int nlen = (~len + 0x10000) & 0xffff;
    output.writeUint16(nlen);

    // Copy buffer
    output.writeBytes(input.buffer);
  }

  void _addFixedHuffmanBlock(InputBuffer input, _BitStream output,
                             bool isEnd) {
    // Block Header
    int bfinal = isEnd ? 1 : 0;
    int btype = FIXED_HUFFMAN;
    output.writeBits(bfinal | (btype << 1), 3, reverse: true);

    Data.Uint16List data = _lz77(input.buffer);
    _fixedHuffman(data, output);
  }

  void _addDynamicHuffmanBlock(InputBuffer input, _BitStream output,
                               bool isEnd) {
    // Block Header
    int bfinal = isEnd ? 1 : 0;
    int btype = DYNAMIC_HUFFMAN;
    output.writeBits(bfinal | (btype << 1), 3, reverse: true);

    Data.Uint16List data = _lz77(input.buffer);

    Data.Uint8List litLenLengths = _getLengths(_freqLitLen, 15);
    Data.Uint16List litLenCodes = _getCodesFromLengths(litLenLengths);
    Data.Uint8List distLengths = _getLengths(_freqDist, 7);
    Data.Uint16List distCodes = _getCodesFromLengths(distLengths);

    // HLIT, HDIST
    int hlit;
    for (hlit = 286; hlit > 257 && litLenLengths[hlit - 1] == 0; hlit--) {}

    int hdist;
    for (hdist = 30; hdist > 1 && distLengths[hdist - 1] == 0; hdist--) {}

    // HCLEN
    List treeSymbols =
        _getTreeSymbols(hlit, litLenLengths, hdist, distLengths);

    Data.Uint8List treeLengths = _getLengths(treeSymbols[1], 7);
    List<int> transLengths = new List<int>(19);

    for (int i = 0; i < 19; i++) {
      transLengths[i] = treeLengths[_hclenOrder[i]];
    }

    int hclen;
    for (hclen = 19; hclen > 4 && transLengths[hclen - 1] == 0; hclen--) {}

    var treeCodes = _getCodesFromLengths(treeLengths);

    output.writeBits(hlit - 257, 5, reverse: true);
    output.writeBits(hdist - 1, 5, reverse: true);
    output.writeBits(hclen - 4, 4, reverse: true);
    for (int i = 0; i < hclen; i++) {
      output.writeBits(transLengths[i], 3, reverse: true);
    }

    for (int i = 0, il = treeSymbols[0].length; i < il; i++) {
      int code = treeSymbols[0][i];

      output.writeBits(treeCodes[code], treeLengths[code], reverse: true);

      // extra bits
      if (code >= 16) {
        i++;

        int bitlen = 0;
        switch (code) {
          case 16: bitlen = 2; break;
          case 17: bitlen = 3; break;
          case 18: bitlen = 7; break;
          default:
            throw 'invalid code: $code';
        }

        output.writeBits(treeSymbols[0][i], bitlen, reverse: true);
      }
    }

    _dynamicHuffman(data,
        [litLenCodes, litLenLengths],
        [distCodes, distLengths],
        output);
  }

  void _fixedHuffman(Data.Uint16List dataArray, _BitStream output) {
    for (int index = 0, length = dataArray.length; index < length; index++) {
      int literal = dataArray[index];

      output.writeBits(_FIXED_HUFFMAN_TABLE[literal],
                       _FIXED_HUFFMAN_TABLE_LEN[literal]);

      if (literal > 0x100) {
        // length extra
        output.writeBits(dataArray[++index], dataArray[++index], reverse: true);
        // distance
        output.writeBits(dataArray[++index], 5);
        // distance extra
        output.writeBits(dataArray[++index], dataArray[++index], reverse: true);
      } else if (literal == 0x100) {
        break;
      }
    }
  }

  void _dynamicHuffman(Data.Uint16List dataArray, List litLen, List dist,
                       _BitStream output) {
    Data.Uint16List litLenCodes = litLen[0];
    Data.Uint8List litLenLengths = litLen[1];
    Data.Uint16List distCodes = dist[0];
    Data.Uint8List distLengths = dist[1];

    for (int index = 0, length = dataArray.length; index < length; ++index) {
      int literal = dataArray[index];

      // literal or length
      output.writeBits(litLenCodes[literal], litLenLengths[literal], reverse: true);

      if (literal > 256) {
        // length extra
        output.writeBits(dataArray[++index], dataArray[++index], reverse: true);
        // distance
        int code = dataArray[++index];
        output.writeBits(distCodes[code], distLengths[code], reverse: true);
        // distance extra
        output.writeBits(dataArray[++index], dataArray[++index], reverse: true);
      } else if (literal == 256) {
        break;
      }
    }
  }

  List _getTreeSymbols(int hlit, Data.Uint8List litlenLengths,
                       int hdist, Data.Uint8List distLengths) {
    Data.Uint32List src = new Data.Uint32List(hlit + hdist);
    Data.Uint32List result = new Data.Uint32List(286 + 30);
    Data.Uint32List freqs = new Data.Uint32List(19);

    int j = 0;
    for (int i = 0; i < hlit; i++) {
      src[j++] = litlenLengths[i];
    }
    for (int i = 0; i < hdist; i++) {
      src[j++] = distLengths[i];
    }

    int nResult = 0;
    for (int i = 0, l = src.length; i < l; i += j) {
      // Run Length Encoding
      for (j = 1; i + j < l && src[i + j] == src[i]; ++j) {}

      int runLength = j;

      if (src[i] == 0) {
        if (runLength < 3) {
          while (runLength-- > 0) {
            result[nResult++] = 0;
            freqs[0]++;
          }
        } else {
          while (runLength > 0) {
            int rpt = (runLength < 138 ? runLength : 138);

            if (rpt > runLength - 3 && rpt < runLength) {
              rpt = runLength - 3;
            }

            if (rpt <= 10) {
              result[nResult++] = 17;
              result[nResult++] = rpt - 3;
              freqs[17]++;
            } else {
              result[nResult++] = 18;
              result[nResult++] = rpt - 11;
              freqs[18]++;
            }

            runLength -= rpt;
          }
        }
      } else {
        result[nResult++] = src[i];
        freqs[src[i]]++;
        runLength--;

        if (runLength < 3) {
          while (runLength-- > 0) {
            result[nResult++] = src[i];
            freqs[src[i]]++;
          }
        } else {
          while (runLength > 0) {
            int rpt = (runLength < 6 ? runLength : 6);

            if (rpt > runLength - 3 && rpt < runLength) {
              rpt = runLength - 3;
            }

            result[nResult++] = 16;
            result[nResult++] = rpt - 3;
            freqs[16]++;

            runLength -= rpt;
          }
        }
      }
    }

    return [result.sublist(0, nResult), freqs];
  }

  Data.Uint16List _getCodesFromLengths(Data.Uint8List lengths) {
    var codes = new Data.Uint16List(lengths.length);
    Map<int, int> count = {};
    Map<int, int> startCode = {};
    int code = 0;

    int len = _MAX_CODE_LENGTH > lengths.length ? _MAX_CODE_LENGTH : lengths.length;
    for (int i = 1, il = len; i <= il; i++) {
      count[i] = 0;
    }

    // Count the codes of each length.
    for (int i = 0, il = lengths.length; i < il; i++) {
      if (!count.containsKey(lengths[i])) {
        count[lengths[i]] = 0;
      }
      count[lengths[i]] = (count[lengths[i]]) + 1;
    }

    // Determine the starting code for each length block.
    for (int i = 1, il = _MAX_CODE_LENGTH; i <= il; i++) {
      startCode[i] = code;
      code += count[i];
      code <<= 1;
    }

    // Determine the code for each symbol. Mirrored, of course.
    for (int i = 0, il = lengths.length; i < il; i++) {
      code = startCode[lengths[i]];
      if (!startCode.containsKey(lengths[i])) {
        startCode[lengths[i]] = 0;
      }
      startCode[lengths[i]] += 1;
      codes[i] = 0;

      for (int j = 0, m = lengths[i]; j < m; j++) {
        codes[i] = (codes[i] << 1) | (code & 1);
        code >>= 1;
      }
    }

    return codes;
  }

  Data.Uint8List _getLengths(Data.Uint32List freqs, int limit) {
    int nSymbols = freqs.length;
    _Heap heap = new _Heap(2 * _HUFMAX);
    Data.Uint8List length = new Data.Uint8List(nSymbols);

    for (int i = 0; i < nSymbols; ++i) {
      if (freqs[i] > 0) {
        heap.push(i, freqs[i]);
      }
    }

    List nodes = new List(heap.length ~/ 2);
    Data.Uint32List values = new Data.Uint32List(heap.length ~/ 2);

    if (nodes.length == 1) {
      length[heap.pop()[0]] = 1;
      return length;
    }

    // Reverse Package Merge Algorithm
    for (int i = 0, il = heap.length ~/ 2; i < il; ++i) {
      nodes[i] = heap.pop();
      values[i] = nodes[i][1];
    }

    Data.Uint8List codeLength = _reversePackageMerge(values, values.length, limit);

    for (int i = 0, il = nodes.length; i < il; ++i) {
      length[nodes[i][0]] = codeLength[i];
    }

    return length;
  }

  /**
   * Reverse Package Merge algorithm.
   */
  Data.Uint8List _reversePackageMerge(Data.Uint32List freqs,
                                      int symbols,
                                      int limit) {
    //Data.Uint16List minimumCost = new Data.Uint16List(limit);
    Map<int, int> minimumCost = {};
    Data.Uint8List flag = new Data.Uint8List(limit);
    Data.Uint8List codeLength = new Data.Uint8List(symbols);
    List value = new List(limit);
    List type  = new List(limit);
    Data.Uint32List currentPosition = new Data.Uint32List(limit);
    int excess = (1 << limit) - symbols;
    int half = (1 << (limit - 1));

    void _takePackage(int j) {
      if (j >= currentPosition.length) {
        return;
      }
      if (currentPosition[j] >= type[j].length) {
        return;
      }
      int x = type[j][currentPosition[j]];

      if (x == symbols) {
        _takePackage(j + 1);
        _takePackage(j + 1);
      } else {
        --codeLength[x];
      }

      ++currentPosition[j];
    }

    minimumCost[limit - 1] = symbols;

    for (int j = 0; j < limit; ++j) {
      if (excess < half) {
        flag[j] = 0;
      } else {
        flag[j] = 1;
        excess -= half;
      }
      excess <<= 1;
      //if (j < limit - 2) {
        minimumCost[limit - 2 - j] = (minimumCost[limit - 1 - j] ~/ 2) + symbols;
      //}
    }
    minimumCost[0] = flag[0];

    value[0] = new List(minimumCost[0]);
    type[0]  = new List(minimumCost[0]);

    for (int j = 1; j < limit; ++j) {
      if (minimumCost[j] > 2 * minimumCost[j - 1] + flag[j]) {
        minimumCost[j] = 2 * minimumCost[j - 1] + flag[j];
      }
      value[j] = new List(minimumCost[j]);
      type[j]  = new List(minimumCost[j]);
    }

    for (int i = 0; i < symbols; ++i) {
      codeLength[i] = limit;
    }

    for (int t = 0; t < minimumCost[limit - 1]; ++t) {
      value[limit - 1][t] = freqs[t];
      type[limit - 1][t]  = t;
    }

    if (flag[limit - 1] == 1) {
      --codeLength[0];
      ++currentPosition[limit - 1];
    }

    for (int j = limit - 2; j >= 0; --j) {
      int i = 0;
      int weight = 0;
      int next = currentPosition[j + 1];

      for (int t = 0; t < minimumCost[j]; t++) {
        if ((next) < value[j + 1].length) {
          weight = value[j + 1][next];
        }
        if ((next + 1) < value[j + 1].length) {
          weight += value[j + 1][next + 1];
        }

        if (weight > freqs[i]) {
          value[j][t] = weight;
          type[j][t] = symbols;
          next += 2;
        } else {
          value[j][t] = freqs[i];
          type[j][t] = i;
          ++i;
        }
      }

      currentPosition[j] = 0;
      if (flag[j] == 1) {
        _takePackage(j);
      }
    }

    return codeLength;
  }

  Data.Uint16List _lz77(List<int> input) {
    Data.Uint16List lz77Buffer = new Data.Uint16List(input.length * 2);
    int pos = 0;
    int skipLength = 0;
    _Lz77Match prevMatch;
    Map<int, List> table = {};

    _freqLitLen = new Data.Uint32List(286);
    _freqDist = new Data.Uint32List(30);

    _freqLitLen[256] = 1;

    void _writeMatch(_Lz77Match match, int offset) {
      var lz77Array = match.toLz77Array();
      int len = lz77Array.length;
      for (int i = 0; i < len; ++i) {
        lz77Buffer[pos++] = lz77Array[i];
      }
      _freqLitLen[lz77Array[0]]++;
      _freqDist[lz77Array[3]]++;
      skipLength = match.length + offset - 1;
      prevMatch = null;
    };

    int length = input.length;
    for (int position = 0; position < length; ++position) {
      int matchKey = 0;
      for (int i = 0; i < _LZ77_MIN_LENGTH; ++i) {
        if (position + i == length) {
          break;
        }
        matchKey = (matchKey << 8) | input[position + i];
      }

      if (table[matchKey] == null) {
        table[matchKey] = [];
      }

      List matchList = table[matchKey];

      // skip
      if (skipLength-- > 0) {
        matchList.add(position);
        continue;
      }

      while (matchList.length > 0 && position - matchList[0] > _WINDOW_SIZE) {
        matchList.removeAt(0);
      }

      if (position + _LZ77_MIN_LENGTH >= length) {
        if (prevMatch != null) {
          _writeMatch(prevMatch, -1);
        }

        for (int i = 0, il = length - position; i < il; ++i) {
          int tmp = input[position + i];
          lz77Buffer[pos++] = tmp;
          ++_freqLitLen[tmp];
        }
        break;
      }

      if (matchList.length > 0) {
        _Lz77Match longestMatch =
            _searchLongestMatch(input, position, matchList);

        if (prevMatch != null) {
          if (prevMatch.length < longestMatch.length) {
            // write previous literal
            int tmp = input[position - 1];
            lz77Buffer[pos++] = tmp;
            ++_freqLitLen[tmp];

            // write current match
            _writeMatch(longestMatch, 0);
          } else {
            // write previous match
            _writeMatch(prevMatch, -1);
          }
        } else if (longestMatch.length < _lazy) {
          prevMatch = longestMatch;
        } else {
          _writeMatch(longestMatch, 0);
        }
      } else if (prevMatch != null) {
        _writeMatch(prevMatch, -1);
      } else {
        int tmp = input[position];
        lz77Buffer[pos++] = tmp;
        ++_freqLitLen[tmp];
      }

      matchList.add(position);
    }

    lz77Buffer[pos++] = 256;
    _freqLitLen[256]++;

    return lz77Buffer;
  }

  _Lz77Match _searchLongestMatch(List<int> data, int position,
                                 List<int> matchList) {
    int matchMax = 0;
    int dl = data.length;
    int len = matchList.length;
    int currentMatch = 0;

    permatch:
    for (int i = 0; i < len; ++i) {
      int match = matchList[len - i - 1];
      int matchLength = _LZ77_MIN_LENGTH;

      if (matchMax > _LZ77_MIN_LENGTH) {
        for (int j = matchMax; j > _LZ77_MIN_LENGTH; --j) {
          if (data[match + j - 1] != data[position + j - 1]) {
            continue permatch;
          }
        }
        matchLength = matchMax;
      }

      while (matchLength < _LZ77_MAX_LENGTH &&
          position + matchLength < dl &&
          data[match + matchLength] == data[position + matchLength]) {
        ++matchLength;
      }

      if (matchLength > matchMax) {
        currentMatch = match;
        matchMax = matchLength;
      }

      if (matchLength == _LZ77_MAX_LENGTH) {
        break;
      }
    }

    return new _Lz77Match(matchMax, position - currentMatch);
  }

  int _lazy = 0;
  Data.Uint32List _freqLitLen;
  Data.Uint32List _freqDist;

  static const int _LZ77_MIN_LENGTH = 3;
  static const int _LZ77_MAX_LENGTH = 258;
  static const int _HUFMAX = 286;
  static const int _MAX_CODE_LENGTH = 16;
  static const int _WINDOW_SIZE = 0x8000;

  static const List<int> _FIXED_HUFFMAN_TABLE = const [
      48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 65,
      66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83,
      84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99, 100, 101,
      102, 103, 104, 105, 106, 107, 108, 109, 110, 111, 112, 113, 114, 115,
      116, 117, 118, 119, 120, 121, 122, 123, 124, 125, 126, 127, 128, 129,
      130, 131, 132, 133, 134, 135, 136, 137, 138, 139, 140, 141, 142, 143,
      144, 145, 146, 147, 148, 149, 150, 151, 152, 153, 154, 155, 156, 157,
      158, 159, 160, 161, 162, 163, 164, 165, 166, 167, 168, 169, 170, 171,
      172, 173, 174, 175, 176, 177, 178, 179, 180, 181, 182, 183, 184, 185,
      186, 187, 188, 189, 190, 191, 400, 401, 402, 403, 404, 405, 406, 407,
      408, 409, 410, 411, 412, 413, 414, 415, 416, 417, 418, 419, 420, 421,
      422, 423, 424, 425, 426, 427, 428, 429, 430, 431, 432, 433, 434, 435,
      436, 437, 438, 439, 440, 441, 442, 443, 444, 445, 446, 447, 448, 449,
      450, 451, 452, 453, 454, 455, 456, 457, 458, 459, 460, 461, 462, 463,
      464, 465, 466, 467, 468, 469, 470, 471, 472, 473, 474, 475, 476, 477,
      478, 479, 480, 481, 482, 483, 484, 485, 486, 487, 488, 489, 490, 491,
      492, 493, 494, 495, 496, 497, 498, 499, 500, 501, 502, 503, 504, 505,
      506, 507, 508, 509, 510, 511, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12,
      13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 192, 193, 194, 195, 196, 197,
      198, 199];
  static const List<int> _FIXED_HUFFMAN_TABLE_LEN = const [
      8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
      8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
      8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
      8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
      8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
      8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
      9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
      9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
      9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
      9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
      9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 7, 7, 7, 7, 7, 7, 7, 7,
      7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8];

  static const List<int> _hclenOrder = const [
      16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];
}

class _Heap {
  Data.Uint16List buffer;
  int length;

  _Heap(int length) {
    buffer = new Data.Uint16List(length * 2);
    this.length = 0;
  }

  int getParent(int index) {
    return ((index - 2) ~/ 4) * 2;
  }

  int getChild(int index) {
    return 2 * index + 2;
  }

  int push(int index, int value) {
    int current = length;
    buffer[length++] = value;
    buffer[length++] = index;

    while (current > 0) {
      int parent = getParent(current);

      if (buffer[current] > buffer[parent]) {
        int swap = buffer[current];
        buffer[current] = buffer[parent];
        buffer[parent] = swap;

        swap = buffer[current + 1];
        buffer[current + 1] = buffer[parent + 1];
        buffer[parent + 1] = swap;

        current = parent;
      } else {
        break;
      }
    }

    return length;
  }

  List pop() {
    int value = buffer[0];
    int index = buffer[1];

    length -= 2;
    buffer[0] = buffer[length];
    buffer[1] = buffer[length + 1];

    int parent = 0;
    while (true) {
      int current = getChild(parent);

      if (current >= length) {
        break;
      }

      if (current + 2 < length && buffer[current + 2] > buffer[current]) {
        current += 2;
      }

      if (buffer[current] > buffer[parent]) {
        int swap = buffer[parent];
        buffer[parent] = buffer[current];
        buffer[current] = swap;

        swap = buffer[parent + 1];
        buffer[parent + 1] = buffer[current + 1];
        buffer[current + 1] = swap;
      } else {
        break;
      }

      parent = current;
    }

    return [index, value, length];
  }
}

class _Lz77Match {
  int length;
  int backwardDistance;

  _Lz77Match(this.length, this.backwardDistance);

  List<int> toLz77Array() {
    List<int> codeArray = new List<int>(6);

    // length
    int code = _lengthCodeTable[length];
    codeArray[0] = code & 0xffff;
    codeArray[1] = (code >> 16) & 0xff;
    codeArray[2] = code >> 24;

    // distance
    List<int> distance = _getDistanceCode(backwardDistance);
    codeArray[3] = distance[0];
    codeArray[4] = distance[1];
    codeArray[5] = distance[2];

    return codeArray;
  }

  List<int> _getDistanceCode(int dist) {
    if (dist == 1) return [0, dist - 1, 0];
    if (dist == 2) return [1, dist - 2, 0];
    if (dist == 3) return [2, dist - 3, 0];
    if (dist == 4) return [3, dist - 4, 0];
    if (dist <= 6) return [4, dist - 5, 1];
    if (dist <= 8) return [5, dist - 7, 1];
    if (dist <= 12) return [6, dist - 9, 2];
    if (dist <= 16) return [7, dist - 13, 2];
    if (dist <= 24) return [8, dist - 17, 3];
    if (dist <= 32) return [9, dist - 25, 3];
    if (dist <= 48) return [10, dist - 33, 4];
    if (dist <= 64) return [11, dist - 49, 4];
    if (dist <= 96) return [12, dist - 65, 5];
    if (dist <= 128) return [13, dist - 97, 5];
    if (dist <= 192) return [14, dist - 129, 6];
    if (dist <= 256) return [15, dist - 193, 6];
    if (dist <= 384) return [16, dist - 257, 7];
    if (dist <= 512) return [17, dist - 385, 7];
    if (dist <= 768) return [18, dist - 513, 8];
    if (dist <= 1024) return [19, dist - 769, 8];
    if (dist <= 1536) return [20, dist - 1025, 9];
    if (dist <= 2048) return [21, dist - 1537, 9];
    if (dist <= 3072) return [22, dist - 2049, 10];
    if (dist <= 4096) return [23, dist - 3073, 10];
    if (dist <= 6144) return [24, dist - 4097, 11];
    if (dist <= 8192) return [25, dist - 6145, 11];
    if (dist <= 12288) return [26, dist - 8193, 12];
    if (dist <= 16384) return [27, dist - 12289, 12];
    if (dist <= 24576) return [28, dist - 16385, 13];
    if (dist <= 32768) return [29, dist - 24577, 13];
    throw 'invalid distance';
  }

  static const List<int> _lengthCodeTable = const [
      0, 0, 0, 257, 258, 259, 260, 261, 262, 263, 264, 16777481, 16843017,
      16777482, 16843018, 16777483, 16843019, 16777484, 16843020, 33554701,
      33620237, 33685773, 33751309, 33554702, 33620238, 33685774, 33751310,
      33554703, 33620239, 33685775, 33751311, 33554704, 33620240, 33685776,
      33751312, 50331921, 50397457, 50462993, 50528529, 50594065, 50659601,
      50725137, 50790673, 50331922, 50397458, 50462994, 50528530, 50594066,
      50659602, 50725138, 50790674, 50331923, 50397459, 50462995, 50528531,
      50594067, 50659603, 50725139, 50790675, 50331924, 50397460, 50462996,
      50528532, 50594068, 50659604, 50725140, 50790676, 67109141, 67174677,
      67240213, 67305749, 67371285, 67436821, 67502357, 67567893, 67633429,
      67698965, 67764501, 67830037, 67895573, 67961109, 68026645, 68092181,
      67109142, 67174678, 67240214, 67305750, 67371286, 67436822, 67502358,
      67567894, 67633430, 67698966, 67764502, 67830038, 67895574, 67961110,
      68026646, 68092182, 67109143, 67174679, 67240215, 67305751, 67371287,
      67436823, 67502359, 67567895, 67633431, 67698967, 67764503, 67830039,
      67895575, 67961111, 68026647, 68092183, 67109144, 67174680, 67240216,
      67305752, 67371288, 67436824, 67502360, 67567896, 67633432, 67698968,
      67764504, 67830040, 67895576, 67961112, 68026648, 68092184, 83886361,
      83951897, 84017433, 84082969, 84148505, 84214041, 84279577, 84345113,
      84410649, 84476185, 84541721, 84607257, 84672793, 84738329, 84803865,
      84869401, 84934937, 85000473, 85066009, 85131545, 85197081, 85262617,
      85328153, 85393689, 85459225, 85524761, 85590297, 85655833, 85721369,
      85786905, 85852441, 85917977, 83886362, 83951898, 84017434, 84082970,
      84148506, 84214042, 84279578, 84345114, 84410650, 84476186, 84541722,
      84607258, 84672794, 84738330, 84803866, 84869402, 84934938, 85000474,
      85066010, 85131546, 85197082, 85262618, 85328154, 85393690, 85459226,
      85524762, 85590298, 85655834, 85721370, 85786906, 85852442, 85917978,
      83886363, 83951899, 84017435, 84082971, 84148507, 84214043, 84279579,
      84345115, 84410651, 84476187, 84541723, 84607259, 84672795, 84738331,
      84803867, 84869403, 84934939, 85000475, 85066011, 85131547, 85197083,
      85262619, 85328155, 85393691, 85459227, 85524763, 85590299, 85655835,
      85721371, 85786907, 85852443, 85917979, 83886364, 83951900, 84017436,
      84082972, 84148508, 84214044, 84279580, 84345116, 84410652, 84476188,
      84541724, 84607260, 84672796, 84738332, 84803868, 84869404, 84934940,
      85000476, 85066012, 85131548, 85197084, 85262620, 85328156, 85393692,
      85459228, 85524764, 85590300, 85655836, 85721372, 85786908, 85852444,
      285];
}

class _BitStream {
  int index = 0;
  int bitindex = 0;
  Data.Uint8List buffer;

  _BitStream([int bufferSize = _BLOCK_SIZE]) :
    buffer = new Data.Uint8List(bufferSize);

  /**
   * Write a byte to the end of the buffer.
   */
  void writeByte(int value) {
    bitindex = 0;
    buffer[++index] = value & 0xff;
    if (index == buffer.length) {
      _expandBuffer();
    }
  }

  /**
   * Write a set of bytes to the end of the buffer.
   */
  void writeBytes(List<int> bytes) {
    bitindex = 0;
    while (index + bytes.length + 1 > buffer.length) {
      _expandBuffer();
    }
    buffer.setRange(index + 1, index + bytes.length + 1, bytes);
    index += bytes.length + 1;
  }

  /**
   * Write a 16-bit word to the end of the buffer.
   */
  void writeUint16(int value) {
    writeByte((value) & 0xff);
    writeByte((value >> 8) & 0xff);
  }

  void writeBits(int number, int n, {bool reverse: false}) {
    int current = buffer[index];

    int rev32_(int n) {
      return (_BitStream._REVERSE_TABLE[n & 0xFF] << 24) |
          (_BitStream._REVERSE_TABLE[n >> 8 & 0xFF] << 16) |
          (_BitStream._REVERSE_TABLE[n >> 16 & 0xFF] << 8) |
          _BitStream._REVERSE_TABLE[n >> 24 & 0xFF];
    }

    if (reverse && n > 1) {
      number = n > 8 ?
          rev32_(number) >> (32 - n) :
          _BitStream._REVERSE_TABLE[number] >> (8 - n);
    }

    if (n + bitindex < 8) {
      current = (current << n) | number;
      bitindex += n;
    } else {
      for (int i = 0; i < n; ++i) {
        current = (current << 1) | ((number >> n - i - 1) & 1);

        // next byte
        if (++bitindex == 8) {
          bitindex = 0;
          buffer[index++] = _BitStream._REVERSE_TABLE[current];
          current = 0;

          // expand
          if (index == buffer.length) {
            _expandBuffer();
          }
        }
      }
    }
    buffer[index] = current;
  }

  Data.Uint8List finish() {
    var buffer = this.buffer;
    var index = this.index;

    if (this.bitindex > 0) {
      buffer[index] <<= 8 - this.bitindex;
      buffer[index] = _BitStream._REVERSE_TABLE[buffer[index]];
      index++;
    }

    Data.Uint8List output = buffer.sublist(0, index);

    return output;
  }

  void _expandBuffer() {
    var oldbuf = buffer;
    var il = oldbuf.length;
    buffer = new Data.Uint8List(il + _BLOCK_SIZE);
    buffer.setRange(0, oldbuf.length, oldbuf);
  }

  static const int _BLOCK_SIZE = 0x8000;

  static const List<int> _REVERSE_TABLE = const [
     0, 128, 64, 192, 32, 160, 96, 224, 16, 144, 80, 208, 48, 176, 112, 240,
     8, 136, 72, 200, 40, 168, 104, 232, 24, 152, 88, 216, 56, 184, 120, 248,
     4, 132, 68, 196, 36, 164, 100, 228, 20, 148, 84, 212, 52, 180, 116, 244,
     12, 140, 76, 204, 44, 172, 108, 236, 28, 156, 92, 220, 60, 188, 124, 252,
     2, 130, 66, 194, 34, 162, 98, 226, 18, 146, 82, 210, 50, 178, 114, 242,
     10, 138, 74, 202, 42, 170, 106, 234, 26, 154, 90, 218, 58, 186, 122, 250,
     6, 134, 70, 198, 38, 166, 102, 230, 22, 150, 86, 214, 54, 182, 118, 246,
     14, 142, 78, 206, 46, 174, 110, 238, 30, 158, 94, 222, 62, 190, 126, 254,
     1, 129, 65, 193, 33, 161, 97, 225, 17, 145, 81, 209, 49, 177, 113, 241,
     9, 137, 73, 201, 41, 169, 105, 233, 25, 153, 89, 217, 57, 185, 121, 249,
     5, 133, 69, 197, 37, 165, 101, 229, 21, 149, 85, 213, 53, 181, 117, 245,
     13, 141, 77, 205, 45, 173, 109, 237, 29, 157, 93, 221, 61, 189, 125, 253,
     3, 131, 67, 195, 35, 163, 99, 227, 19, 147, 83, 211, 51, 179, 115, 243,
     11, 139, 75, 203, 43, 171, 107, 235, 27, 155, 91, 219, 59, 187, 123, 251,
     7, 135, 71, 199, 39, 167, 103, 231, 23, 151, 87, 215, 55, 183, 119, 247,
     15, 143, 79, 207, 47, 175, 111, 239, 31, 159, 95, 223, 63, 191, 127, 255];
}
