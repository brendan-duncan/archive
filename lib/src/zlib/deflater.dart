part of archive;

class Deflater {
  static const int BEST_COMPRESSION = 9;
  static const int BEST_SPEED = 1;
  static const int DEFAULT_COMPRESSION = 6;
  static const int NO_COMPRESSION = 0;

  Deflater(List<int> bytes, {int level: DEFAULT_COMPRESSION}) :
    input = new InputBuffer(bytes) {
    _deflateInit(level);
    _deflate();
  }

  Deflater.buffer(this.input, {int level: DEFAULT_COMPRESSION}) {
    _deflateInit(level);
    _deflate();
  }

  List<int> getBytes() {
    return output.getBytes();
  }

  void _lm_init() {
    window_size = 2 * w_size;

    head[hash_size - 1] = 0;
    for (int i = 0; i < hash_size - 1; i++) {
      head[i] = 0;
    }

    // Set the default configuration parameters:
    max_lazy_match = config.max_lazy;
    good_match = config.good_length;
    nice_match = config.nice_length;
    max_chain_length = config.max_chain;

    strstart = 0;
    block_start = 0;
    lookahead = 0;
    match_length = prev_length = MIN_MATCH - 1;
    match_available = 0;
    ins_h = 0;
  }

  /**
   * Initialize the tree data structures for a new zlib stream.
   */
  void _tr_init() {
    l_desc.dyn_tree = dyn_ltree;
    l_desc.stat_desc = _StaticTree.static_l_desc;

    d_desc.dyn_tree = dyn_dtree;
    d_desc.stat_desc = _StaticTree.static_d_desc;

    bl_desc.dyn_tree = bl_tree;
    bl_desc.stat_desc = _StaticTree.static_bl_desc;

    bi_buf = 0;
    bi_valid = 0;
    last_eob_len = 8; // enough lookahead for inflate

    // Initialize the first block of the first file:
    _init_block();
  }

  void _init_block() {
    // Initialize the trees.
    for (int i = 0; i < L_CODES; i++) {
      dyn_ltree[i * 2] = 0;
    }
    for (int i = 0; i < D_CODES; i++) {
      dyn_dtree[i * 2] = 0;
    }
    for (int i = 0; i < BL_CODES; i++) {
      bl_tree[i * 2] = 0;
    }

    dyn_ltree[END_BLOCK * 2] = 1;
    opt_len = static_len = 0;
    last_lit = matches = 0;
  }

  /**
   * Restore the heap property by moving down the tree starting at node k,
   * exchanging a node with the smallest of its two sons if necessary, stopping
   * when the heap property is re-established (each father smaller than its
   * two sons).
   */
  void _pqdownheap(Data.Uint16List tree, int k) {
    int v = heap[k];
    int j = k << 1; // left son of k
    while (j <= heap_len) {
      // Set j to the smallest of the two sons:
      if (j < heap_len && _smaller(tree, heap[j + 1], heap[j], depth)) {
        j++;
      }
      // Exit if v is smaller than both sons
      if (_smaller(tree, v, heap[j], depth)) {
        break;
      }

      // Exchange v with the smallest son
      heap[k] = heap[j]; k = j;
      // And continue down the tree, setting j to the left son of k
      j <<= 1;
    }
    heap[k] = v;
  }

  static bool _smaller(Data.Uint16List tree, int n, int m,
                       Data.Uint8List depth) {
    return (tree[n * 2] < tree[m * 2] ||
            (tree[n * 2] == tree[m * 2] && depth[n] <= depth[m]));
  }

  /**
   * Scan a literal or distance tree to determine the frequencies of the codes
   * in the bit length tree.
   */
  void _scanTree(Data.Uint16List tree, int max_code) {
    int n; // iterates over all tree elements
    int prevlen = - 1; // last emitted length
    int curlen; // length of current code
    int nextlen = tree[0 * 2 + 1]; // length of next code
    int count = 0; // repeat count of the current code
    int max_count = 7; // max repeat count
    int min_count = 4; // min repeat count

    if (nextlen == 0) {
      max_count = 138; min_count = 3;
    }
    tree[(max_code + 1) * 2 + 1] = 0xffff; // guard

    for (n = 0; n <= max_code; n++) {
      curlen = nextlen; nextlen = tree[(n + 1) * 2 + 1];
      if (++count < max_count && curlen == nextlen) {
        continue;
      } else if (count < min_count) {
        bl_tree[curlen * 2] = (bl_tree[curlen * 2] + count);
      } else if (curlen != 0) {
        if (curlen != prevlen) {
          bl_tree[curlen * 2]++;
        }
        bl_tree[REP_3_6 * 2]++;
      } else if (count <= 10) {
        bl_tree[REPZ_3_10 * 2]++;
      } else {
        bl_tree[REPZ_11_138 * 2]++;
      }
      count = 0; prevlen = curlen;
      if (nextlen == 0) {
        max_count = 138; min_count = 3;
      } else if (curlen == nextlen) {
        max_count = 6; min_count = 3;
      } else {
        max_count = 7; min_count = 4;
      }
    }
  }

  // Construct the Huffman tree for the bit lengths and return the index in
  // bl_order of the last bit length code to send.
  int _buildBitLengthTree() {
    int max_blindex; // index of last bit length code of non zero freq

    // Determine the bit length frequencies for literal and distance trees
    _scanTree(dyn_ltree, l_desc.max_code);
    _scanTree(dyn_dtree, d_desc.max_code);

    // Build the bit length tree:
    bl_desc._buildTree(this);
    // opt_len now includes the length of the tree representations, except
    // the lengths of the bit lengths codes and the 5+5+4 bits for the counts.

    // Determine the number of bit length codes to send. The pkzip format
    // requires that at least 4 bit length codes be sent. (appnote.txt says
    // 3 but the actual value used is 4.)
    for (max_blindex = BL_CODES - 1; max_blindex >= 3; max_blindex--) {
      if (bl_tree[_Tree.bl_order[max_blindex] * 2 + 1] != 0) {
        break;
      }
    }
    // Update opt_len to include the bit length tree and counts
    opt_len += 3 * (max_blindex + 1) + 5 + 5 + 4;

    return max_blindex;
  }


  /**
   * Send the header for a block using dynamic Huffman trees: the counts, the
   * lengths of the bit length codes, the literal tree and the distance tree.
   * IN assertion: lcodes >= 257, dcodes >= 1, blcodes >= 4.
   */
  void _sendAllTrees(int lcodes, int dcodes, int blcodes) {
    int rank; // index in bl_order

    _sendBits(lcodes - 257, 5); // not +255 as stated in appnote.txt
    _sendBits(dcodes - 1, 5);
    _sendBits(blcodes - 4, 4); // not -3 as stated in appnote.txt
    for (rank = 0; rank < blcodes; rank++) {
      _sendBits(bl_tree[_Tree.bl_order[rank] * 2 + 1], 3);
    }
    _sendTree(dyn_ltree, lcodes - 1); // literal tree
    _sendTree(dyn_dtree, dcodes - 1); // distance tree
  }

  /**
   * Send a literal or distance tree in compressed form, using the codes in
   * bl_tree.
   */
  void _sendTree(Data.Uint16List tree, int max_code) {
    int n; // iterates over all tree elements
    int prevlen = - 1; // last emitted length
    int curlen; // length of current code
    int nextlen = tree[0 * 2 + 1]; // length of next code
    int count = 0; // repeat count of the current code
    int max_count = 7; // max repeat count
    int min_count = 4; // min repeat count

    if (nextlen == 0) {
      max_count = 138; min_count = 3;
    }

    for (n = 0; n <= max_code; n++) {
      curlen = nextlen; nextlen = tree[(n + 1) * 2 + 1];
      if (++count < max_count && curlen == nextlen) {
        continue;
      } else if (count < min_count) {
        do {
          _sendCode(curlen, bl_tree);
        } while (--count != 0);
      } else if (curlen != 0) {
        if (curlen != prevlen) {
          _sendCode(curlen, bl_tree);
          count--;
        }
        _sendCode(REP_3_6, bl_tree);
        _sendBits(count - 3, 2);
      } else if (count <= 10) {
        _sendCode(REPZ_3_10, bl_tree);
        _sendBits(count - 3, 3);
      } else {
        _sendCode(REPZ_11_138, bl_tree);
        _sendBits(count - 11, 7);
      }
      count = 0;
      prevlen = curlen;
      if (nextlen == 0) {
        max_count = 138;
        min_count = 3;
      } else if (curlen == nextlen) {
        max_count = 6;
        min_count = 3;
      } else {
        max_count = 7;
        min_count = 4;
      }
    }
  }

