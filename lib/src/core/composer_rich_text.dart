/// Runtime-neutral rich-text model for the Markdown subset used by the
/// Handrail message composer.
///
/// The wire and draft formats remain Markdown. This deliberately bounded
/// model is an immutable editing boundary for composer renderers.
enum ComposerRichTextMarkType { bold, italic, strikethrough, link, code }

/// One supported inline mark.
final class ComposerRichTextMark {
  const ComposerRichTextMark._(this.type, {this.href});

  const ComposerRichTextMark.bold() : this._(ComposerRichTextMarkType.bold);

  const ComposerRichTextMark.italic() : this._(ComposerRichTextMarkType.italic);

  const ComposerRichTextMark.strikethrough()
      : this._(ComposerRichTextMarkType.strikethrough);

  const ComposerRichTextMark.code() : this._(ComposerRichTextMarkType.code);

  const ComposerRichTextMark.link(String href)
      : this._(ComposerRichTextMarkType.link, href: href);

  final ComposerRichTextMarkType type;

  /// Present only for [ComposerRichTextMarkType.link].
  final String? href;

  @override
  bool operator ==(Object other) =>
      other is ComposerRichTextMark && type == other.type && href == other.href;

  @override
  int get hashCode => Object.hash(type, href);
}

/// Immutable text carrying zero or more supported marks.
final class ComposerRichTextSpan {
  ComposerRichTextSpan(
      {required this.text, List<ComposerRichTextMark> marks = const []})
      : marks = List.unmodifiable(marks);

  final String text;
  final List<ComposerRichTextMark> marks;

  @override
  bool operator ==(Object other) =>
      other is ComposerRichTextSpan &&
      text == other.text &&
      _listEquals(marks, other.marks);

  @override
  int get hashCode => Object.hash(text, Object.hashAll(marks));
}

/// Base type for the supported composer blocks.
sealed class ComposerRichTextBlock {
  const ComposerRichTextBlock();
}

/// A paragraph, including a multi-line paragraph.
final class ComposerRichTextParagraph extends ComposerRichTextBlock {
  ComposerRichTextParagraph({List<ComposerRichTextSpan> content = const []})
      : content = List.unmodifiable(content);

  final List<ComposerRichTextSpan> content;

  @override
  bool operator ==(Object other) =>
      other is ComposerRichTextParagraph && _listEquals(content, other.content);

  @override
  int get hashCode => Object.hashAll(content);
}

/// One unordered-list item. Adjacent items form a list.
final class ComposerRichTextUnorderedListItem extends ComposerRichTextBlock {
  ComposerRichTextUnorderedListItem({
    List<ComposerRichTextSpan> content = const [],
  }) : content = List.unmodifiable(content);

  final List<ComposerRichTextSpan> content;

  @override
  bool operator ==(Object other) =>
      other is ComposerRichTextUnorderedListItem &&
      _listEquals(content, other.content);

  @override
  int get hashCode => Object.hashAll(content);
}

/// One ordered-list item. Adjacent items form a list.
final class ComposerRichTextOrderedListItem extends ComposerRichTextBlock {
  ComposerRichTextOrderedListItem({
    required this.ordinal,
    List<ComposerRichTextSpan> content = const [],
  }) : content = List.unmodifiable(content);

  final int ordinal;
  final List<ComposerRichTextSpan> content;

  @override
  bool operator ==(Object other) =>
      other is ComposerRichTextOrderedListItem &&
      ordinal == other.ordinal &&
      _listEquals(content, other.content);

  @override
  int get hashCode => Object.hash(ordinal, Object.hashAll(content));
}

/// A fenced code block with an optional language hint.
final class ComposerRichTextCodeBlock extends ComposerRichTextBlock {
  const ComposerRichTextCodeBlock({required this.text, this.language});

  final String text;
  final String? language;

  @override
  bool operator ==(Object other) =>
      other is ComposerRichTextCodeBlock &&
      text == other.text &&
      language == other.language;

  @override
  int get hashCode => Object.hash(text, language);
}

/// A deeply immutable composer document.
final class ComposerRichTextDocument {
  ComposerRichTextDocument({List<ComposerRichTextBlock> blocks = const []})
      : blocks = List.unmodifiable(blocks);

  final List<ComposerRichTextBlock> blocks;

  @override
  bool operator ==(Object other) =>
      other is ComposerRichTextDocument && _listEquals(blocks, other.blocks);

  @override
  int get hashCode => Object.hashAll(blocks);
}

const _boldMark = ComposerRichTextMark.bold();
const _italicMark = ComposerRichTextMark.italic();
const _strikethroughMark = ComposerRichTextMark.strikethrough();
const _codeMark = ComposerRichTextMark.code();

