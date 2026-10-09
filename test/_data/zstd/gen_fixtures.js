// Generates the zstd test fixtures, with Node 22.15 or later:
//
//   node test/_data/zstd/gen_fixtures.js test/_data/zstd
//
// The inputs come from synth() and friends, which test/_zstd_util.dart
// reimplements, so only compressed data is stored. The fmtdict fixtures come
// from gen_fmtdict.py instead, which needs the zstandard Python package.
const zlib = require('zlib'), fs = require('fs'), path = require('path');
const C = zlib.constants;
const out = process.argv[2];

function rng(seed) { let s = seed >>> 0; return () => { s ^= s << 13; s ^= s >>> 17; s ^= s << 5; s >>>= 0; return s; }; }

// A mix of skewed text, matches at short to long distances, byte runs and
// random bytes.
function synth(n, seed) {
  const next = rng(seed), b = new Uint8Array(n); let i = 0;
  while (i < n) {
    const r = next() % 100;
    if (r < 45 && i > 0) {
      const k = next() % 4, maxd = [16, 1000, 60000, i][k];
      const d = 1 + next() % Math.min(i, maxd), len = 3 + next() % (k === 0 ? 50 : 30);
      for (let j = 0; j < len && i < n; j++, i++) b[i] = b[i - d];
    } else if (r < 85) {
      const len = 1 + next() % 20;
      for (let j = 0; j < len && i < n; j++, i++) b[i] = 97 + Math.floor(((next() % 26) * (next() % 26)) / 26);
    } else if (r < 95) {
      const v = next() & 0xff, len = 1 + next() % 300;
      for (let j = 0; j < len && i < n; j++, i++) b[i] = v;
    } else {
      const len = 1 + next() % 100;
      for (let j = 0; j < len && i < n; j++, i++) b[i] = next() & 0xff;
    }
  }
  return Buffer.from(b);
}

// Copies of 2000 random bytes with a 'Z' inserted every so often, so that
// once the first copy is out of the way the only literals are 'Z's.
function rleLiterals(n, seed) {
  const next = rng(seed), r = new Uint8Array(2000), b = new Uint8Array(n);
  for (let i = 0; i < 2000; i++) r[i] = next() & 0xff;
  let i = 0, j = 0;
  while (i < n) {
    if (i >= 2000 && next() % 200 === 0) b[i++] = 90;
    else b[i++] = r[j++ % 2000];
  }
  return Buffer.from(b);
}

// Sixteen symbols with skewed frequencies, whose Huffman weights zstd stores
// directly rather than compressed.
function nibbles(n, seed) {
  const next = rng(seed), b = new Uint8Array(n);
  for (let i = 0; i < n; i++) b[i] = ((next() % 16) * (next() % 16)) >> 4;
  return Buffer.from(b);
}

function z(data, params, opts = {}) {
  const p = {};
  for (const [k, v] of Object.entries(params)) p[C['ZSTD_c_' + k]] = v;
  return zlib.zstdCompressSync(data, {params: p, ...opts});
}
const w = (name, data) => fs.writeFileSync(path.join(out, name), data);

const s = synth(300000, 1);
w('synth.l1.zst', z(s, {compressionLevel: 1}));
w('synth.l3.zst', z(s, {compressionLevel: 3, checksumFlag: 1}));
w('synth.l19.zst', z(s, {compressionLevel: 19, checksumFlag: 1}));
w('synth.lm5.zst', z(s, {compressionLevel: -5}));
// A 1 KB window and no content size: the window slides, and blocks of
// random bytes are stored raw.
w('synth.w10.zst', z(s, {compressionLevel: 9, windowLog: 10, contentSizeFlag: 0, checksumFlag: 1}));
w('rle.zst', z(rleLiterals(300000, 2), {compressionLevel: 19, checksumFlag: 1}));
w('nibbles.zst', z(nibbles(20000, 3), {compressionLevel: 3, checksumFlag: 1}));