  /**
   * Output a byte on the stream.
   * IN assertion: there is enough room in pending_buf.
   */
  void _putBytes(Data.Uint8List p, int start, int len) {
    if (len == 0) {
      return;
    }
    pending_buf.setRange(pending, len, p, start);
    pending += len;
  }

  void _putByte(int c) {
    pending_buf[pending++] = c;
  }

  void _putShort(int w) {
    _putByte((w));
    _putByte((_URShift(w, 8)));
  }

  void _putShortMSB(int b) {
    _putByte((b >> 8));
    _putByte((b));
  }

  void _sendCode(int c, List<int> tree) {
    _sendBits((tree[c * 2] & 0xffff), (tree[c * 2 + 1] & 0xffff));
  }

  void _sendBits(int value_Renamed, int length) {
    int len = length;
    if (bi_valid > Buf_size - len) {
      int val = value_Renamed;
      bi_buf = (bi_buf | (((val << bi_valid) & 0xffff)));
      _putShort(bi_buf);
      bi_buf = (_URShift(val, (Buf_size - bi_valid)));
      bi_valid += len - Buf_size;
    } else {
      bi_buf = (bi_buf | ((((value_Renamed) << bi_valid) & 0xffff)));
      bi_valid += len;
    }
  }

  /**
   * Send one empty static block to give enough lookahead for inflate.
   * This takes 10 bits, of which 7 may remain in the bit buffer.
   * The current inflate code requires 9 bits of lookahead. If the
   * last two codes for the previous block (real code plus EOB) were coded
   * on 5 bits or less, inflate may have only 5+3 bits of lookahead to decode
   * the last real code. In this case we send two empty static blocks instead
   * of one. (There are no problems if the previous block is stored or fixed.)
   * To simplify the code, we assume the worst case of last real code encoded
   * on one bit only.
   */
  void _trAlign() {
    _sendBits(STATIC_TREES << 1, 3);
    _sendCode(END_BLOCK, _StaticTree.static_ltree);

    biFlush();

    // Of the 10 bits for the empty block, we have already sent
    // (10 - bi_valid) bits. The lookahead for the last real code (before
    // the EOB of the previous block) was thus at least one plus the length
    // of the EOB plus what we have just sent of the empty static block.
    if (1 + last_eob_len + 10 - bi_valid < 9) {
      _sendBits(STATIC_TREES << 1, 3);
      _sendCode(END_BLOCK, _StaticTree.static_ltree);
      biFlush();
    }

    last_eob_len = 7;
  }


  // Save the match info and tally the frequency counts. Return true if
  // the current block must be flushed.
  bool _trTally(int dist, int lc) {
    pending_buf[d_buf + last_lit * 2] = (_URShift(dist, 8));
    pending_buf[d_buf + last_lit * 2 + 1] = dist;

    pending_buf[l_buf + last_lit] = lc; last_lit++;

    if (dist == 0) {
      // lc is the unmatched char
      dyn_ltree[lc * 2]++;
    } else {
      matches++;
      // Here, lc is the match length - MIN_MATCH
      dist--; // dist = match distance - 1
      dyn_ltree[(_Tree._length_code[lc] + LITERALS + 1) * 2]++;
      dyn_dtree[_Tree._dCode(dist) * 2]++;
    }

    if ((last_lit & 0x1fff) == 0 && level > 2) {
      // Compute an upper bound for the compressed length
      int out_length = last_lit * 8;
      int in_length = strstart - block_start;
      int dcode;
      for (dcode = 0; dcode < D_CODES; dcode++) {
        out_length = (out_length + dyn_dtree[dcode * 2] * (5 + _Tree.extra_dbits[dcode]));
      }
      out_length = _URShift(out_length, 3);
      if ((matches < (last_lit / 2)) && out_length < in_length / 2) {
        return true;
      }
    }

    return (last_lit == lit_bufsize - 1);
    // We avoid equality with lit_bufsize because of wraparound at 64K
    // on 16 bit machines and because stored blocks are restricted to
    // 64K-1 bytes.
  }

  /**
   * Send the block data compressed using the given Huffman trees
   */
  void _compressBlock(List<int> ltree, List<int> dtree) {
    int dist; // distance of matched string
    int lc; // match length or unmatched char (if dist == 0)
    int lx = 0; // running index in l_buf
    int code; // the code to send
    int extra; // number of extra bits to send

    if (last_lit != 0) {
      do {
        dist = ((pending_buf[d_buf + lx * 2] << 8) & 0xff00) |
                (pending_buf[d_buf + lx * 2 + 1] & 0xff);
        lc = (pending_buf[l_buf + lx]) & 0xff; lx++;

        if (dist == 0) {
          _sendCode(lc, ltree); // send a literal byte
        } else {
          // Here, lc is the match length - MIN_MATCH
          code = _Tree._length_code[lc];

          _sendCode(code + LITERALS + 1, ltree); // send the length code
          extra = _Tree.extra_lbits[code];
          if (extra != 0) {
            lc -= _Tree.base_length[code];
            _sendBits(lc, extra); // send the extra length bits
          }
          dist--; // dist is now the match distance - 1
          code = _Tree._dCode(dist);

          _sendCode(code, dtree); // send the distance code
          extra = _Tree.extra_dbits[code];
          if (extra != 0) {
            dist -= _Tree.base_dist[code];
            _sendBits(dist, extra); // send the extra distance bits
          }
        } // literal or match pair ?

        // Check that the overlay between pending_buf and d_buf+l_buf is ok:
      } while (lx < last_lit);
    }

    _sendCode(END_BLOCK, ltree);
    last_eob_len = ltree[END_BLOCK * 2 + 1];
  }

  /**
   * Set the data type to ASCII or BINARY, using a crude approximation:
   * binary if more than 20% of the bytes are <= 6 or >= 128, ascii otherwise.
   * IN assertion: the fields freq of dyn_ltree are set and the total of all
   * frequencies does not exceed 64K (to fit in an int on 16 bit machines).
   */
  void setDataType() {
    int n = 0;
    int ascii_freq = 0;
    int bin_freq = 0;
    while (n < 7) {
      bin_freq += dyn_ltree[n * 2]; n++;
    }
    while (n < 128) {
      ascii_freq += dyn_ltree[n * 2]; n++;
    }
    while (n < LITERALS) {
      bin_freq += dyn_ltree[n * 2]; n++;
    }
    data_type = (bin_freq > (_URShift(ascii_freq, 2)) ?
                Z_BINARY : Z_ASCII);
  }

  /**
   * Flush the bit buffer, keeping at most 7 bits in it.
   */
  void biFlush() {
    if (bi_valid == 16) {
      _putShort(bi_buf);
      bi_buf = 0;
      bi_valid = 0;
    } else if (bi_valid >= 8) {
      _putByte(bi_buf);
      bi_buf = (_URShift(bi_buf, 8));
      bi_valid -= 8;
    }
  }

  /**
   * Flush the bit buffer and align the output on a byte boundary
   */
  void _biWindup() {
    if (bi_valid > 8) {
      _putShort(bi_buf);
    } else if (bi_valid > 0) {
      _putByte(bi_buf);
    }
    bi_buf = 0;
    bi_valid = 0;
  }

  /**
   * Copy a stored block, storing first the length and its
   * one's complement if requested.
   */
  void _copyBlock(int buf, int len, bool header) {
    _biWindup(); // align on byte boundary
    last_eob_len = 8; // enough lookahead for inflate

    if (header) {
      _putShort(len);
      _putShort((~len + 0x10000) & 0xffff);
    }

    _putBytes(window, buf, len);
  }

  void _flushBlockOnly(bool eof) {
    _trFlushBlock(block_start >= 0 ? block_start : - 1,
                    strstart - block_start, eof);
    block_start = strstart;
    _flushPending();
  }

  /**
   * Copy without compression as much as possible from the input stream, return
   * the current block state.
   * This function does not insert new strings in the dictionary since
   * uncompressible data is probably not useful. This function is used
   * only for the level=0 compression option.
   * NOTE: this function should be optimized to avoid extra copying from
   * window to pending_buf.
   */
  int _deflateStored(int flush) {
    // Stored blocks are limited to 0xffff bytes, pending_buf is limited
    // to pending_buf_size, and each stored block has a 5 byte header:

    int max_block_size = 0xffff;
    int max_start;

    if (max_block_size > pending_buf_size - 5) {
      max_block_size = pending_buf_size - 5;
    }

    // Copy as much as possible from input to output:
    while (true) {
      // Fill the window as much as possible:
      if (lookahead <= 1) {
        _fillWindow();
        if (lookahead == 0 && flush == Z_NO_FLUSH) {
          return NeedMore;
        }
        if (lookahead == 0) {
          break; // flush the current block
        }
      }

      strstart += lookahead;
      lookahead = 0;

      // Emit a stored block if pending_buf will be full:
      max_start = block_start + max_block_size;
      if (strstart == 0 || strstart >= max_start) {
        // strstart == 0 is possible when wraparound on 16-bit machine
        lookahead = (strstart - max_start);
        strstart = max_start;

        _flushBlockOnly(false);
      }

      // Flush if we may have to slide, otherwise block_start may become
      // negative and the data will be gone:
      if (strstart - block_start >= w_size - MIN_LOOKAHEAD) {
        _flushBlockOnly(false);
      }
    }

    _flushBlockOnly(flush == Z_FINISH);

    return flush == Z_FINISH ? FinishDone : BlockDone;
  }

