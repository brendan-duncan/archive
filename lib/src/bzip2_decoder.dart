part of archive;

/**
 * Decompress bzip2 compressed data.
 * Derived from libbzip2 (http://www.bzip.org).
 */
class BZip2Decoder {
  List<int> decodeBytes(List<int> data, {bool verify: true}) {
    return decodeBuffer(new InputStream(data, byteOrder: BIG_ENDIAN),
                        verify: verify);
  }

  List<int> decodeBuffer(InputStream _input, {bool verify: false}) {
    OutputStream output = new OutputStream();
    BitReader br = new BitReader(_input);

    _groupPos = 0;
    _groupNo = 0;
    _gSel = 0;
    _gMinlen = 0;

    if (br.readByte() != BZ2_SIGNATURE[0] ||
        br.readByte() != BZ2_SIGNATURE[1] ||
        br.readByte() != BZ2_SIGNATURE[2]) {
      throw new ArchiveException('Invalid Signature');
    }

    _blockSize100k = br.readByte() - BZ_HDR_0;
    if (_blockSize100k < 0 || _blockSize100k > 9) {
      throw new ArchiveException('Invalid BlockSize');
    }

    _tt = new Data.Uint32List(_blockSize100k * 100000);

    int combinedCrc = 0;

    while (true) {
      int type = _readBlockType(br);
      if (type == BLOCK_COMPRESSED) {
        int storedBlockCrc = 0;
        storedBlockCrc = (storedBlockCrc << 8) | br.readByte();
        storedBlockCrc = (storedBlockCrc << 8) | br.readByte();
        storedBlockCrc = (storedBlockCrc << 8) | br.readByte();
        storedBlockCrc = (storedBlockCrc << 8) | br.readByte();

        int crc = _readCompressed(br, output);
        crc = _finalizeCrc(crc);

        if (verify && crc != storedBlockCrc) {
          throw new ArchiveException('Invalid block checksum.');
        }
        combinedCrc = (combinedCrc << 1) | (combinedCrc >> 31);
                combinedCrc ^= crc;
      } else if (type == BLOCK_EOS) {
        int storedCrc = 0;
        storedCrc = (storedCrc << 8) | br.readByte();
        storedCrc = (storedCrc << 8) | br.readByte();
        storedCrc = (storedCrc << 8) | br.readByte();
        storedCrc = (storedCrc << 8) | br.readByte();

        if (verify && storedCrc != combinedCrc) {
          throw new ArchiveException('Invalid combined checksum.');
        }

        return output.getBytes();
      }
    }

    return null;
  }

  int _readBlockType(BitReader br) {
    bool eos = true;
    bool compressed = true;

    // .eos_magic:48        0x177245385090 (BCD sqrt(pi))
    // .compressed_magic:48 0x314159265359 (BCD (pi))
    for (int i = 0; i < 6; ++i) {
      int b = br.readByte();
      if (b != BZ_COMPRESSED_MAGIC[i]) {
        compressed = false;
      }
      if (b != BZ_EOS_MAGIC[i]) {
        eos = false;
      }
      if (!eos && !compressed) {
        throw new ArchiveException('Invalid Block Signature');
      }
    }

    return (compressed) ? BLOCK_COMPRESSED : BLOCK_EOS;
  }

