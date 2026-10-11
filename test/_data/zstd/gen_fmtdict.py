# Trains a small zstd dictionary on JSON-like records and compresses one of
# them with it, for test/zstd_test.dart.
import os, random, sys
import zstandard as zstd

out = sys.argv[1]
random.seed(7)
words = ['alpha', 'beta', 'gamma', 'delta', 'user', 'name', 'email', 'status', 'active', 'value', 'items', 'price']

def record(i):
    return ('{"id": %d, "name": "%s", "email": "%s@example.com", "status": "%s", "price": %d.%02d, "tags": [%s]}\n' % (
        i, random.choice(words), random.choice(words), random.choice(['active', 'inactive', 'pending']),
        random.randint(0, 999), random.randint(0, 99),
        ', '.join('"%s"' % random.choice(words) for _ in range(random.randint(0, 4))))).encode()

samples = [b''.join(record(i * 10 + j) for j in range(random.randint(1, 6))) for i in range(1000)]
d = zstd.train_dictionary(4096, samples)
open(os.path.join(out, 'fmtdict.dict'), 'wb').write(d.as_bytes())
sample = b''.join(samples[990:1000])
open(os.path.join(out, 'fmtdict.txt'), 'wb').write(sample)
open(os.path.join(out, 'fmtdict.zst'), 'wb').write(zstd.ZstdCompressor(level=3, dict_data=d, write_checksum=True).compress(sample))
open(os.path.join(out, 'fmtdict.l19.zst'), 'wb').write(zstd.ZstdCompressor(level=19, dict_data=d, write_checksum=True).compress(sample))
print('dict id', d.dict_id(), len(d.as_bytes()), 'sample', len(sample))