  /**
   * Send a stored block
   */
  void _trStoredBlock(int buf, int stored_len, bool eof) {
    _sendBits((STORED_BLOCK << 1) + (eof?1:0), 3); // send block type
    _copyBlock(buf, stored_len, true); // with header
  }

  /**
   * Determine the best encoding for the current block: dynamic trees, static
   * trees or store, and output the encoded block to the zip file.
   */
  void _trFlushBlock(int buf, int stored_len, bool eof) {
    int opt_lenb, static_lenb; // opt_len and static_len in bytes
    int max_blindex = 0; // index of last bit length code of non zero freq

    // Build the Huffman trees unless a stored block is forced
    if (level > 0) {
      // Check if the file is ascii or binary
      if (data_type == Z_UNKNOWN) {
        setDataType();
      }

      // Construct the literal and distance trees
      l_desc._buildTree(this);

      d_desc._buildTree(this);

      // At this point, opt_len and static_len are the total bit lengths of
      // the compressed block data, excluding the tree representations.

      // Build the bit length tree for the above two trees, and get the index
      // in bl_order of the last bit length code to send.
      max_blindex = _buildBitLengthTree();

      // Determine the best encoding. Compute first the block length in bytes
      opt_lenb = _URShift((opt_len + 3 + 7), 3);
      static_lenb = _URShift((static_len + 3 + 7), 3);

      if (static_lenb <= opt_lenb) {
        opt_lenb = static_lenb;
      }
    } else {
      opt_lenb = static_lenb = stored_len + 5; // force a stored block
    }

    if (stored_len + 4 <= opt_lenb && buf != - 1) {
      // 4: two words for the lengths
      // The test buf != NULL is only necessary if LIT_BUFSIZE > WSIZE.
      // Otherwise we can't have processed more than WSIZE input bytes since
      // the last block flush, because compression would have been
      // successful. If LIT_BUFSIZE <= WSIZE, it is never too late to
      // transform a block into a stored block.
      _trStoredBlock(buf, stored_len, eof);
    } else if (static_lenb == opt_lenb) {
      _sendBits((STATIC_TREES << 1) + (eof ? 1 : 0), 3);
      _compressBlock(_StaticTree.static_ltree, _StaticTree.static_dtree);
    } else {
      _sendBits((DYN_TREES << 1) + (eof ? 1 : 0), 3);
      _sendAllTrees(l_desc.max_code + 1, d_desc.max_code + 1, max_blindex + 1);
      _compressBlock(dyn_ltree, dyn_dtree);
    }

    // The above check is made mod 2^32, for files larger than 512 MB
    // and uLong implemented on 32 bits.

    _init_block();

    if (eof) {
      _biWindup();
    }
  }

  /**
   * Fill the window when the lookahead becomes insufficient.
   * Updates strstart and lookahead.
   * IN assertion: lookahead < MIN_LOOKAHEAD
   * OUT assertions: strstart <= window_size-MIN_LOOKAHEAD
   *    At least one byte has been read, or avail_in == 0; reads are
   *    performed for at least two bytes (required for the zip translate_eol
   *    option -- not supported here).
   */
  void _fillWindow() {
    int n, m;
    int p;
    int more; // Amount of free space at the end of the window.

    do {
      more = (window_size - lookahead - strstart);

      // Deal with !@#$% 64K limit:
      if (more == 0 && strstart == 0 && lookahead == 0) {
        more = w_size;
      } else if (more == - 1) {
        // Very unlikely, but possible on 16 bit machine if strstart == 0
        // and lookahead == 1 (input done one byte at time)
        more--;

        // If the window is almost full and there is insufficient lookahead,
        // move the upper half to the lower one to make room in the upper half.
      } else if (strstart >= w_size + w_size - MIN_LOOKAHEAD) {
        window.setRange(0, w_size, window, w_size);
        //Array.Copy(window, w_size, window, 0, w_size);
        match_start -= w_size;
        strstart -= w_size; // we now have strstart >= MAX_DIST
        block_start -= w_size;

        // Slide the hash table (could be avoided with 32 bit values
        // at the expense of memory usage). We slide even when level == 0
        // to keep the hash table consistent if we switch back to level > 0
        // later. (Using level 0 permanently is not an optimal usage of
        // zlib, so we don't care about this pathological case.)

        n = hash_size;
        p = n;
        do {
          m = (head[--p] & 0xffff);
          head[p] = (m >= w_size?(m - w_size) : 0);
        } while (--n != 0);

        n = w_size;
        p = n;
        do {
          m = (prev[--p] & 0xffff);
          prev[p] = (m >= w_size ? (m - w_size) : 0);
          // If n is not on any hash chain, prev[n] is garbage but
          // its value will never be used.
        } while (--n != 0);
        more += w_size;
      }

      if (input.isEOF) {
        return;
      }

      // If there was no sliding:
      //    strstart <= WSIZE+MAX_DIST-1 && lookahead <= MIN_LOOKAHEAD - 1 &&
      //    more == window_size - lookahead - strstart
      // => more >= window_size - (MIN_LOOKAHEAD-1 + WSIZE + MAX_DIST-1)
      // => more >= window_size - 2*WSIZE + 2
      // In the BIG_MEM or MMAP case (not yet supported),
      //   window_size == input_size + MIN_LOOKAHEAD  &&
      //   strstart + s->lookahead <= input_size => more >= MIN_LOOKAHEAD.
      // Otherwise, window_size == 2*WSIZE so more >= 2.
      // If there was sliding, more >= WSIZE. So in all cases, more >= 2.

      n = _readBuf(window, strstart + lookahead, more);
      lookahead += n;

      // Initialize the hash value now that we have some input:
      if (lookahead >= MIN_MATCH) {
        ins_h = window[strstart] & 0xff;
        ins_h = (((ins_h) << hash_shift) ^
                 (window[strstart + 1] & 0xff)) & hash_mask;
      }

      // If the whole input has less than MIN_MATCH bytes, ins_h is garbage,
      // but this is not important since only literal bytes will be emitted.
    } while (lookahead < MIN_LOOKAHEAD && !input.isEOF);
  }

  /**
   * Compress as much as possible from the input stream, return the current
   * block state.
   * This function does not perform lazy evaluation of matches and inserts
   * new strings in the dictionary only for unmatched strings or for short
   * matches. It is used only for the fast compression options.
   */
  int _deflateFast(int flush) {
    int hash_head = 0; // head of the hash chain
    bool bflush; // set if current block must be flushed

    while (true) {
      // Make sure that we always have enough lookahead, except
      // at the end of the input file. We need MAX_MATCH bytes
      // for the next match, plus MIN_MATCH bytes to insert the
      // string following the next match.
      if (lookahead < MIN_LOOKAHEAD) {
        _fillWindow();
        if (lookahead < MIN_LOOKAHEAD && flush == Z_NO_FLUSH) {
          return NeedMore;
        }
        if (lookahead == 0) {
          break; // flush the current block
        }
      }

      // Insert the string window[strstart .. strstart+2] in the
      // dictionary, and set hash_head to the head of the hash chain:
      if (lookahead >= MIN_MATCH) {
        ins_h = (((ins_h) << hash_shift) ^
                 (window[(strstart) + (MIN_MATCH - 1)] & 0xff)) & hash_mask;

        hash_head = (head[ins_h] & 0xffff);
        prev[strstart & w_mask] = head[ins_h];
        head[ins_h] = strstart;
      }

      // Find the longest match, discarding those <= prev_length.
      // At this point we have always match_length < MIN_MATCH

      if (hash_head != 0 &&
          ((strstart - hash_head) & 0xffff) <= w_size - MIN_LOOKAHEAD) {
        // To simplify the code, we prevent matches with the string
        // of window index 0 (in particular we have to avoid a match
        // of the string with itself at the start of the input file).
        if (strategy != Z_HUFFMAN_ONLY) {
          match_length = _longestMatch(hash_head);
        }

        // longest_match() sets match_start
      }

      if (match_length >= MIN_MATCH) {
        bflush = _trTally(strstart - match_start, match_length - MIN_MATCH);

        lookahead -= match_length;

        // Insert new strings in the hash table only if the match length
        // is not too large. This saves time but degrades compression.
        if (match_length <= max_lazy_match && lookahead >= MIN_MATCH) {
          match_length--; // string at strstart already in hash table
          do {
            strstart++;

            ins_h = ((ins_h << hash_shift) ^
                     (window[(strstart) + (MIN_MATCH - 1)] & 0xff)) & hash_mask;

            hash_head = (head[ins_h] & 0xffff);
            prev[strstart & w_mask] = head[ins_h];
            head[ins_h] = strstart;

            // strstart never exceeds WSIZE-MAX_MATCH, so there are
            // always MIN_MATCH bytes ahead.
          } while (--match_length != 0);
          strstart++;
        } else {
          strstart += match_length;
          match_length = 0;
          ins_h = window[strstart] & 0xff;

          ins_h = (((ins_h) << hash_shift) ^ (window[strstart + 1] & 0xff)) & hash_mask;
          // If lookahead < MIN_MATCH, ins_h is garbage, but it does not
          // matter since it will be recomputed at next deflate call.
        }
      } else {
        // No match, output a literal byte

        bflush = _trTally(0, window[strstart] & 0xff);
        lookahead--;
        strstart++;
      }

      if (bflush) {
        _flushBlockOnly(false);
      }
    }

    _flushBlockOnly(flush == Z_FINISH);

    return flush == Z_FINISH ? FinishDone : BlockDone;
  }

