part of archive_test;

void defineInflateTests() {
  group('inflate', () {
    List<int> buffer = new List<int>(0xfffff);
    for (int i = 0; i < buffer.length; ++i) {
      buffer[i] = i % 256;
    }

    test('stream/NO_COMPRESSION', () {
      // compress the buffer (assumption: deflate works correctly).
      List<int> deflated = new Deflate(buffer,
          level: Deflate.NO_COMPRESSION).getBytes();

      // re-cast the deflated bytes as a Uint8List (which is it's native type).
      // Do this so we can use use Uint8List.view to section off chunks of the
      // data to test streamed inflation.
      Uint8List deflatedBytes = deflated as Uint8List;

      // Create a new stream inflator.
      Inflate inflate = new Inflate.stream();

      int bi = 0;

      // The section of the input buffer we're currently streaming.
      int streamOffset = 0;
      int streamSize = 1049;
      // Continue while we haven't streamed all of the data yet.
      while (streamOffset < deflatedBytes.length) {
        // Create a view of the input data for the bytes we're currently
        // streaming.
        Uint8List streamBytes = new Uint8List.view(deflatedBytes.buffer,
                                                   streamOffset,
                                                   streamSize);
        streamOffset += streamBytes.length;

        // Set the new bytes as the stream input.
        inflate.streamInput(streamBytes);

        // Inflate all of blocks available from the stream input.
        List<int> inflated = inflate.inflateNext();
        while (inflated != null) {
          // Verify the current block we inflated matches the original buffer.
          for (int i = 0; i < inflated.length; ++i) {
            expect(inflated[i], equals(buffer[bi++]));
          }
          inflated = inflate.inflateNext();
        }
      }
    });
  });
}
