# archive
[![Build Status](https://travis-ci.org/brendan-duncan/archive.svg?branch=master)](https://travis-ci.org/brendan-duncan/archive)

# NOTICE
Due to the constraints of life, I am unable to maintain this library any longer. I appologize to everyone using it that I won't be able to continue support. If others want to take over development, I would be happy to see it continue. Please message me if you would like to take over the development.

## Overview

A Dart library to encode and decode various archive and compression formats.

The library has no reliance on `dart:io`, so it can be used for both server and
web applications.

The archive library currently supports the following decoders:

- Zip (Archive)
- Tar (Archive)
- ZLib [Inflate decompression]
- GZip [Inflate decompression]
- BZip2 [decompression]

And the following encoders:

- Zip (Archive)
- Tar (Archive)
- ZLib [Deflate compression]
- GZip [Deflate compression]
- BZip2 [compression]