  /**
   * Same as above, but achieves better compression. We use a lazy
   * evaluation for matches: a match is finally adopted only if there is
   * no better match at the next window position.
   */
  int _deflateSlow(int flush) {
    int hash_head = 0; // head of hash chain
    bool bflush; // set if current block must be flushed

    // Process the input block.
    while (true) {
      // Make sure that we always have enough lookahead, except
      // at the end of the input file. We need MAX_MATCH bytes
      // for the next match, plus MIN_MATCH bytes to insert the
      // string following the next match.
      if (lookahead < MIN_LOOKAHEAD) {
        _fillWindow();
        if (lookahead < MIN_LOOKAHEAD && flush == Z_NO_FLUSH) {
          return NeedMore;
        }
        if (lookahead == 0) {
          break; // flush the current block
        }
      }

      // Insert the string window[strstart .. strstart+2] in the
      // dictionary, and set hash_head to the head of the hash chain:

      if (lookahead >= MIN_MATCH) {
        ins_h = (((ins_h) << hash_shift) ^
                 (window[(strstart) + (MIN_MATCH - 1)] & 0xff)) & hash_mask;
        //  prev[strstart&w_mask]=hash_head=head[ins_h];
        hash_head = (head[ins_h] & 0xffff);
        prev[strstart & w_mask] = head[ins_h];
        head[ins_h] = strstart;
      }

      // Find the longest match, discarding those <= prev_length.
      prev_length = match_length;
      prev_match = match_start;
      match_length = MIN_MATCH - 1;

      if (hash_head != 0 && prev_length < max_lazy_match &&
          ((strstart - hash_head) & 0xffff) <= w_size - MIN_LOOKAHEAD) {
        // To simplify the code, we prevent matches with the string
        // of window index 0 (in particular we have to avoid a match
        // of the string with itself at the start of the input file).

        if (strategy != Z_HUFFMAN_ONLY) {
          match_length = _longestMatch(hash_head);
        }
        // longest_match() sets match_start

        if (match_length <= 5 &&
            (strategy == Z_FILTERED ||
             (match_length == MIN_MATCH && strstart - match_start > 4096))) {
          // If prev_match is also MIN_MATCH, match_start is garbage
          // but we will ignore the current match anyway.
          match_length = MIN_MATCH - 1;
        }
      }

      // If there was a match at the previous step and the current
      // match is not better, output the previous match:
      if (prev_length >= MIN_MATCH && match_length <= prev_length) {
        int max_insert = strstart + lookahead - MIN_MATCH;
        // Do not insert strings in hash table beyond this.

        bflush = _trTally(strstart - 1 - prev_match, prev_length - MIN_MATCH);

        // Insert in hash table all strings up to the end of the match.
        // strstart-1 and strstart are already inserted. If there is not
        // enough lookahead, the last two strings are not inserted in
        // the hash table.
        lookahead -= (prev_length - 1);
        prev_length -= 2;

        do {
          if (++strstart <= max_insert) {
            ins_h = (((ins_h) << hash_shift) ^
                     (window[(strstart) + (MIN_MATCH - 1)] & 0xff)) & hash_mask;
            //prev[strstart&w_mask]=hash_head=head[ins_h];
            hash_head = (head[ins_h] & 0xffff);
            prev[strstart & w_mask] = head[ins_h];
            head[ins_h] = strstart;
          }
        } while (--prev_length != 0);

        match_available = 0;
        match_length = MIN_MATCH - 1;
        strstart++;

        if (bflush) {
          _flushBlockOnly(false);
        }
      } else if (match_available != 0) {

        // If there was no match at the previous position, output a
        // single literal. If there was a match but the current match
        // is longer, truncate the previous match to a single literal.

        bflush = _trTally(0, window[strstart - 1] & 0xff);

        if (bflush) {
          _flushBlockOnly(false);
        }
        strstart++;
        lookahead--;
      } else {
        // There is no previous match to compare with, wait for
        // the next step to decide.
        match_available = 1;
        strstart++;
        lookahead--;
      }
    }

    if (match_available != 0) {
      bflush = _trTally(0, window[strstart - 1] & 0xff);
      match_available = 0;
    }
    _flushBlockOnly(flush == Z_FINISH);

    return flush == Z_FINISH ? FinishDone : BlockDone;
  }

  int _longestMatch(int cur_match) {
    int chain_length = max_chain_length; // max hash chain length
    int scan = strstart; // current string
    int match; // matched string
    int len; // length of current match
    int best_len = prev_length; // best match length so far
    int limit = strstart > (w_size - MIN_LOOKAHEAD) ?
                strstart - (w_size - MIN_LOOKAHEAD) : 0;
    int nice_match = this.nice_match;

    // Stop when cur_match becomes <= limit. To simplify the code,
    // we prevent matches with the string of window index 0.

    int wmask = w_mask;

    int strend = strstart + MAX_MATCH;
    int scan_end1 = window[scan + best_len - 1];
    int scan_end = window[scan + best_len];

    // The code is optimized for HASH_BITS >= 8 and MAX_MATCH-2 multiple of 16.
    // It is easy to get rid of this optimization if necessary.

    // Do not waste too much time if we already have a good match:
    if (prev_length >= good_match) {
      chain_length >>= 2;
    }

    // Do not look for matches beyond the end of the input. This is necessary
    // to make deflate deterministic.
    if (nice_match > lookahead) {
      nice_match = lookahead;
    }

    do {
      match = cur_match;

      // Skip to next match if the match length cannot increase
      // or if the match length is less than 2:
      if (window[match + best_len] != scan_end ||
          window[match + best_len - 1] != scan_end1 ||
          window[match] != window[scan] ||
          window[++match] != window[scan + 1]) {
        continue;
      }

      // The check at best_len-1 can be removed because it will be made
      // again later. (This heuristic is not always a win.)
      // It is not necessary to compare scan[2] and match[2] since they
      // are always equal when the other bytes match, given that
      // the hash keys are equal and that HASH_BITS >= 8.
      scan += 2;
      match++;

      // We check for insufficient lookahead only every 8th comparison;
      // the 256th check will be made at strstart+258.
      do {
      } while (window[++scan] == window[++match] &&
               window[++scan] == window[++match] &&
               window[++scan] == window[++match] &&
               window[++scan] == window[++match] &&
               window[++scan] == window[++match] &&
               window[++scan] == window[++match] &&
               window[++scan] == window[++match] &&
               window[++scan] == window[++match] &&
               scan < strend);

      len = MAX_MATCH - (strend - scan);
      scan = strend - MAX_MATCH;

      if (len > best_len) {
        match_start = cur_match;
        best_len = len;
        if (len >= nice_match) {
          break;
        }
        scan_end1 = window[scan + best_len - 1];
        scan_end = window[scan + best_len];
      }
    } while ((cur_match = (prev[cur_match & wmask] & 0xffff)) > limit &&
              --chain_length != 0);

    if (best_len <= lookahead) {
      return best_len;
    }

    return lookahead;
  }


