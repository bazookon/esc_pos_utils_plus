import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';

/// Renders ESC/POS bytes to a text grid interpreting `ESC $` (set absolute
/// print position) so we can assert the visual layout of rows.
List<String> render(List<int> bytes, {int paperDots = 372, int cpl = 32}) {
  final double charWidth = paperDots / cpl;
  final lines = <String>[];
  var line = List.filled(cpl + 4, ' ');
  int col = 0;
  bool lineUsed = false;

  void flush() {
    lines.add(line.join().trimRight());
    line = List.filled(cpl + 4, ' ');
    col = 0;
    lineUsed = false;
  }

  for (int i = 0; i < bytes.length; i++) {
    final b = bytes[i];
    if (b == 0x1B) {
      final cmd = bytes[i + 1];
      if (cmd == 0x24) {
        // ESC $ nL nH -> absolute position in dots
        final pos = bytes[i + 2] + bytes[i + 3] * 256;
        col = (pos / charWidth).round();
        i += 3;
      } else if (cmd == 0x61 || cmd == 0x45 || cmd == 0x4D || cmd == 0x21) {
        i += 2; // align / bold / font / style: 1 param
      } else if (cmd == 0x74 || cmd == 0x64) {
        if (cmd == 0x64) {
          // ESC d n -> feed n lines
          if (lineUsed) flush();
          for (int f = 0; f < bytes[i + 2]; f++) {
            lines.add('');
          }
        }
        i += 2;
      } else if (cmd == 0x40) {
        i += 1; // init
      } else {
        i += 1;
      }
    } else if (b == 0x1D) {
      i += 2; // GS commands used here carry 1 param
    } else if (b == 0x1C) {
      // FS . / FS & (kanji off/on) have no params; FS C / FS t carry 1
      final cmd = bytes[i + 1];
      i += (cmd == 0x2E || cmd == 0x26) ? 1 : 2;
    } else if (b == 0x0A) {
      flush();
    } else if (b >= 0x20) {
      if (col < line.length) {
        line[col] = String.fromCharCode(b);
        lineUsed = true;
      }
      col++;
    }
  }
  if (lineUsed) flush();
  return lines;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Generator generator;

  setUp(() async {
    final profile = await CapabilityProfile.load(name: 'Sunmi-V2');
    generator = Generator(PaperSize.mm58, profile);
  });

  test('row wraps long column content at word boundaries', () {
    final bytes = generator.row([
      PosColumn(
          text: '1',
          width: 2,
          styles: const PosStyles(align: PosAlign.center)),
      PosColumn(
          text: 'mistral seleccion de barricas 750cc (botella)',
          width: 6,
          styles: const PosStyles(align: PosAlign.left)),
      PosColumn(
          text: '\$50.000',
          width: 4,
          styles: const PosStyles(align: PosAlign.right)),
    ]);

    final lines = render(bytes);
    for (final l in lines) {
      // ignore: avoid_print
      print('|${l.padRight(32)}|');
    }

    // No line may hard-split a word: every continuation line must start
    // at the product column and contain whole words of the source text.
    const source = 'mistral seleccion de barricas 750cc (botella)';
    final printedWords = lines
        .expand((l) => l.split(RegExp(r'\s+')))
        .where((w) => w.isNotEmpty && w != '1' && w != '\$50.000')
        .toList();
    for (final w in printedWords) {
      expect(source.split(' ').contains(w), true,
          reason: '"$w" is not a whole word of the source -> word was split');
    }
    // All words printed exactly once, in order.
    expect(printedWords.join(' '), source);
  });

  test('embedded newlines in column text do not break column positioning', () {
    // Ticket de producto real: nombre con '\n' embebido (mm58, columnas 2+10)
    final bytes = generator.row([
      PosColumn(
          text: '1x',
          width: 2,
          styles: const PosStyles(align: PosAlign.left, bold: true)),
      PosColumn(
          text: 'mistral 35° 750cc\n(botella)(+6 redbull)',
          width: 10,
          styles: const PosStyles(align: PosAlign.left, bold: true)),
    ]);

    final lines = render(bytes);
    for (final l in lines) {
      // ignore: avoid_print
      print('|${l.padRight(32)}|');
    }

    // No blank lines in the middle, and every continuation line must be
    // indented to the product column (col index 2 of 12 -> char 5), never
    // at column 0.
    final content = lines.where((l) => l.isNotEmpty).toList();
    expect(content.length, lines.length,
        reason: 'embedded newline produced a blank line');
    for (final l in content.skip(1)) {
      expect(l.startsWith('     '), true,
          reason: 'continuation "$l" is not aligned to its column');
    }
  });

  test('header row with short column does not leak dot to next line', () {
    final bytes = generator.row([
      PosColumn(
          text: 'Cant',
          width: 2,
          styles: const PosStyles(align: PosAlign.center, bold: true)),
      PosColumn(
          text: 'Producto',
          width: 6,
          styles: const PosStyles(align: PosAlign.left, bold: true)),
      PosColumn(
          text: 'Total',
          width: 4,
          styles: const PosStyles(align: PosAlign.right, bold: true)),
    ]);

    final lines = render(bytes);
    for (final l in lines) {
      // ignore: avoid_print
      print('|${l.padRight(32)}|');
    }
    expect(lines.where((l) => l.trim().isNotEmpty).length, 1);
  });
}