final _controlCharacters = RegExp(r'[\u0000-\u001f\u007f]');
final _listLine = RegExp(r'^ {0,3}(?:([-+*])|(\d+)[.)])[\t ]+(.*)$');
final _fenceLine = RegExp(r'^ {0,3}(`{3,}|~{3,})([^\r\n]*)$');
final _inlineEscapable = RegExp(r'[\\`*_\[\]~+\-.)]');

/// Returns a normalized safe link destination, or null for an unsafe link.
///
/// HTTP, HTTPS, mailto, and relative links are allowed. Control characters
/// are removed before the scheme is checked, so they cannot disguise an
/// unsafe scheme.
String? sanitizeComposerMarkdownLink(String href) {
  final sanitized = href.replaceAll(_controlCharacters, '').trim();
  if (sanitized.isEmpty) return null;

  final parsed = Uri.tryParse(sanitized);
  if (parsed == null) return null;
  final scheme = parsed.scheme.toLowerCase();
  if (scheme.isNotEmpty &&
      scheme != 'http' &&
      scheme != 'https' &&
      scheme != 'mailto') {
    return null;
  }
  return sanitized;
}

void _appendSpan(
  List<ComposerRichTextSpan> spans,
  String text, [
  List<ComposerRichTextMark> marks = const [],
]) {
  if (text.isEmpty) return;
  final previous = spans.isEmpty ? null : spans.last;
  if (previous != null && _listEquals(previous.marks, marks)) {
    spans[spans.length - 1] = ComposerRichTextSpan(
      text: previous.text + text,
      marks: previous.marks,
    );
    return;
  }
  spans.add(ComposerRichTextSpan(text: text, marks: marks));
}

List<ComposerRichTextSpan> _addOuterMark(
  List<ComposerRichTextSpan> spans,
  ComposerRichTextMark mark,
) {
  final marked = <ComposerRichTextSpan>[];
  for (final span in spans) {
    _appendSpan(marked, span.text, [mark, ...span.marks]);
  }
  return List.unmodifiable(marked);
}

List<ComposerRichTextSpan> _parseInline(String source) {
  final spans = <ComposerRichTextSpan>[];
  var index = 0;

  while (index < source.length) {
    final character = source[index];
    if (character == r'\' && index + 1 < source.length) {
      final escaped = source[index + 1];
      if (_inlineEscapable.hasMatch(escaped)) {
        _appendSpan(spans, escaped);
        index += 2;
        continue;
      }
    }

    if (character == '`') {
      final closing = source.indexOf('`', index + 1);
      if (closing > index + 1) {
        _appendSpan(spans, source.substring(index + 1, closing), [_codeMark]);
        index = closing + 1;
        continue;
      }
    }

    if (character == '!' &&
        index + 1 < source.length &&
        source[index + 1] == '[') {
      final labelEnd = source.indexOf('](', index + 2);
      final destinationEnd =
          labelEnd == -1 ? -1 : source.indexOf(')', labelEnd + 2);
      if (labelEnd > index + 2 && destinationEnd > labelEnd + 2) {
        _appendSpan(spans, source.substring(index, destinationEnd + 1));
        index = destinationEnd + 1;
        continue;
      }
    }

    if (character == '[') {
      final labelEnd = source.indexOf('](', index + 1);
      final destinationEnd =
          labelEnd == -1 ? -1 : source.indexOf(')', labelEnd + 2);
      if (labelEnd > index + 1 && destinationEnd > labelEnd + 2) {
        final destination = source.substring(labelEnd + 2, destinationEnd);
        final href = sanitizeComposerMarkdownLink(destination);
        final entireLink = source.substring(index, destinationEnd + 1);
        if (href == null) {
          _appendSpan(spans, entireLink);
        } else {
          final label = _parseInline(source.substring(index + 1, labelEnd));
          for (final span in _addOuterMark(
            label,
            ComposerRichTextMark.link(href),
          )) {
            _appendSpan(spans, span.text, span.marks);
          }
        }
        index = destinationEnd + 1;
        continue;
      }
    }

    final marker = source.startsWith('**', index)
        ? '**'
        : source.startsWith('__', index)
            ? '__'
            : source.startsWith('~~', index)
                ? '~~'
                : character == '*' || character == '_'
                    ? character
                    : null;
    if (marker != null) {
      final closing = source.indexOf(marker, index + marker.length);
      if (closing > index + marker.length) {
        final mark = marker == '~~'
            ? _strikethroughMark
            : marker.length == 2
                ? _boldMark
                : _italicMark;
        final marked = _addOuterMark(
          _parseInline(source.substring(index + marker.length, closing)),
          mark,
        );
        for (final span in marked) {
          _appendSpan(spans, span.text, span.marks);
        }
        index = closing + marker.length;
        continue;
      }

      // Consume the whole unmatched delimiter so its second character cannot
      // accidentally open another mark.
      _appendSpan(spans, marker);
      index += marker.length;
      continue;
    }

    _appendSpan(spans, character);
    index += 1;
  }

  return List.unmodifiable(spans);
}