  int _deflateInit(int level,
                  {int method: Z_DEFLATED,
                   int windowBits: MAX_WBITS,
                   int memLevel: DEF_MEM_LEVEL,
                   int strategy: Z_DEFAULT_STRATEGY}) {
    if (level == null || level == Z_DEFAULT_COMPRESSION) {
      level = 6;
    }

    config = _getConfig(level);

    if (memLevel < 1 || memLevel > MAX_MEM_LEVEL || method != Z_DEFLATED ||
        windowBits < 9 || windowBits > 15 || level < 0 || level > 9 ||
        strategy < 0 || strategy > Z_HUFFMAN_ONLY) {
      throw new ArchiveException('Invalid Deflate parameter');
    }

    dyn_ltree = new Data.Uint16List(HEAP_SIZE * 2);
    dyn_dtree = new Data.Uint16List((2 * D_CODES + 1) * 2);
    bl_tree = new Data.Uint16List((2 * BL_CODES + 1) * 2);

    w_bits = windowBits;
    w_size = 1 << w_bits;
    w_mask = w_size - 1;

    hash_bits = memLevel + 7;
    hash_size = 1 << hash_bits;
    hash_mask = hash_size - 1;
    hash_shift = ((hash_bits + MIN_MATCH - 1) ~/ MIN_MATCH);

    window = new Data.Uint8List(w_size * 2);
    prev = new Data.Uint16List(w_size);
    head = new Data.Uint16List(hash_size);

    lit_bufsize = 1 << (memLevel + 6); // 16K elements by default

    // We overlay pending_buf and d_buf+l_buf. This works since the average
    // output size for (length,distance) codes is <= 24 bits.
    pending_buf = new Data.Uint8List(lit_bufsize * 4);
    pending_buf_size = lit_bufsize * 4;

    d_buf = lit_bufsize;
    l_buf = (1 + 2) * lit_bufsize;

    this.level = level;

    this.strategy = strategy;
    this.method = method;

    _deflateParams(level, strategy);

    return _deflateReset();
  }

  int _deflateReset() {
    pending = 0;
    pending_out = 0;

    status = BUSY_STATE;

    last_flush = Z_NO_FLUSH;

    _tr_init();
    _lm_init();

    return Z_OK;
  }

  int _deflateEnd() {
    if (status != INIT_STATE && status != BUSY_STATE &&
        status != FINISH_STATE) {
      return Z_STREAM_ERROR;
    }

    // Deallocate in reverse order of allocations:
    pending_buf = null;
    head = null;
    prev = null;
    window = null;

    return status == BUSY_STATE ? Z_DATA_ERROR : Z_OK;
  }

  int _deflateParams(int _level, int _strategy) {
    int err = Z_OK;

    if (_level == null || _level == Z_DEFAULT_COMPRESSION) {
      _level = 6;
    }

    if (_level < 0 || _level > 9 || _strategy < 0 ||
        _strategy > Z_HUFFMAN_ONLY) {
      return Z_STREAM_ERROR;
    }

    config = _getConfig(_level);

    if (config.func != config.func) {
      // Flush the last buffer:
      err = _deflate(Z_PARTIAL_FLUSH);
    }

    if (level != _level) {
      level = _level;
      max_lazy_match = config.max_lazy;
      good_match = config.good_length;
      nice_match = config.nice_length;
      max_chain_length = config.max_chain;
    }

    strategy = _strategy;
    return err;
  }

  int _deflateSetDictionary(Data.Uint8List dictionary, int dictLength) {
    int length = dictLength;
    int index = 0;

    if (dictionary == null || status != INIT_STATE)
      return Z_STREAM_ERROR;

    if (length < MIN_MATCH) {
      return Z_OK;
    }
    if (length > w_size - MIN_LOOKAHEAD) {
      length = w_size - MIN_LOOKAHEAD;
      index = dictLength - length; // use the tail of the dictionary
    }

    window.setRange(0, length, dictionary, index);

    strstart = length;
    block_start = length;

    // Insert all strings in the hash table (except for the last two bytes).
    // s->lookahead stays null, so s->ins_h will be recomputed at the next
    // call of fill_window.

    ins_h = window[0] & 0xff;
    ins_h = (((ins_h) << hash_shift) ^ (window[1] & 0xff)) & hash_mask;

    for (int n = 0; n <= length - MIN_MATCH; n++) {
      ins_h = (((ins_h) << hash_shift) ^
               (window[(n) + (MIN_MATCH - 1)] & 0xff)) & hash_mask;
      prev[n & w_mask] = head[ins_h];
      head[ins_h] = n;
    }

    return Z_OK;
  }

  int _deflate([int flush = Z_FULL_FLUSH]) {
    int old_flush;

    if (flush > Z_FINISH || flush < 0) {
      return Z_STREAM_ERROR;
    }

    old_flush = last_flush;
    last_flush = flush;

    // Flush as much pending output as possible
    if (pending != 0) {
      _flushPending();

      // Make sure there is something to do and avoid duplicate consecutive
      // flushes. For repeated and useless calls with Z_FINISH, we keep
      // returning Z_STREAM_END instead of Z_BUFF_ERROR.
    }

    // Start a new block or continue the current one.
    if (!input.isEOF || lookahead != 0 ||
        (flush != Z_NO_FLUSH && status != FINISH_STATE)) {
      int bstate = - 1;
      switch (config.func) {
        case STORED:
          bstate = _deflateStored(flush);
          break;
        case FAST:
          bstate = _deflateFast(flush);
          break;
        case SLOW:
          bstate = _deflateSlow(flush);
          break;
        default:
          break;
      }

      if (bstate == FinishStarted || bstate == FinishDone) {
        status = FINISH_STATE;
      }

      if (bstate == NeedMore || bstate == FinishStarted) {
        return Z_OK;
        // If flush != Z_NO_FLUSH && avail_out == 0, the next call
        // of deflate should use the same flush parameter to make sure
        // that the flush is complete. So we don't have to output an
        // empty block here, this will be done at next call. This also
        // ensures that for a very small output buffer, we emit at most
        // one empty block.
      }

      if (bstate == BlockDone) {
        if (flush == Z_PARTIAL_FLUSH) {
          _trAlign();
        } else {
          // FULL_FLUSH or SYNC_FLUSH
          _trStoredBlock(0, 0, false);
          // For a full flush, this empty block will be recognized
          // as a special marker by inflate_sync().
          if (flush == Z_FULL_FLUSH) {
            for (int i = 0; i < hash_size; i++) {
              // forget history
              head[i] = 0;
            }
          }
        }

        _flushPending();
      }
    }

    if (flush != Z_FINISH) {
      return Z_OK;
    }

    return Z_STREAM_END;
  }

  /**
   * Read a new buffer from the current input stream, update the adler32
   * and total number of bytes read.  All deflate() input goes through
   * this function so some applications may wish to modify it to avoid
   * allocating a large strm->next_in buffer and copying from it.
   * (See also flush_pending()).
   */
  int _readBuf(Data.Uint8List buf, int start, int size) {
    int len = input.length - input.position;

    if (len > size) {
      len = size;
    }

    if (len == 0) {
      return 0;
    }


    buf.setRange(start, len, input.readBytes(len));

    return len;
  }

  /**
   * Flush as much pending output as possible. All deflate() output goes
   * through this function so some applications may wish to modify it
   * to avoid allocating a large strm->next_out buffer and copying into it.
   */
  void _flushPending() {
    int len = pending;

    output.writeBytes(pending_buf, len);

    pending_out += len;
    pending -= len;
    if (pending == 0) {
      pending_out = 0;
    }
  }

  static _DeflaterConfig _getConfig(int level) {
    switch (level) {
      //                             good  lazy  nice  chain
      case 0: return new _DeflaterConfig(0, 0, 0, 0, STORED);
      case 1: return new _DeflaterConfig(4, 4, 8, 4, FAST);
      case 2: return new _DeflaterConfig(4, 5, 16, 8, FAST);
      case 3: return new _DeflaterConfig(4, 6, 32, 32, FAST);

      case 4: return new _DeflaterConfig(4, 4, 16, 16, SLOW);
      case 5: return new _DeflaterConfig(8, 16, 32, 32, SLOW);
      case 6: return new _DeflaterConfig(8, 16, 128, 128, SLOW);
      case 7: return new _DeflaterConfig(8, 32, 128, 256, SLOW);
      case 8: return new _DeflaterConfig(32, 128, 258, 1024, SLOW);
      case 9: return new _DeflaterConfig(32, 258, 258, 4096, SLOW);
    }
    return null;
  }

  static const int MAX_MEM_LEVEL = 9;

  static const int Z_DEFAULT_COMPRESSION = - 1;

  static const int MAX_WBITS = 15; // 32K LZ77 window
  static const int DEF_MEM_LEVEL = 8;

  static const int STORED = 0;
  static const int FAST = 1;
  static const int SLOW = 2;
  static _DeflaterConfig config;