  int _readCompressed(BitReader br, OutputStream output) {
    int blockRandomized = br.readBits(1);
    int origPtr = br.readBits(8);
    origPtr = (origPtr << 8) | br.readBits(8);
    origPtr = (origPtr << 8) | br.readBits(8);

    // Receive the mapping table
    _inUse16 = new Data.Uint8List(16);
    for (int i = 0; i < 16; ++i) {
      _inUse16[i] = br.readBits(1);
    }

    _inUse = new Data.Uint8List(256);
    for (int i = 0, k = 0; i < 16; ++i, k += 16) {
      if (_inUse16[i] != 0) {
        for (int j = 0; j < 16; ++j) {
          _inUse[k + j] = br.readBits(1);
        }
      }
    }

    _makeMaps();
    if (_numInUse == 0) {
      throw new ArchiveException('Data error');
    }

    int alphaSize = _numInUse + 2;

    // Now the selectors
    int numGroups = br.readBits(3);
    if (numGroups < 2 || numGroups > 6) {
      throw new ArchiveException('Data error');
    }

    _numSelectors = br.readBits(15);
    if (_numSelectors < 1) {
      throw new ArchiveException('Data error');
    }

    _selectorMtf = new Data.Uint8List(BZ_MAX_SELECTORS);
    _selector = new Data.Uint8List(BZ_MAX_SELECTORS);

    for (int i = 0; i < _numSelectors; ++i) {
      int j = 0;
      while (true) {
        int b = br.readBits(1);
        if (b == 0) {
          break;
        }
        j++;
        if (j >= numGroups) {
          throw new ArchiveException('Data error');
        }
      }

      _selectorMtf[i] = j;
    }

    // Undo the MTF values for the selectors.
    Data.Uint8List pos = new Data.Uint8List(BZ_N_GROUPS);
    for (int i = 0; i < numGroups; ++i) {
      pos[i] = i;
    }

    for (int i = 0; i < _numSelectors; ++i) {
      int v = _selectorMtf[i];
      int tmp = pos[v];
      while (v > 0) {
        pos[v] = pos[v - 1];
        v--;
      }
      pos[0] = tmp;
      _selector[i] = tmp;
    }

    // Now the coding tables
    _len = new List<Data.Uint8List>(BZ_N_GROUPS);

    for (int t = 0; t < numGroups; ++t) {
      _len[t] = new Data.Uint8List(BZ_MAX_ALPHA_SIZE);

      int c = br.readBits(5);
      for (int i = 0; i < alphaSize; ++i) {
        while (true) {
          if (c < 1 || c > 20) {
            throw new ArchiveException('Data error');
          }
          int b = br.readBits(1);
          if (b == 0) {
            break;
          }
          b = br.readBits(1);
          if (b == 0) {
            c++;
          } else {
            c--;
          }
        }
        _len[t][i] = c;
      }
    }

    // Create the Huffman decoding tables
    _limit = new List<Data.Int32List>(BZ_N_GROUPS);
    _base = new List<Data.Int32List>(BZ_N_GROUPS);
    _perm = new List<Data.Int32List>(BZ_N_GROUPS);
    _minLens = new Data.Int32List(BZ_N_GROUPS);

    for (int t = 0; t < numGroups; t++) {
      _limit[t] = new Data.Int32List(BZ_MAX_ALPHA_SIZE);
      _base[t] = new Data.Int32List(BZ_MAX_ALPHA_SIZE);
      _perm[t] = new Data.Int32List(BZ_MAX_ALPHA_SIZE);

      int minLen = 32;
      int maxLen = 0;
      for (int i = 0; i < alphaSize; ++i) {
        if (_len[t][i] > maxLen) {
          maxLen = _len[t][i];
        }
        if (_len[t][i] < minLen) {
          minLen = _len[t][i];
        }
      }

      _hbCreateDecodeTables(_limit[t], _base[t], _perm[t], _len[t],
                            minLen, maxLen, alphaSize);

      _minLens[t] = minLen;
    }

    // Now the MTF values
    int EOB = _numInUse + 1;
    int nblockMAX = 100000 * _blockSize100k;
    int groupNo  = -1;
    int groupPos = 0;

    _unzftab = new Data.Int32List(256);

    // MTF init
    _mtfa = new Data.Uint8List(MTFA_SIZE);
    _mtfbase = new Data.Int32List(256 ~/ MTFL_SIZE);

    int kk = MTFA_SIZE - 1;
    for (int ii = 256 ~/ MTFL_SIZE - 1; ii >= 0; ii--) {
      for (int jj = MTFL_SIZE - 1; jj >= 0; jj--) {
        _mtfa[kk] = ii * MTFL_SIZE + jj;
        kk--;
      }
      _mtfbase[ii] = kk + 1;
    }

    int nblock = 0;
    _groupPos = 0;
    _groupNo = -1;
    int nextSym = _getMtfVal(br);
    int uc = 0;

    while (true) {
      if (nextSym == EOB) {
        break;
      }

      if (nextSym == BZ_RUNA || nextSym == BZ_RUNB) {
        int es = -1;
        int N = 1;
        do {
          // Check that N doesn't get too big, so that es doesn't
          // go negative.  The maximum value that can be
          // RUNA/RUNB encoded is equal to the block size (post
          // the initial RLE), viz, 900k, so bounding N at 2
          // million should guard against overflow without
          // rejecting any legitimate inputs.
          if (N >= 2 * 1024 * 1024) {
            throw new ArchiveException('Data error');
          }

          if (nextSym == BZ_RUNA) {
            es = es + (0 + 1) * N;
          } else if (nextSym == BZ_RUNB) {
            es = es + (1 + 1) * N;
          }

          N = N * 2;

          nextSym = _getMtfVal(br);
        } while (nextSym == BZ_RUNA || nextSym == BZ_RUNB);

        es++;

        uc = _seqToUnseq[_mtfa[_mtfbase[0]]];
        _unzftab[uc] += es;

        while (es > 0) {
          if (nblock >= nblockMAX) {
            throw new ArchiveException('Data error');
          }

          _tt[nblock] = uc;

          nblock++;
          es--;
        };

        continue;
      } else {
        if (nblock >= nblockMAX) {
          throw new ArchiveException('Data error');
        }

        // uc = MTF ( nextSym-1 )
        int nn = nextSym - 1;

        if (nn < MTFL_SIZE) {
          // avoid general-case expense
          int pp = _mtfbase[0];
          uc = _mtfa[pp + nn];
          while (nn > 3) {
            int z = pp + nn;
            _mtfa[(z)] = _mtfa[(z)-1];
            _mtfa[(z) - 1] = _mtfa[(z) - 2];
            _mtfa[(z) - 2] = _mtfa[(z) - 3];
            _mtfa[(z) - 3] = _mtfa[(z) - 4];
            nn -= 4;
          }
          while (nn > 0) {
            _mtfa[(pp+nn)] = _mtfa[(pp + nn) - 1];
            nn--;
          }
          _mtfa[pp] = uc;
        } else {
          // general case
          int lno = nn ~/ MTFL_SIZE;
          int off = nn % MTFL_SIZE;
          int pp = _mtfbase[lno] + off;
          uc = _mtfa[pp];
          while (pp > _mtfbase[lno]) {
            _mtfa[pp] = _mtfa[pp - 1];
            pp--;
          }
          _mtfbase[lno]++;
          while (lno > 0) {
            _mtfbase[lno]--;
            _mtfa[_mtfbase[lno]] = _mtfa[_mtfbase[lno - 1] + MTFL_SIZE - 1];
            lno--;
          }
          _mtfbase[0]--;
          _mtfa[_mtfbase[0]] = uc;
          if (_mtfbase[0] == 0) {
            kk = MTFA_SIZE-1;
            for (int ii = 256 ~/ MTFL_SIZE - 1; ii >= 0; ii--) {
              for (int jj = MTFL_SIZE - 1; jj >= 0; jj--) {
                _mtfa[kk] = _mtfa[_mtfbase[ii] + jj];
                kk--;
              }
              _mtfbase[ii] = kk + 1;
            }
          }
        }

        // end uc = MTF ( nextSym-1 )
        _unzftab[_seqToUnseq[uc]]++;
        _tt[nblock] = (_seqToUnseq[uc]);
        nblock++;

        nextSym = _getMtfVal(br);
        continue;
      }
    }

    // Now we know what nblock is, we can do a better sanity
    // check on s->origPtr.
    if (origPtr < 0 || origPtr >= nblock) {
      throw new ArchiveException('Data error');
    }

    // Set up cftab to facilitate generation of T^(-1)
    // Check: unzftab entries in range.
    for (int i = 0; i <= 255; i++) {
      if (_unzftab[i] < 0 || _unzftab[i] > nblock) {
        throw new ArchiveException('Data error');
      }
    }

    // Actually generate cftab.
    _cftab = new Data.Int32List(257);
    _cftab[0] = 0;
    for (int i = 1; i <= 256; i++) {
      _cftab[i] = _unzftab[i - 1];
    }

    for (int i = 1; i <= 256; i++) {
      _cftab[i] += _cftab[i - 1];
    }

    // Check: cftab entries in range.
    for (int i = 0; i <= 256; i++) {
      if (_cftab[i] < 0 || _cftab[i] > nblock) {
        // s->cftab[i] can legitimately be == nblock
        throw new ArchiveException('Data error');
      }
    }

    // Check: cftab entries non-descending.
    for (int i = 1; i <= 256; i++) {
      if (_cftab[i - 1] > _cftab[i]) {
        throw new ArchiveException('Data error');
      }
    }

    // compute the T^(-1) vector
    for (int i = 0; i < nblock; i++) {
      uc = (_tt[i] & 0xff);
      _tt[_cftab[uc]] |= (i << 8);
      _cftab[uc]++;
    }

    int blockCrc = _INITIAL_CRC;

    int tPos = _tt[origPtr] >> 8;
    int numBlockUsed = 0;
    int k0;
    int rNToGo = 0;
    int rTPos = 0;

    if (blockRandomized != 0) {
      rNToGo = 0;
      rTPos = 0;

      if (tPos >= 100000 * _blockSize100k) {
        throw new ArchiveException('Data error');
      }
      tPos = _tt[tPos];
      k0 = tPos & 0xff;
      tPos >>= 8;

      numBlockUsed++;

      if (rNToGo == 0) {
        rNToGo = BZ2_rNums[rTPos];
        rTPos++;
        if (rTPos == 512) {
          rTPos = 0;
        }
      }
      rNToGo--;

      k0 ^= ((rNToGo == 1) ? 1 : 0);
    } else {
      // c_tPos is unsigned, hence test < 0 is pointless.
      if (tPos >= 100000 * _blockSize100k) {
        return blockCrc;
      }
      tPos = _tt[tPos];
      k0 = (tPos & 0xff);
      tPos >>= 8;
      numBlockUsed++;
    }

    // UnRLE to output
    int c_state_out_len = 0;
    int c_state_out_ch = 0;
    int s_save_nblockPP = nblock + 1;
    int c_nblock_used = numBlockUsed;
    int c_k0 = k0;
    int k1;

    if (blockRandomized != 0) {
      while (true) {
        // try to finish existing run
        while (true) {
          if (c_state_out_len == 0) {
            break;
          }

          output.writeByte(c_state_out_ch);
          blockCrc = _updateCrc(c_state_out_ch, blockCrc);

          c_state_out_len--;
        }

        // can a new run be started?
        if (c_nblock_used == s_save_nblockPP) {
          return blockCrc;
        }

        // Only caused by corrupt data stream?
        if (c_nblock_used > s_save_nblockPP) {
          throw new ArchiveException('Data error.');
        }

        c_state_out_len = 1;
        c_state_out_ch = k0;
        tPos = _tt[tPos];
        k1 = tPos & 0xff;
        tPos >>= 8;
        if (rNToGo == 0) {
          rNToGo = BZ2_rNums[rTPos];
          rTPos++;
          if (rTPos == 512) {
            rTPos = 0;
          }
        }
        rNToGo--;
        k1 ^= ((rNToGo == 1) ? 1 : 0);
        c_nblock_used++;
        if (c_nblock_used == s_save_nblockPP) {
          continue;
        }
        if (k1 != k0) {
          k0 = k1;
          continue;
        }

        c_state_out_len = 2;
        tPos = _tt[tPos];
        k1 = tPos & 0xff;
        tPos >>= 8;
        if (rNToGo == 0) {
          rNToGo = BZ2_rNums[rTPos];
          rTPos++;
          if (rTPos == 512) {
            rTPos = 0;
          }
        }
        k1 ^= ((rNToGo == 1) ? 1 : 0);
        c_nblock_used++;
        if (c_nblock_used == s_save_nblockPP) {
          continue;
        }
        if (k1 != k0) {
          k0 = k1;
          continue;
        }

        c_state_out_len = 3;
        tPos = _tt[tPos];
        k1 = tPos & 0xff;
        tPos >>= 8;
        if (rNToGo == 0) {
          rNToGo = BZ2_rNums[rTPos];
          rTPos++;
          if (rTPos == 512) {
            rTPos = 0;
          }
        }
        k1 ^= ((rNToGo == 1) ? 1 : 0);
        c_nblock_used++;
        if (c_nblock_used == s_save_nblockPP) {
          continue;
        }
        if (k1 != k0) {
          k0 = k1;
          continue;
        }

        tPos = _tt[tPos];
        k1 = tPos & 0xff;
        tPos >>= 8;
        if (rNToGo == 0) {
          rNToGo = BZ2_rNums[rTPos];
          rTPos++;
          if (rTPos == 512) {
            rTPos = 0;
          }
        }
        k1 ^= ((rNToGo == 1) ? 1 : 0);
        c_nblock_used++;
        c_state_out_len = k1 + 4;

        tPos = _tt[tPos];
        k0 = tPos & 0xff;
        tPos >>= 8;
        if (rNToGo == 0) {
          rNToGo = BZ2_rNums[rTPos];
          rTPos++;
          if (rTPos == 512) {
            rTPos = 0;
          }
        }
        k0 ^= ((rNToGo == 1) ? 1 : 0);
        c_nblock_used++;
      }
    } else {
      while (true) {
        // try to finish existing run
        if (c_state_out_len > 0) {
          while (true) {
            if (c_state_out_len == 1) {
              break;
            }

            output.writeByte(c_state_out_ch);
            blockCrc = _updateCrc(c_state_out_ch, blockCrc);

            c_state_out_len--;
          }

          output.writeByte(c_state_out_ch);
          blockCrc = _updateCrc(c_state_out_ch, blockCrc);
        }

        // Only caused by corrupt data stream?
        if (c_nblock_used > s_save_nblockPP) {
          throw new ArchiveException('Data error');
        }

        // can a new run be started?
        if (c_nblock_used == s_save_nblockPP) {
          c_state_out_len = 0;
          return blockCrc;
        }

        c_state_out_ch = c_k0;

        int k1;

        if (tPos >= 100000 * _blockSize100k) {
          throw new ArchiveException('Data Error');
        }
        tPos = _tt[tPos];
        k1 = tPos & 0xff;
        tPos >>= 8;

        c_nblock_used++;
        if (k1 != c_k0) {
          c_k0 = k1;
          output.writeByte(c_state_out_ch);
          blockCrc = _updateCrc(c_state_out_ch, blockCrc);
          c_state_out_len = 0;
          continue;
        }

        if (c_nblock_used == s_save_nblockPP) {
          output.writeByte(c_state_out_ch);
          blockCrc = _updateCrc(c_state_out_ch, blockCrc);
          c_state_out_len = 0;
          continue;
        }

        c_state_out_len = 2;
        if (tPos >= 100000 * _blockSize100k) {
          throw new ArchiveException('Data Error');
        }
        tPos = _tt[tPos];
        k1 = tPos & 0xff;
        tPos >>= 8;
        c_nblock_used++;

        if (c_nblock_used == s_save_nblockPP) {
          continue;
        }

        if (k1 != c_k0) {
          c_k0 = k1;
          continue;
        }

        c_state_out_len = 3;
        if (tPos >= 100000 * _blockSize100k) {
          throw new ArchiveException('Data Error');
        }
        tPos = _tt[tPos];
        k1 = tPos & 0xff;
        tPos >>= 8;
        c_nblock_used++;

        if (c_nblock_used == s_save_nblockPP) {
          continue;
        }

        if (k1 != c_k0) {
          c_k0 = k1;
          continue;
        }

        if (tPos >= 100000 * _blockSize100k) {
          throw new ArchiveException('Data Error');
        }
        tPos = _tt[tPos];
        k1 = tPos & 0xff;
        tPos >>= 8;
        c_nblock_used++;

        c_state_out_len = k1 + 4;

        if (tPos >= 100000 * _blockSize100k) {
          throw new ArchiveException('Data Error');
        }
        tPos = _tt[tPos];
        c_k0 = tPos & 0xff;
        tPos >>= 8;

        c_nblock_used++;
      }
    }

    return blockCrc;
  }

