import 'dart:convert';
import 'dart:typed_data';

import 'crc32.dart';
import 'input_stream.dart';

const _cp437High = 'ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ¢£¥₧ƒáíóúñÑªº¿⌐¬½¼¡«»'
    '░▒▓│┤╡╢╖╕╣║╗╝╜╛┐└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀'
    'αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■ ';

String? _decode(Encoding encoding, Uint8List bytes) {
  try {
    return encoding.decode(bytes);
  } on FormatException {
    return null;
  }
}

String zipName(Uint8List name, int flags, Encoding? encoding) =>
    (encoding != null && flags & 0x800 == 0 ? _decode(encoding, name) : null) ??
    _decode(utf8, name) ??
    String.fromCharCodes(
        name.map((c) => c < 0x80 ? c : _cp437High.codeUnitAt(c - 0x80)));

String? zipUnicodePath(Uint8List name, InputStream field) {
  if (field.length < 5 ||
      field.readByte() != 1 ||
      field.readUint32() != getCrc32(name)) {
    return null;
  }
  final path = _decode(utf8, field.toUint8List());
  return path == null || path.isEmpty ? null : path;
}
