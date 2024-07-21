library test.archive;

import 'adler32_test.dart' as adler32_test;
import 'archive_test.dart' as archive_test;
import 'bzip2_test.dart' as bzip2_test;
import 'commands_test.dart' as commands_test;
import 'crc32_test.dart' as crc32_test;
import 'deflate_test.dart' as deflate_test;
import 'gzip_test.dart' as gzip_test;
import 'inflate_test.dart' as inflate_test;
import 'input_file_stream_test.dart' as input_file_stream_test;
import 'input_memory_stream_test.dart' as input_memory_stream_test;
import 'io_test.dart' as io_test;
import 'output_file_stream_test.dart' as output_file_stream_test;
import 'output_memory_stream_test.dart' as output_memory_stream_test;
import 'ram_file_data_test.dart' as ram_file_data_test;
import 'tar_test.dart' as tar_test;
import 'xz_test.dart' as xz_test;
import 'zip_test.dart' as zip_test;
import 'zlib_test.dart' as zlib_test;

void main() {
  adler32_test.main();
  archive_test.main();
  bzip2_test.main();
  commands_test.main();
  crc32_test.main();
  deflate_test.main();
  gzip_test.main();
  inflate_test.main();
  input_file_stream_test.main();
  input_memory_stream_test.main();
  io_test.main();
  ram_file_data_test.main();
  output_file_stream_test.main();
  output_memory_stream_test.main();
  tar_test.main();
  zip_test.main();
  zlib_test.main();
  xz_test.main();
}