  int _getMtfVal(BitReader br) {
    if (_groupPos == 0) {
      _groupNo++;
      if (_groupNo >= _numSelectors) {
        throw new ArchiveException('Data error');
      }

      _groupPos = BZ_G_SIZE;
      _gSel = _selector[_groupNo];
      _gMinlen = _minLens[_gSel];
      _gLimit = _limit[_gSel];
      _gPerm = _perm[_gSel];
      _gBase = _base[_gSel];
    }

    _groupPos--;
    int zn = _gMinlen;
    int zvec = br.readBits(zn);

    while (true) {
      if (zn > 20) {
        throw new ArchiveException('Data error');
      }
      if (zvec <= _gLimit[zn]) {
        break;
      }

      zn++;
      int zj = br.readBits(1);
      zvec = (zvec << 1) | zj;
    }

    if (zvec - _gBase[zn] < 0 || zvec - _gBase[zn] >= BZ_MAX_ALPHA_SIZE) {
      throw new ArchiveException('Data error');
    }

    return _gPerm[zvec - _gBase[zn]];
  }

  void _hbCreateDecodeTables(Data.Int32List limit, Data.Int32List base,
                             Data.Int32List perm, Data.Uint8List length,
                             int minLen, int maxLen, int alphaSize) {
    int pp = 0;
    for (int i = minLen; i <= maxLen; i++) {
      for (int j = 0; j < alphaSize; j++) {
        if (length[j] == i) {
          perm[pp] = j; pp++;
        }
      }
    }

    for (int i = 0; i < BZ_MAX_CODE_LEN; i++) {
      base[i] = 0;
    }

    for (int i = 0; i < alphaSize; i++) {
      base[length[i]+1]++;
    }

    for (int i = 1; i < BZ_MAX_CODE_LEN; i++) {
      base[i] += base[i - 1];
    }

    for (int i = 0; i < BZ_MAX_CODE_LEN; i++) {
      limit[i] = 0;
    }

    int vec = 0;

    for (int i = minLen; i <= maxLen; i++) {
      vec += (base[i + 1] - base[i]);
      limit[i] = vec-1;
      vec <<= 1;
    }

    for (int i = minLen + 1; i <= maxLen; i++) {
      base[i] = ((limit[i - 1] + 1) << 1) - base[i];
    }
  }