// Random bytes, a long run of one byte, then synth(5000, 9), with a 1 KB
// window: blocks stored raw and as RLE.
function randomBytes(n, seed) { const next = rng(seed), b = new Uint8Array(n); for (let i = 0; i < n; i++) b[i] = next() & 0xff; return Buffer.from(b); }
w('blocks.zst', z(Buffer.concat([randomBytes(5000, 8), Buffer.alloc(5000, 0x41), synth(5000, 9)]), {compressionLevel: 3, windowLog: 10, checksumFlag: 1}));

// Three frames and a skippable frame between them: synth(1000, 4),
// synth(20000, 5) and synth(1000, 4) again.
const skip = Buffer.alloc(13); skip.writeUInt32LE(0x184D2A53, 0); skip.writeUInt32LE(5, 4);
w('multi.zst', Buffer.concat([z(synth(1000, 4), {}), skip, z(synth(20000, 5), {checksumFlag: 1}), z(synth(1000, 4), {compressionLevel: 19})]));

// Raw content dictionary: synth(30000, 6), used to compress its middle
// followed by synth(10000, 7).
const dict = synth(30000, 6);
w('rawdict.zst', z(Buffer.concat([dict.subarray(5000, 25000), synth(10000, 7)]), {compressionLevel: 3, checksumFlag: 1}, {dictionary: dict}));
// A zip whose entries use method 93, zstd, except for one deflated entry, built
// by hand since Node has no zip writer. The contents are files already in
// test/_data/zip.
function zip(entries) {
  const locals = [], centrals = [];
  let offset = 0;
  for (const {name, data, method} of entries) {
    const packed = method === 93 ? z(data, {compressionLevel: 19, checksumFlag: 1})
                 : zlib.deflateRawSync(data);
    const nameBytes = Buffer.from(name);
    const crc = zlib.crc32(data);
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0); local.writeUInt16LE(63, 4);
    local.writeUInt16LE(method, 8); local.writeUInt16LE(0x5000, 10); local.writeUInt16LE(0x5921, 12);
    local.writeUInt32LE(crc, 14); local.writeUInt32LE(packed.length, 18); local.writeUInt32LE(data.length, 22);
    local.writeUInt16LE(nameBytes.length, 26);
    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0); central.writeUInt16LE(63, 4); central.writeUInt16LE(63, 6);
    central.writeUInt16LE(method, 10); central.writeUInt16LE(0x5000, 12); central.writeUInt16LE(0x5921, 14);
    central.writeUInt32LE(crc, 16); central.writeUInt32LE(packed.length, 20); central.writeUInt32LE(data.length, 24);
    central.writeUInt16LE(nameBytes.length, 28); central.writeUInt32LE(offset, 42);
    locals.push(local, nameBytes, packed);
    centrals.push(central, nameBytes);
    offset += 30 + nameBytes.length + packed.length;
  }
  const cd = Buffer.concat(centrals);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0); end.writeUInt16LE(entries.length, 8); end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(cd.length, 12); end.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, cd, end]);
}
const zipData = path.join(__dirname, '..', 'zip');
w('zstd.zip', zip([
  {name: 'hello.txt', data: fs.readFileSync(path.join(zipData, 'hello.txt')), method: 93},
  {name: 'gophercolor16x16.png', data: fs.readFileSync(path.join(zipData, 'gophercolor16x16.png')), method: 93},
  {name: 'readme.notzip', data: fs.readFileSync(path.join(zipData, 'readme.notzip')), method: 8},
]));

// test/_data/test2.tar compressed, for extractFileToDisk.
w('test2.tar.zst', z(fs.readFileSync(path.join(__dirname, '..', 'test2.tar')), {compressionLevel: 3, checksumFlag: 1}));

// Embedded in test/zstd_web_test.dart, which cannot read files.
console.log('web fixture:', z(synth(20000, 11), {compressionLevel: 3, checksumFlag: 1}).toString('base64'));
console.log(fs.readdirSync(out).map(f => f + ' ' + fs.statSync(path.join(out, f)).size).join('\n'));