  // block not completed, need more input or more output
  static const int NeedMore = 0;

  // block flush performed
  static const int BlockDone = 1;

  // finish started, need only more output at next deflate
  static const int FinishStarted = 2;

  // finish done, accept no more input or output
  static const int FinishDone = 3;

  // preset dictionary flag in zlib header
  static const int PRESET_DICT = 0x20;

  static const int Z_FILTERED = 1;
  static const int Z_HUFFMAN_ONLY = 2;
  static const int Z_DEFAULT_STRATEGY = 0;

  static const int Z_NO_FLUSH = 0;
  static const int Z_PARTIAL_FLUSH = 1;
  static const int Z_SYNC_FLUSH = 2;
  static const int Z_FULL_FLUSH = 3;
  static const int Z_FINISH = 4;

  static const int Z_OK = 0;
  static const int Z_STREAM_END = 1;
  static const int Z_NEED_DICT = 2;
  static const int Z_ERRNO = - 1;
  static const int Z_STREAM_ERROR = - 2;
  static const int Z_DATA_ERROR = - 3;
  static const int Z_MEM_ERROR = - 4;
  static const int Z_BUF_ERROR = - 5;
  static const int Z_VERSION_ERROR = - 6;

  static const int INIT_STATE = 42;
  static const int BUSY_STATE = 113;
  static const int FINISH_STATE = 666;

  // The deflate compression method
  static const int Z_DEFLATED = 8;

  static const int STORED_BLOCK = 0;
  static const int STATIC_TREES = 1;
  static const int DYN_TREES = 2;

  // The three kinds of block type
  static const int Z_BINARY = 0;
  static const int Z_ASCII = 1;
  static const int Z_UNKNOWN = 2;

  static const int Buf_size = 8 * 2;

  // repeat previous bit length 3-6 times (2 bits of repeat count)
  static const int REP_3_6 = 16;

  // repeat a zero length 3-10 times  (3 bits of repeat count)
  static const int REPZ_3_10 = 17;

  // repeat a zero length 11-138 times  (7 bits of repeat count)
  static const int REPZ_11_138 = 18;

  static const int MIN_MATCH = 3;
  static const int MAX_MATCH = 258;
  static const int MIN_LOOKAHEAD = (MAX_MATCH + MIN_MATCH + 1);

  static const int MAX_BITS = 15;
  static const int D_CODES = 30;
  static const int BL_CODES = 19;
  static const int LENGTH_CODES = 29;
  static const int LITERALS = 256;
  static const int L_CODES = (LITERALS + 1 + LENGTH_CODES);
  static const int HEAP_SIZE = (2 * L_CODES + 1);

  static const int END_BLOCK = 256;

  InputBuffer input;
  OutputBuffer output = new OutputBuffer();
  int status; // as the name implies
  Data.Uint8List pending_buf; // output still pending
  int pending_buf_size; // size of pending_buf
  int pending_out; // next pending byte to output to the stream
  int pending; // nb of bytes in the pending buffer
  int data_type; // UNKNOWN, BINARY or ASCII
  int method; // STORED (for zip only) or DEFLATED
  int last_flush; // value of flush param for previous deflate call

  int w_size; // LZ77 window size (32K by default)
  int w_bits; // log2(w_size)  (8..16)
  int w_mask; // w_size - 1

  Data.Uint8List window;
  // Sliding window. Input bytes are read into the second half of the window,
  // and move to the first half later to keep a dictionary of at least wSize
  // bytes. With this organization, matches are limited to a distance of
  // wSize-MAX_MATCH bytes, but this ensures that IO is always
  // performed with a length multiple of the block size. Also, it limits
  // the window size to 64K, which is quite useful on MSDOS.
  // To do: use the user input buffer as sliding window.

  int window_size;
  // Actual size of window: 2*wSize, except when the user input buffer
  // is directly used as sliding window.

  Data.Uint16List prev;
  // Link to older string with same hash index. To limit the size of this
  // array to 64K, this link is maintained only for the last 32K strings.
  // An index in this array is thus a window index modulo 32K.

  Data.Uint16List head; // Heads of the hash chains or NIL.

  int ins_h; // hash index of string to be inserted
  int hash_size; // number of elements in hash table
  int hash_bits; // log2(hash_size)
  int hash_mask; // hash_size-1

  // Number of bits by which ins_h must be shifted at each input
  // step. It must be such that after MIN_MATCH steps, the oldest
  // byte no longer takes part in the hash key, that is:
  // hash_shift * MIN_MATCH >= hash_bits
  int hash_shift;

  // Window position at the beginning of the current output block. Gets
  // negative when the window is moved backwards.

  int block_start;

  int match_length; // length of best match
  int prev_match; // previous match
  int match_available; // set if previous match exists
  int strstart; // start of string to insert
  int match_start; // start of matching string
  int lookahead; // number of valid bytes ahead in window

  // Length of the best match at previous step. Matches not greater than this
  // are discarded. This is used in the lazy match evaluation.
  int prev_length;

  // To speed up deflation, hash chains are never searched beyond this
  // length.  A higher limit improves compression ratio but degrades the speed.
  int max_chain_length;

  // Attempt to find a better match only when the current match is strictly
  // smaller than this value. This mechanism is used only for compression
  // levels >= 4.
  int max_lazy_match;

  // Insert new strings in the hash table only if the match length is not
  // greater than this length. This saves time but degrades compression.
  // max_insert_length is used only for compression levels <= 3.

  int level; // compression level (1..9)
  int strategy; // favor or force Huffman coding

  // Use a faster search when the previous match is longer than this
  int good_match;

  // Stop searching when current match exceeds this
  int nice_match;

  Data.Uint16List dyn_ltree; // literal and length tree
  Data.Uint16List dyn_dtree; // distance tree
  Data.Uint16List bl_tree; // Huffman tree for bit lengths

  _Tree l_desc = new _Tree(); // desc for literal tree
  _Tree d_desc = new _Tree(); // desc for distance tree
  _Tree bl_desc = new _Tree(); // desc for bit length tree

  // number of codes at each bit length for an optimal tree
  Data.Uint16List bl_count = new Data.Uint16List(MAX_BITS + 1);

  // heap used to build the Huffman trees
  Data.Uint32List heap = new Data.Uint32List(2 * L_CODES + 1);

  int heap_len; // number of elements in the heap
  int heap_max; // element of largest frequency
  // The sons of heap[n] are heap[2*n] and heap[2*n+1]. heap[0] is not used.
  // The same heap array is used to build all trees.

  // Depth of each subtree used as tie breaker for trees of equal frequency
  Data.Uint8List depth = new Data.Uint8List(2 * L_CODES + 1);

  int l_buf; // index for literals or lengths

  // Size of match buffer for literals/lengths.  There are 4 reasons for
  // limiting lit_bufsize to 64K:
  //   - frequencies can be kept in 16 bit counters
  //   - if compression is not successful for the first block, all input
  //     data is still in the window so we can still emit a stored block even
  //     when input comes from standard input.  (This can also be done for
  //     all blocks if lit_bufsize is not greater than 32K.)
  //   - if compression is not successful for a file smaller than 64K, we can
  //     even emit a stored file instead of a stored block (saving 5 bytes).
  //     This is applicable only for zip (not gzip or zlib).
  //   - creating new Huffman trees less frequently may not provide fast
  //     adaptation to changes in the input data statistics. (Take for
  //     example a binary file with poorly compressible code followed by
  //     a highly compressible string table.) Smaller buffer sizes give
  //     fast adaptation but have of course the overhead of transmitting
  //     trees more frequently.
  //   - I can't count above 4
  int lit_bufsize;

  int last_lit; // running index in l_buf

  // Buffer for distances. To simplify the code, d_buf and l_buf have
  // the same number of elements. To use different lengths, an extra flag
  // array would be necessary.

  int d_buf; // index of pendig_buf

  int opt_len; // bit length of current block with optimal trees
  int static_len; // bit length of current block with static trees
  int matches; // number of string matches in current block
  int last_eob_len; // bit length of EOB code for last block

  // Output buffer. bits are inserted starting at the bottom (least
  // significant bits).
  int bi_buf;

  // Number of valid bits in bi_buf.  All bits above the last valid bit
  // are always zero.
  int bi_valid;
}

class _DeflaterConfig {
  int good_length; // reduce lazy search above this match length
  int max_lazy; // do not perform lazy search above this match length
  int nice_length; // quit search above this match length
  int max_chain;
  int func;
  _DeflaterConfig(int good_length, int max_lazy, int nice_length,
                  int max_chain, int func) {
    this.good_length = good_length;
    this.max_lazy = max_lazy;
    this.nice_length = nice_length;
    this.max_chain = max_chain;
    this.func = func;
  }
}