  void _makeMaps() {
    _numInUse = 0;
    _seqToUnseq = new Data.Uint8List(256);
    for (int i = 0; i < 256; ++i) {
      if (_inUse[i] != 0) {
        _seqToUnseq[_numInUse++] = i;
      }
    }
  }

  static int _INITIAL_CRC = 0xffffffff;

  static int _updateCrc(int value, int crc) {
    return ((crc << 8) ^
            _BZ2_CRC32_TABLE[(crc >> 24) & 0xff ^ (value & 0xff)]) & 0xffffffff;
  }

  static int _finalizeCrc(int crc) {
    return crc ^ 0xffffffff;
  }

  int _blockSize100k;
  Data.Uint32List _tt;
  Data.Uint8List _inUse16;
  Data.Uint8List _inUse;
  Data.Uint8List _seqToUnseq;
  Data.Uint8List _mtfa;
  Data.Int32List _mtfbase;
  Data.Uint8List _selectorMtf;
  Data.Uint8List _selector;
  List<Data.Int32List> _limit;
  List<Data.Int32List> _base;
  List<Data.Int32List> _perm;
  Data.Int32List _minLens;
  Data.Int32List _unzftab;

  int _numSelectors;
  int _groupPos = 0;
  int _groupNo = -1;
  int _gSel = 0;
  int _gMinlen = 0;
  Data.Int32List _gLimit;
  Data.Int32List _gPerm;
  Data.Int32List _gBase;
  Data.Int32List _cftab;

