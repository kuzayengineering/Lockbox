// Recognising Ultra HDR photos (JPEGs with an HDR gain map, as made by
// Pixel cameras and by Lockbox's "Save frame" on HDR video).

import 'dart:convert';
import 'dart:typed_data';

final List<List<int>> _markers = [
  ascii.encode('hdrgm:'), // Adobe/Google gain map XMP (Ultra HDR v1)
  ascii.encode('urn:iso:std:iso:ts:21496'), // ISO 21496-1 gain map
];

/// [head] should be the first part of the file (256 KB is plenty).
bool looksUltraHdr(Uint8List head) {
  if (head.length < 4 || head[0] != 0xFF || head[1] != 0xD8) return false;
  for (final m in _markers) {
    if (_indexOf(head, m) >= 0) return true;
  }
  return false;
}

int _indexOf(Uint8List hay, List<int> needle) {
  final first = needle[0];
  outer:
  for (var i = 0; i <= hay.length - needle.length; i++) {
    if (hay[i] != first) continue;
    for (var j = 1; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}
