part of archive;

/**
 * Decompress bzip2 compressed data.
 * Derived from libbzip2 (http://www.bzip.org).
 * BZip2 data is stored in BIG_ENDIAN byteOrder.
 */
class BZip2Decoder {
  List<int> decodeBytes(List<int> data, {bool verify: true}) {
    return decodeBuffer(new InputStream(data, byteOrder: BIG_ENDIAN),
                        verify: verify);
  }

  List<int> decodeBuffer(InputStream input, {bool verify: false}) {
    OutputStream output = new OutputStream();

    _groupPos = 0;
    _groupNo = 0;
    _gSel = 0;
    _gMinlen = 0;

    // FORMAT
    // .magic:16                       = 'BZ' signature/magic number
    // .version:8                      = 'h' for Bzip2 ('H'uffman coding), '0' for Bzip1 (deprecated)
    // .hundred_k_blocksize:8          = '1'..'9' block-size 100 kB-900 kB (uncompressed)
    //
    // .compressed_magic:48            = 0x314159265359 (BCD (pi))
    // .crc:32                         = checksum for this block
    // .randomised:1                   = 0=>normal, 1=>randomised (deprecated)
    // .origPtr:24                     = starting pointer into BWT for after untransform
    // .huffman_used_map:16            = bitmap, of ranges of 16 bytes, present/not present
    // .huffman_used_bitmaps:0..256    = bitmap, of symbols used, present/not present (multiples of 16)
    // .huffman_groups:3               = 2..6 number of different Huffman tables in use
    // .selectors_used:15              = number of times that the Huffman tables are swapped (each 50 bytes)
    // *.selector_list:1..6            = zero-terminated bit runs (0..62) of MTF'ed Huffman table (*selectors_used)
    // .start_huffman_length:5         = 0..20 starting bit length for Huffman deltas
    // *.delta_bit_length:1..40        = 0=>next symbol; 1=>alter length
    //                                                { 1=>decrement length;  0=>increment length } (*(symbols+2)*groups)
    // .contents:2..∞                  = Huffman encoded data stream until end of block
    //
    // .eos_magic:48                   = 0x177245385090 (BCD sqrt(pi))
    // .crc:32                         = checksum for whole stream
    // .padding:0..7                   = align to whole byte
    if (input.readByte() != BZ2_SIGNATURE[0] ||
        input.readByte() != BZ2_SIGNATURE[1] ||
        input.readByte() != BZ2_SIGNATURE[2]) {
      throw new ArchiveException('Invalid Signature');
    }

    _blockSize100k = input.readByte() - BZ_HDR_0;
    if (_blockSize100k < 0 || _blockSize100k > 9) {
      throw new ArchiveException('Invalid BlockSize');
    }

    _tt = new Data.Uint32List(_blockSize100k * 100000);

    while (true) {
      int type = _readBlockType(input);
      if (type == BLOCK_COMPRESSED) {
        _readCompressed(input, output);
      } else if (type == BLOCK_EOS) {
        int crc = input.readUint32();
        return output.getBytes();
      }
    }

    return null;
  }

  int _readBlockType(InputStream input) {
    bool eos = true;
    bool compressed = true;

    // .eos_magic:48        0x177245385090 (BCD sqrt(pi))
    // .compressed_magic:48 0x314159265359 (BCD (pi))
    Data.Uint8List magic = input.readBytes(6);
    for (int i = 0; i < 6; ++i) {
      if (magic[i] != BZ_COMPRESSED_MAGIC[i]) {
        compressed = false;
      }
      if (magic[i] != BZ_EOS_MAGIC[i]) {
        eos = false;
      }
      if (!eos && !compressed) {
        throw new ArchiveException('Invalid Block Signature');
      }
    }


    return (compressed) ? BLOCK_COMPRESSED : BLOCK_EOS;
  }

  void _readCompressed(InputStream input, OutputStream output) {
    int crc = input.readUint32();

    BitReader br = new BitReader(input);

    int randomized = br.readBits(1);
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

    int tPos = _tt[origPtr] >> 8;
    int numBlockUsed = 0;
    int k0;
    /*if (_blockRandomised) {
      BZ_RAND_INIT_MASK;
      BZ_GET_FAST(k0);
      _numBlockUsed++;
      BZ_RAND_UPD_MASK;
      _k0 ^= BZ_RAND_MASK;
    } else*/ {
      //BZ_GET_FAST(k0);
      // c_tPos is unsigned, hence test < 0 is pointless.
      if (tPos >= 100000 * _blockSize100k) {
        return;
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

    while (true) {
      // try to finish existing run
      if (c_state_out_len > 0) {
        while (true) {
          if (c_state_out_len == 1) {
            break;
          }

          output.writeByte(c_state_out_ch);
          // update CRC
          c_state_out_len--;
        }

        output.writeByte(c_state_out_ch);
        // update CRC
      }

      // Only caused by corrupt data stream?
      if (c_nblock_used > s_save_nblockPP) {
        throw new ArchiveException('Data error');
      }

      // can a new run be started?
      if (c_nblock_used == s_save_nblockPP) {
        c_state_out_len = 0;
        return;
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
        // update CRC
        c_state_out_len = 0;
        continue;
      }

      if (c_nblock_used == s_save_nblockPP) {
        output.writeByte(c_state_out_ch);
        // update CRC
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
}