class _Tree {
  static const int MAX_BITS = 15;
  static const int BL_CODES = 19;
  static const int D_CODES = 30;
  static const int LITERALS = 256;
  static const int LENGTH_CODES = 29;
  static const int L_CODES = (LITERALS + 1 + LENGTH_CODES);
  static const int HEAP_SIZE = (2 * L_CODES + 1);

  // Bit length codes must not exceed MAX_BL_BITS bits
  static const int MAX_BL_BITS = 7;

  // end of block literal code
  static const int END_BLOCK = 256;

  // repeat previous bit length 3-6 times (2 bits of repeat count)
  static const int REP_3_6 = 16;

  // repeat a zero length 3-10 times  (3 bits of repeat count)
  static const int REPZ_3_10 = 17;

  // repeat a zero length 11-138 times  (7 bits of repeat count)
  static const int REPZ_11_138 = 18;

  // extra bits for each length code
  static const List<int> extra_lbits = const [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];

  // extra bits for each distance code
  static const List<int> extra_dbits = const [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];

  // extra bits for each bit length code
  static const List<int> extra_blbits = const [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 3, 7];

  static const List<int> bl_order = const [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];


  // The lengths of the bit length codes are sent in order of decreasing
  // probability, to avoid transmitting the lengths for unused bit
  // length codes.

  static const int Buf_size = 8 * 2;

  // see definition of array dist_code below
  static const int DIST_CODE_LEN = 512;

  static const List<int> _dist_code = const [0, 1, 2, 3, 4, 4, 5, 5, 6, 6, 6, 6, 7, 7, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8, 9, 9, 9, 9, 9, 9, 9, 9, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 0, 0, 16, 17, 18, 18, 19, 19, 20, 20, 20, 20, 21, 21, 21, 21, 22, 22, 22, 22, 22, 22, 22, 22, 23, 23, 23, 23, 23, 23, 23, 23, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29,
    29, 29, 29, 29, 29, 29, 29, 29, 29];

  static const List<int> _length_code = const [0, 1, 2, 3, 4, 5, 6, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 12, 12, 13, 13, 13, 13, 14, 14, 14, 14, 15, 15, 15, 15, 16, 16, 16, 16, 16, 16, 16, 16, 17, 17, 17, 17, 17, 17, 17, 17, 18, 18, 18, 18, 18, 18, 18, 18, 19, 19, 19, 19, 19, 19, 19, 19, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 22, 22, 22, 22, 22, 22, 22, 22, 22, 22, 22, 22, 22, 22, 22, 22, 23, 23, 23, 23, 23, 23, 23, 23, 23, 23, 23, 23, 23, 23, 23, 23, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 28];

  static const List<int> base_length = const [0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 20, 24, 28, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 0];

  static const List<int> base_dist = const [0, 1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024, 1536, 2048, 3072, 4096, 6144, 8192, 12288, 16384, 24576];

  /**
   * Mapping from a distance to a distance code. dist is the distance - 1 and
   * must not have side effects. _dist_code[256] and _dist_code[257] are never
   * used.
   */
  static int _dCode(int dist) {
    return ((dist) < 256?_dist_code[dist]:_dist_code[256 + (_URShift((dist), 7))]);
  }

  Data.Uint16List dyn_tree; // the dynamic tree
  int max_code; // largest code with non zero frequency
  _StaticTree stat_desc; // the corresponding static tree

  /**
   * Compute the optimal bit lengths for a tree and update the total bit length
   * for the current block.
   * IN assertion: the fields freq and dad are set, heap[heap_max] and
   *    above are the tree nodes sorted by increasing frequency.
   * OUT assertions: the field len is set to the optimal bit length, the
   *     array bl_count contains the frequencies for each bit length.
   *     The length opt_len is updated; static_len is also updated if stree is
   *     not null.
   */
  void _genBitlen(Deflater s) {
    Data.Uint16List tree = dyn_tree;
    List<int> stree = stat_desc.static_tree;
    List<int> extra = stat_desc.extra_bits;
    int base_Renamed = stat_desc.extra_base;
    int max_length = stat_desc.max_length;
    int h; // heap index
    int n, m; // iterate over the tree elements
    int bits; // bit length
    int xbits; // extra bits
    int f; // frequency
    int overflow = 0; // number of elements with bit length too large

    for (bits = 0; bits <= MAX_BITS; bits++) {
      s.bl_count[bits] = 0;
    }

    // In a first pass, compute the optimal bit lengths (which may
    // overflow in the case of the bit length tree).
    tree[s.heap[s.heap_max] * 2 + 1] = 0; // root of the heap

    for (h = s.heap_max + 1; h < HEAP_SIZE; h++) {
      n = s.heap[h];
      bits = tree[tree[n * 2 + 1] * 2 + 1] + 1;
      if (bits > max_length) {
        bits = max_length;
        overflow++;
      }
      tree[n * 2 + 1] = bits;
      // We overwrite tree[n*2+1] which is no longer needed

      if (n > max_code) {
        continue; // not a leaf node
      }

      s.bl_count[bits]++;
      xbits = 0;
      if (n >= base_Renamed) {
        xbits = extra[n - base_Renamed];
      }
      f = tree[n * 2];
      s.opt_len += f * (bits + xbits);
      if (stree != null) {
        s.static_len += f * (stree[n * 2 + 1] + xbits);
      }
    }
    if (overflow == 0) {
      return ;
    }

    // This happens for example on obj2 and pic of the Calgary corpus
    // Find the first bit length which could increase:
    do {
      bits = max_length - 1;
      while (s.bl_count[bits] == 0) {
        bits--;
      }
      s.bl_count[bits]--; // move one leaf down the tree
      // move one overflow item as its brother
      s.bl_count[bits + 1] = (s.bl_count[bits + 1] + 2);
      s.bl_count[max_length]--;
      // The brother of the overflow item also moves one step up,
      // but this does not affect bl_count[max_length]
      overflow -= 2;
    } while (overflow > 0);

    for (bits = max_length; bits != 0; bits--) {
      n = s.bl_count[bits];
      while (n != 0) {
        m = s.heap[--h];
        if (m > max_code) {
          continue;
        }
        if (tree[m * 2 + 1] != bits) {
          s.opt_len = (s.opt_len + (bits - tree[m * 2 + 1]) * tree[m * 2]);
          tree[m * 2 + 1] = bits;
        }
        n--;
      }
    }
  }

  /**
   * Construct one Huffman tree and assigns the code bit strings and lengths.
   * Update the total bit length for the current block.
   * IN assertion: the field freq is set for all tree elements.
   * OUT assertions: the fields len and code are set to the optimal bit length
   *     and corresponding code. The length opt_len is updated; static_len is
   *     also updated if stree is not null. The field max_code is set.
   */
  void _buildTree(Deflater s) {
    Data.Uint16List tree = dyn_tree;
    List<int> stree = stat_desc.static_tree;
    int elems = stat_desc.elems;
    int n, m; // iterate over heap elements
    int max_code = - 1; // largest code with non zero frequency
    int node; // new node being created

    // Construct the initial heap, with least frequent element in
    // heap[1]. The sons of heap[n] are heap[2*n] and heap[2*n+1].
    // heap[0] is not used.
    s.heap_len = 0;
    s.heap_max = HEAP_SIZE;

    for (n = 0; n < elems; n++) {
      if (tree[n * 2] != 0) {
        s.heap[++s.heap_len] = max_code = n;
        s.depth[n] = 0;
      } else {
        tree[n * 2 + 1] = 0;
      }
    }

    // The pkzip format requires that at least one distance code exists,
    // and that at least one bit should be sent even if there is only one
    // possible code. So to avoid special checks later on we force at least
    // two codes of non zero frequency.
    while (s.heap_len < 2) {
      node = s.heap[++s.heap_len] = (max_code < 2?++max_code:0);
      tree[node * 2] = 1;
      s.depth[node] = 0;
      s.opt_len--;
      if (stree != null) {
        s.static_len -= stree[node * 2 + 1];
      }
      // node is 0 or 1 so it does not have extra bits
    }
    this.max_code = max_code;

    // The elements heap[heap_len/2+1 .. heap_len] are leaves of the tree,
    // establish sub-heaps of increasing lengths:

    for (n = s.heap_len ~/ 2; n >= 1; n--) {
      s._pqdownheap(tree, n);
    }

    // Construct the Huffman tree by repeatedly combining the least two
    // frequent nodes.

    node = elems; // next node of the tree
    do {
      // n = node of least frequency
      n = s.heap[1];
      s.heap[1] = s.heap[s.heap_len--];
      s._pqdownheap(tree, 1);
      m = s.heap[1]; // m = node of next least frequency

      s.heap[--s.heap_max] = n; // keep the nodes sorted by frequency
      s.heap[--s.heap_max] = m;

      // Create a new node father of n and m
      tree[node * 2] = (tree[n * 2] + tree[m * 2]);
      s.depth[node] = (_max(s.depth[n], s.depth[m]) + 1);
      tree[n * 2 + 1] = tree[m * 2 + 1] = node;

      // and insert the new node in the heap
      s.heap[1] = node++;
      s._pqdownheap(tree, 1);
    } while (s.heap_len >= 2);

    s.heap[--s.heap_max] = s.heap[1];

    // At this point, the fields freq and dad are set. We can now
    // generate the bit lengths.

    _genBitlen(s);

    // The field len is now set, we can generate the bit codes
    _genCodes(tree, max_code, s.bl_count);
  }