  List<Data.Uint8List> _len;
  int _numInUse = 0;
  int _combinedCrc;

  // Only BZh version signature is supported (BZ0 is depricated).
  static const int BZ_HDR_0 = 0x30;
  static const int BZ_N_GROUPS = 6;
  static const int BZ_G_SIZE = 50;
  static const int BZ_N_ITERS = 4;
  static const int BZ_MAX_ALPHA_SIZE = 258;
  static const int BZ_MAX_CODE_LEN = 23;
  static const int BZ_MAX_SELECTORS = (2 + (900000 ~/ BZ_G_SIZE));
  static const int MTFA_SIZE = 4096;
  static const int MTFL_SIZE = 16;
  static const int BZ_RUNA = 0;
  static const int BZ_RUNB = 1;

  static const List<int> BZ2_SIGNATURE = const [0x42, 0x5a, 0x68];

  static const List<int> BZ_COMPRESSED_MAGIC = const [
    0x31, 0x41, 0x59, 0x26, 0x53, 0x59];

  static const List<int> BZ_EOS_MAGIC = const [
    0x17, 0x72, 0x45, 0x38, 0x50, 0x90];

  static const int BLOCK_COMPRESSED = 0;
  static const int BLOCK_EOS = 2;

  static const List<int> BZ2_rNums = const [
     619, 720, 127, 481, 931, 816, 813, 233, 566, 247,
     985, 724, 205, 454, 863, 491, 741, 242, 949, 214,
     733, 859, 335, 708, 621, 574, 73, 654, 730, 472,
     419, 436, 278, 496, 867, 210, 399, 680, 480, 51,
     878, 465, 811, 169, 869, 675, 611, 697, 867, 561,
     862, 687, 507, 283, 482, 129, 807, 591, 733, 623,
     150, 238, 59, 379, 684, 877, 625, 169, 643, 105,
     170, 607, 520, 932, 727, 476, 693, 425, 174, 647,
     73, 122, 335, 530, 442, 853, 695, 249, 445, 515,
     909, 545, 703, 919, 874, 474, 882, 500, 594, 612,
     641, 801, 220, 162, 819, 984, 589, 513, 495, 799,
     161, 604, 958, 533, 221, 400, 386, 867, 600, 782,
     382, 596, 414, 171, 516, 375, 682, 485, 911, 276,
     98, 553, 163, 354, 666, 933, 424, 341, 533, 870,
     227, 730, 475, 186, 263, 647, 537, 686, 600, 224,
     469, 68, 770, 919, 190, 373, 294, 822, 808, 206,
     184, 943, 795, 384, 383, 461, 404, 758, 839, 887,
     715, 67, 618, 276, 204, 918, 873, 777, 604, 560,
     951, 160, 578, 722, 79, 804, 96, 409, 713, 940,
     652, 934, 970, 447, 318, 353, 859, 672, 112, 785,
     645, 863, 803, 350, 139, 93, 354, 99, 820, 908,
     609, 772, 154, 274, 580, 184, 79, 626, 630, 742,
     653, 282, 762, 623, 680, 81, 927, 626, 789, 125,
     411, 521, 938, 300, 821, 78, 343, 175, 128, 250,
     170, 774, 972, 275, 999, 639, 495, 78, 352, 126,
     857, 956, 358, 619, 580, 124, 737, 594, 701, 612,
     669, 112, 134, 694, 363, 992, 809, 743, 168, 974,
     944, 375, 748, 52, 600, 747, 642, 182, 862, 81,
     344, 805, 988, 739, 511, 655, 814, 334, 249, 515,
     897, 955, 664, 981, 649, 113, 974, 459, 893, 228,
     433, 837, 553, 268, 926, 240, 102, 654, 459, 51,
     686, 754, 806, 760, 493, 403, 415, 394, 687, 700,
     946, 670, 656, 610, 738, 392, 760, 799, 887, 653,
     978, 321, 576, 617, 626, 502, 894, 679, 243, 440,
     680, 879, 194, 572, 640, 724, 926, 56, 204, 700,
     707, 151, 457, 449, 797, 195, 791, 558, 945, 679,
     297, 59, 87, 824, 713, 663, 412, 693, 342, 606,
     134, 108, 571, 364, 631, 212, 174, 643, 304, 329,
     343, 97, 430, 751, 497, 314, 983, 374, 822, 928,
     140, 206, 73, 263, 980, 736, 876, 478, 430, 305,
     170, 514, 364, 692, 829, 82, 855, 953, 676, 246,
     369, 970, 294, 750, 807, 827, 150, 790, 288, 923,
     804, 378, 215, 828, 592, 281, 565, 555, 710, 82,
     896, 831, 547, 261, 524, 462, 293, 465, 502, 56,
     661, 821, 976, 991, 658, 869, 905, 758, 745, 193,
     768, 550, 608, 933, 378, 286, 215, 979, 792, 961,
     61, 688, 793, 644, 986, 403, 106, 366, 905, 644,
     372, 567, 466, 434, 645, 210, 389, 550, 919, 135,
     780, 773, 635, 389, 707, 100, 626, 958, 165, 504,
     920, 176, 193, 713, 857, 265, 203, 50, 668, 108,
     645, 990, 626, 197, 510, 357, 358, 850, 858, 364,
     936, 638];