final class _ParsedFence {
  const _ParsedFence({
    required this.character,
    required this.length,
    this.language,
  });

  final String character;
  final int length;
  final String? language;
}

_ParsedFence? _parseFence(String line) {
  final match = _fenceLine.firstMatch(line);
  final marker = match?.group(1);
  if (marker == null) return null;
  final language = (match?.group(2) ?? '').trim();
  return _ParsedFence(
    character: marker[0],
    length: marker.length,
    language: language.isEmpty ? null : language,
  );
}

bool _closesFence(String line, _ParsedFence fence) {
  final marker = line.trim();
  if (marker.length < fence.length) return false;
  for (var index = 0; index < marker.length; index += 1) {
    if (marker[index] != fence.character) return false;
  }
  return true;
}

int _closingFenceIndex(
  List<String> lines,
  int openingIndex,
  _ParsedFence fence,
) {
  for (var index = openingIndex + 1; index < lines.length; index += 1) {
    if (_closesFence(lines[index], fence)) return index;
  }
  return -1;
}

ComposerRichTextParagraph _paragraph(String source) =>
    ComposerRichTextParagraph(content: _parseInline(source));

/// Converts stored composer Markdown into an immutable editing document.
ComposerRichTextDocument composerMarkdownToRichTextDocument(String source) {
  final lines = source.replaceAll(RegExp(r'\r\n?'), '\n').split('\n');
  final blocks = <ComposerRichTextBlock>[];
  var index = 0;

  while (index < lines.length) {
    if (lines[index].trim().isEmpty) {
      index += 1;
      continue;
    }

    final fence = _parseFence(lines[index]);
    if (fence != null) {
      final closingIndex = _closingFenceIndex(lines, index, fence);
      if (closingIndex != -1) {
        blocks.add(ComposerRichTextCodeBlock(
          text: lines.sublist(index + 1, closingIndex).join('\n'),
          language: fence.language,
        ));
        index = closingIndex + 1;
        continue;
      }

      // An unclosed fence stays editable literal text.
      final fallbackLines = <String>[lines[index]];
      index += 1;
      while (index < lines.length && lines[index].trim().isNotEmpty) {
        fallbackLines.add(lines[index]);
        index += 1;
      }
      blocks.add(_paragraph(fallbackLines.join('\n')));
      continue;
    }

    final listMatch = _listLine.firstMatch(lines[index]);
    if (listMatch != null) {
      final ordered = listMatch.group(2) != null;
      while (index < lines.length) {
        final itemMatch = _listLine.firstMatch(lines[index]);
        if (itemMatch == null || (itemMatch.group(2) != null) != ordered) {
          break;
        }
        final content = _parseInline(itemMatch.group(3) ?? '');
        if (ordered) {
          blocks.add(ComposerRichTextOrderedListItem(
            ordinal: int.parse(itemMatch.group(2)!),
            content: content,
          ));
        } else {
          blocks.add(ComposerRichTextUnorderedListItem(content: content));
        }
        index += 1;
      }
      continue;
    }

    final paragraphLines = <String>[];
    while (index < lines.length && lines[index].trim().isNotEmpty) {
      final candidate = lines[index];
      if (_listLine.hasMatch(candidate) || _parseFence(candidate) != null) {
        break;
      }
      paragraphLines.add(candidate);
      index += 1;
    }
    blocks.add(_paragraph(paragraphLines.join('\n')));
  }

  return ComposerRichTextDocument(blocks: blocks);
}

const _markOrder = <ComposerRichTextMarkType, int>{
  ComposerRichTextMarkType.bold: 0,
  ComposerRichTextMarkType.italic: 1,
  ComposerRichTextMarkType.strikethrough: 2,
  ComposerRichTextMarkType.link: 3,
  ComposerRichTextMarkType.code: 4,
};

List<ComposerRichTextMark> _normalizeMarks(
  List<ComposerRichTextMark> marks,
  String text,
) {
  final byType = <ComposerRichTextMarkType, ComposerRichTextMark>{};
  for (final mark in marks) {
    if (byType.containsKey(mark.type)) continue;
    if (mark.type == ComposerRichTextMarkType.link) {
      final href = sanitizeComposerMarkdownLink(mark.href ?? '');
      if (href != null) {
        byType[mark.type] = ComposerRichTextMark.link(href);
      }
    } else if (mark.type != ComposerRichTextMarkType.code ||
        !text.contains('`')) {
      byType[mark.type] = mark;
    }
  }
  final normalized = byType.values.toList()
    ..sort((left, right) =>
        _markOrder[left.type]!.compareTo(_markOrder[right.type]!));
  return List.unmodifiable(normalized);
}

