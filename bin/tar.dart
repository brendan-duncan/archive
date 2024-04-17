// ignore_for_file: avoid_print
import 'dart:io';
import 'package:archive/archive_io.dart';

// tar --list <file>
// tar --extract <file> <dest>
// tar --create <source>
const usage = 'usage: tar [--list|--extract|--create] <file> [<dest>|<source>]';

void _fail(String message) {
  print(message);
  exit(1);
}

void main(List<String> arguments) async {
  if (arguments.isEmpty) {
    _fail(usage);
  }

  final command = arguments[0];
  if (command == '--list') {
    if (arguments.length < 2) {
      _fail(usage);
    }
    listTarFiles(arguments[1]);
  } else if (command == '--extract') {
    if (arguments.length < 3) {
      _fail(usage);
    }
    extractTarFiles(arguments[1], arguments[2]);
  } else if (command == '--create') {
    if (arguments.length < 2) {
      _fail(usage);
    }
    await createTarFile(arguments[1]);
  } else {
    _fail(usage);
  }
}