  static const List<int> _BZ2_CRC32_TABLE = const [
     0x00000000, 0x04c11db7, 0x09823b6e, 0x0d4326d9,
     0x130476dc, 0x17c56b6b, 0x1a864db2, 0x1e475005,
     0x2608edb8, 0x22c9f00f, 0x2f8ad6d6, 0x2b4bcb61,
     0x350c9b64, 0x31cd86d3, 0x3c8ea00a, 0x384fbdbd,
     0x4c11db70, 0x48d0c6c7, 0x4593e01e, 0x4152fda9,
     0x5f15adac, 0x5bd4b01b, 0x569796c2, 0x52568b75,
     0x6a1936c8, 0x6ed82b7f, 0x639b0da6, 0x675a1011,
     0x791d4014, 0x7ddc5da3, 0x709f7b7a, 0x745e66cd,
     0x9823b6e0, 0x9ce2ab57, 0x91a18d8e, 0x95609039,
     0x8b27c03c, 0x8fe6dd8b, 0x82a5fb52, 0x8664e6e5,
     0xbe2b5b58, 0xbaea46ef, 0xb7a96036, 0xb3687d81,
     0xad2f2d84, 0xa9ee3033, 0xa4ad16ea, 0xa06c0b5d,
     0xd4326d90, 0xd0f37027, 0xddb056fe, 0xd9714b49,
     0xc7361b4c, 0xc3f706fb, 0xceb42022, 0xca753d95,
     0xf23a8028, 0xf6fb9d9f, 0xfbb8bb46, 0xff79a6f1,
     0xe13ef6f4, 0xe5ffeb43, 0xe8bccd9a, 0xec7dd02d,
     0x34867077, 0x30476dc0, 0x3d044b19, 0x39c556ae,
     0x278206ab, 0x23431b1c, 0x2e003dc5, 0x2ac12072,
     0x128e9dcf, 0x164f8078, 0x1b0ca6a1, 0x1fcdbb16,
     0x018aeb13, 0x054bf6a4, 0x0808d07d, 0x0cc9cdca,
     0x7897ab07, 0x7c56b6b0, 0x71159069, 0x75d48dde,
     0x6b93dddb, 0x6f52c06c, 0x6211e6b5, 0x66d0fb02,
     0x5e9f46bf, 0x5a5e5b08, 0x571d7dd1, 0x53dc6066,
     0x4d9b3063, 0x495a2dd4, 0x44190b0d, 0x40d816ba,
     0xaca5c697, 0xa864db20, 0xa527fdf9, 0xa1e6e04e,
     0xbfa1b04b, 0xbb60adfc, 0xb6238b25, 0xb2e29692,
     0x8aad2b2f, 0x8e6c3698, 0x832f1041, 0x87ee0df6,
     0x99a95df3, 0x9d684044, 0x902b669d, 0x94ea7b2a,
     0xe0b41de7, 0xe4750050, 0xe9362689, 0xedf73b3e,
     0xf3b06b3b, 0xf771768c, 0xfa325055, 0xfef34de2,
     0xc6bcf05f, 0xc27dede8, 0xcf3ecb31, 0xcbffd686,
     0xd5b88683, 0xd1799b34, 0xdc3abded, 0xd8fba05a,
     0x690ce0ee, 0x6dcdfd59, 0x608edb80, 0x644fc637,
     0x7a089632, 0x7ec98b85, 0x738aad5c, 0x774bb0eb,
     0x4f040d56, 0x4bc510e1, 0x46863638, 0x42472b8f,
     0x5c007b8a, 0x58c1663d, 0x558240e4, 0x51435d53,
     0x251d3b9e, 0x21dc2629, 0x2c9f00f0, 0x285e1d47,
     0x36194d42, 0x32d850f5, 0x3f9b762c, 0x3b5a6b9b,
     0x0315d626, 0x07d4cb91, 0x0a97ed48, 0x0e56f0ff,
     0x1011a0fa, 0x14d0bd4d, 0x19939b94, 0x1d528623,
     0xf12f560e, 0xf5ee4bb9, 0xf8ad6d60, 0xfc6c70d7,
     0xe22b20d2, 0xe6ea3d65, 0xeba91bbc, 0xef68060b,
     0xd727bbb6, 0xd3e6a601, 0xdea580d8, 0xda649d6f,
     0xc423cd6a, 0xc0e2d0dd, 0xcda1f604, 0xc960ebb3,
     0xbd3e8d7e, 0xb9ff90c9, 0xb4bcb610, 0xb07daba7,
     0xae3afba2, 0xaafbe615, 0xa7b8c0cc, 0xa379dd7b,
     0x9b3660c6, 0x9ff77d71, 0x92b45ba8, 0x9675461f,
     0x8832161a, 0x8cf30bad, 0x81b02d74, 0x857130c3,
     0x5d8a9099, 0x594b8d2e, 0x5408abf7, 0x50c9b640,
     0x4e8ee645, 0x4a4ffbf2, 0x470cdd2b, 0x43cdc09c,
     0x7b827d21, 0x7f436096, 0x7200464f, 0x76c15bf8,
     0x68860bfd, 0x6c47164a, 0x61043093, 0x65c52d24,
     0x119b4be9, 0x155a565e, 0x18197087, 0x1cd86d30,
     0x029f3d35, 0x065e2082, 0x0b1d065b, 0x0fdc1bec,
     0x3793a651, 0x3352bbe6, 0x3e119d3f, 0x3ad08088,
     0x2497d08d, 0x2056cd3a, 0x2d15ebe3, 0x29d4f654,
     0xc5a92679, 0xc1683bce, 0xcc2b1d17, 0xc8ea00a0,
     0xd6ad50a5, 0xd26c4d12, 0xdf2f6bcb, 0xdbee767c,
     0xe3a1cbc1, 0xe760d676, 0xea23f0af, 0xeee2ed18,
     0xf0a5bd1d, 0xf464a0aa, 0xf9278673, 0xfde69bc4,
     0x89b8fd09, 0x8d79e0be, 0x803ac667, 0x84fbdbd0,
     0x9abc8bd5, 0x9e7d9662, 0x933eb0bb, 0x97ffad0c,
     0xafb010b1, 0xab710d06, 0xa6322bdf, 0xa2f33668,
     0xbcb4666d, 0xb8757bda, 0xb5365d03, 0xb1f740b4];
}