String _escapeInlineText(String text) => text.replaceAllMapped(
      RegExp(r'[\\`*_\[\]~]'),
      (match) => '\\${match.group(0)}',
    );

String _serializeSpan(
  ComposerRichTextSpan span,
  List<ComposerRichTextMark> marks,
) {
  var value = marks.any((mark) => mark.type == ComposerRichTextMarkType.code)
      ? span.text
      : _escapeInlineText(span.text);
  final hasBold =
      marks.any((mark) => mark.type == ComposerRichTextMarkType.bold);

  for (var index = marks.length - 1; index >= 0; index -= 1) {
    final mark = marks[index];
    switch (mark.type) {
      case ComposerRichTextMarkType.bold:
        value = '**$value**';
      case ComposerRichTextMarkType.italic:
        value = hasBold ? '_${value}_' : '*$value*';
      case ComposerRichTextMarkType.strikethrough:
        value = '~~$value~~';
      case ComposerRichTextMarkType.code:
        value = '`$value`';
      case ComposerRichTextMarkType.link:
        final href = mark.href!.replaceAll(')', '%29');
        value = '[$value]($href)';
    }
  }
  return value;
}

String _serializeInline(List<ComposerRichTextSpan> content) {
  final normalized = <ComposerRichTextSpan>[];
  for (final span in content) {
    if (span.text.isEmpty) continue;
    final marks = _normalizeMarks(span.marks, span.text);
    final previous = normalized.isEmpty ? null : normalized.last;
    if (previous != null && _listEquals(previous.marks, marks)) {
      normalized[normalized.length - 1] = ComposerRichTextSpan(
        text: previous.text + span.text,
        marks: marks,
      );
    } else {
      normalized.add(ComposerRichTextSpan(text: span.text, marks: marks));
    }
  }
  return normalized.map((span) => _serializeSpan(span, span.marks)).join();
}

String _keepParagraphLinesInert(String markdown) =>
    markdown.split('\n').map((line) {
      if (RegExp(r'^ {0,3}[-+][\t ]').hasMatch(line)) {
        return line.replaceFirstMapped(
          RegExp(r'[-+]'),
          (match) => '\\${match.group(0)}',
        );
      }
      if (RegExp(r'^ {0,3}\d+[.)][\t ]').hasMatch(line)) {
        return line.replaceFirstMapped(
          RegExp(r'[.)]'),
          (match) => '\\${match.group(0)}',
        );
      }
      return line;
    }).join('\n');

String _codeFence(String text) {
  var length = 3;
  for (final match in RegExp(r'`+').allMatches(text)) {
    if (match.group(0)!.length >= length) {
      length = match.group(0)!.length + 1;
    }
  }
  return List.filled(length, '`').join();
}

String _serializeBlock(ComposerRichTextBlock block) => switch (block) {
      ComposerRichTextParagraph(:final content) =>
        _keepParagraphLinesInert(_serializeInline(content)),
      ComposerRichTextUnorderedListItem(:final content) =>
        '- ${_serializeInline(content)}',
      ComposerRichTextOrderedListItem(:final ordinal, :final content) =>
        '${ordinal >= 0 ? ordinal : 1}. ${_serializeInline(content)}',
      ComposerRichTextCodeBlock(:final text, :final language) => () {
          final fence = _codeFence(text);
          final safeLanguage =
              language?.replaceAll(RegExp(r'[\r\n]+'), ' ').trim() ?? '';
          return '$fence$safeLanguage\n$text\n$fence';
        }(),
    };

bool _sameListKind(ComposerRichTextBlock left, ComposerRichTextBlock right) =>
    (left is ComposerRichTextUnorderedListItem &&
        right is ComposerRichTextUnorderedListItem) ||
    (left is ComposerRichTextOrderedListItem &&
        right is ComposerRichTextOrderedListItem);

/// Serializes an editing document to deterministic Markdown for storage.
String richTextDocumentToCanonicalMarkdown(
  ComposerRichTextDocument document,
) {
  final markdown = StringBuffer();
  for (var index = 0; index < document.blocks.length; index += 1) {
    final block = document.blocks[index];
    if (index > 0) {
      markdown.write(
          _sameListKind(document.blocks[index - 1], block) ? '\n' : '\n\n');
    }
    markdown.write(_serializeBlock(block));
  }
  return markdown.toString();
}

bool _listEquals<T>(List<T> left, List<T> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