  static int _max(int a, int b) => a > b ? a : b;

  /**
   * Generate the codes for a given tree and bit counts (which need not be
   * optimal).
   * IN assertion: the array bl_count contains the bit length statistics for
   * the given tree and the field len is set for all tree elements.
   * OUT assertion: the field code is set for all tree elements of non
   *     zero code length.
   */
  static void  _genCodes(Data.Uint16List tree, int max_code,
                         Data.Uint16List bl_count) {
    Data.Uint16List next_code = new Data.Uint16List(MAX_BITS + 1);
    int code = 0; // running code value
    int bits; // bit index
    int n; // code index

    // The distribution counts are first used to generate the code values
    // without bit reversal.
    for (bits = 1; bits <= MAX_BITS; bits++) {
      next_code[bits] = code = ((code + bl_count[bits - 1]) << 1);
    }

    for (n = 0; n <= max_code; n++) {
      int len = tree[n * 2 + 1];
      if (len == 0) {
        continue;
      }

      // Now reverse the bits
      tree[n * 2] = (_biReverse(next_code[len]++, len));
    }
  }

  /**
   * Reverse the first len bits of a code, using straightforward code (a faster
   * method would use a table)
   * IN assertion: 1 <= len <= 15
   */
  static int _biReverse(int code, int len) {
    int res = 0;
    do {
      res |= code & 1;
      code = _URShift(code, 1);
      res <<= 1;
    } while (--len > 0);
    return _URShift(res, 1);
  }
}

class _StaticTree {
  static const int MAX_BITS = 15;

  static const int BL_CODES = 19;
  static const int D_CODES = 30;
  static const int LITERALS = 256;
  static const int LENGTH_CODES = 29;
  static const int L_CODES = (LITERALS + 1 + LENGTH_CODES);

  // Bit length codes must not exceed MAX_BL_BITS bits
  static const int MAX_BL_BITS = 7;

  static const List<int> static_ltree = const [
      12, 8, 140, 8, 76, 8, 204, 8, 44, 8, 172, 8, 108, 8, 236, 8, 28, 8, 156,
      8, 92, 8, 220, 8, 60, 8, 188, 8, 124, 8, 252, 8, 2, 8, 130, 8, 66, 8, 194,
      8, 34, 8, 162, 8, 98, 8, 226, 8, 18, 8, 146, 8, 82, 8, 210, 8, 50, 8, 178,
      8, 114, 8, 242, 8, 10, 8, 138, 8, 74, 8, 202, 8, 42, 8, 170, 8, 106, 8,
      234, 8, 26, 8, 154, 8, 90, 8, 218, 8, 58, 8, 186, 8, 122, 8, 250, 8, 6, 8,
      134, 8, 70, 8, 198, 8, 38, 8, 166, 8, 102, 8, 230, 8, 22, 8, 150, 8, 86,
      8, 214, 8, 54, 8, 182, 8, 118, 8, 246, 8, 14, 8, 142, 8, 78, 8, 206, 8,
      46, 8, 174, 8, 110, 8, 238, 8, 30, 8, 158, 8, 94, 8, 222, 8, 62, 8, 190,
      8, 126, 8, 254, 8, 1, 8, 129, 8, 65, 8, 193, 8, 33, 8, 161, 8, 97, 8,
      225, 8, 17, 8, 145, 8, 81, 8, 209, 8, 49, 8, 177, 8, 113, 8, 241, 8, 9,
      8, 137, 8, 73, 8, 201, 8, 41, 8, 169, 8, 105, 8, 233, 8, 25, 8, 153, 8,
      89, 8, 217, 8, 57, 8, 185, 8, 121, 8, 249, 8, 5, 8, 133, 8, 69, 8, 197,
      8, 37, 8, 165, 8, 101, 8, 229, 8, 21, 8, 149, 8, 85, 8, 213, 8, 53, 8,
      181, 8, 117, 8, 245, 8, 13, 8, 141, 8, 77, 8, 205, 8, 45, 8, 173, 8, 109,
      8, 237, 8, 29, 8, 157, 8, 93, 8, 221, 8, 61, 8, 189, 8, 125, 8, 253, 8,
      19, 9, 275, 9, 147, 9, 403, 9, 83, 9, 339, 9, 211, 9, 467, 9, 51, 9, 307,
      9, 179, 9, 435, 9, 115, 9, 371, 9, 243, 9, 499, 9, 11, 9, 267, 9, 139, 9,
      395, 9, 75, 9, 331, 9, 203, 9, 459, 9, 43, 9, 299, 9, 171, 9, 427, 9, 107,
      9, 363, 9, 235, 9, 491, 9, 27, 9, 283, 9, 155, 9, 411, 9, 91, 9, 347, 9,
      219, 9, 475, 9, 59, 9, 315, 9, 187, 9, 443, 9, 123, 9, 379, 9, 251, 9,
      507, 9, 7, 9, 263, 9, 135, 9, 391, 9, 71, 9, 327, 9, 199, 9, 455, 9, 39,
      9, 295, 9, 167, 9, 423, 9, 103, 9, 359, 9, 231, 9, 487, 9, 23, 9, 279, 9,
      151, 9, 407, 9, 87, 9, 343, 9, 215, 9, 471, 9, 55, 9, 311, 9, 183, 9, 439,
      9, 119, 9, 375, 9, 247, 9, 503, 9, 15, 9, 271, 9, 143, 9, 399, 9, 79, 9,
      335, 9, 207, 9, 463, 9, 47, 9, 303, 9, 175, 9, 431, 9, 111, 9, 367, 9,
      239, 9, 495, 9, 31, 9, 287, 9, 159, 9, 415, 9, 95, 9, 351, 9, 223, 9, 479,
      9, 63, 9, 319, 9, 191, 9, 447, 9, 127, 9, 383, 9, 255, 9, 511, 9, 0, 7,
      64, 7, 32, 7, 96, 7, 16, 7, 80, 7, 48, 7, 112, 7, 8, 7, 72, 7, 40, 7, 104,
      7, 24, 7, 88, 7, 56, 7, 120, 7, 4, 7, 68, 7, 36, 7, 100, 7, 20, 7, 84, 7,
      52, 7, 116, 7, 3, 8, 131, 8, 67, 8, 195, 8, 35, 8, 163, 8, 99, 8, 227, 8];

  static const List<int> static_dtree = const [
      0, 5, 16, 5, 8, 5, 24, 5, 4, 5, 20, 5, 12, 5, 28, 5, 2, 5, 18, 5, 10, 5,
      26, 5, 6, 5, 22, 5, 14, 5, 30, 5, 1, 5, 17, 5, 9, 5, 25, 5, 5, 5, 21, 5,
      13, 5, 29, 5, 3, 5, 19, 5, 11, 5, 27, 5, 7, 5, 23, 5];

  static _StaticTree static_l_desc =
      new _StaticTree(static_ltree, _Tree.extra_lbits, LITERALS + 1,
                      L_CODES, MAX_BITS);

  static _StaticTree static_d_desc =
      new _StaticTree(static_dtree, _Tree.extra_dbits, 0, D_CODES, MAX_BITS);

  static _StaticTree static_bl_desc =
      new _StaticTree(null, _Tree.extra_blbits, 0, BL_CODES, MAX_BL_BITS);

  List<int> static_tree; // static tree or null
  List<int> extra_bits; // extra bits for each code or null
  int extra_base; // base index for extra_bits
  int elems; // max number of elements in the tree
  int max_length; // max bit length for the codes

  _StaticTree(this.static_tree, this.extra_bits, this.extra_base,
             this.elems, this.max_length);
}

/**
 * Performs an unsigned bitwise right shift with the specified number
 */
int _URShift(int number, int bits) {
  int nbits = (~bits + 0x10000) & 0xffff;
  if ( number >= 0) {
    return number >> bits;
  } else {
    return (number >> bits) + (2 << nbits);//~bits);
  }
}
