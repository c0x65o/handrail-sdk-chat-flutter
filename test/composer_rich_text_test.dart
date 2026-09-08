import 'package:handrail_chat/core.dart';
import 'package:test/test.dart';

void main() {
  group('semantic Markdown round trips', () {
    const fixtures = <({String name, String markdown, String canonical})>[
      (
        name: 'paragraph and every inline mark',
        markdown:
            '__Bold__ and _italic_ and ~~removed~~ with [docs](https://example.test/docs) and `inline code`',
        canonical:
            '**Bold** and *italic* and ~~removed~~ with [docs](https://example.test/docs) and `inline code`',
      ),
      (
        name: 'ordinary paragraph newlines',
        markdown: 'first line\r\nsecond line',
        canonical: 'first line\nsecond line',
      ),
      (
        name: 'unordered list aliases',
        markdown: '+ first\n* second',
        canonical: '- first\n- second',
      ),
      (
        name: 'ordered list aliases and ordinals',
        markdown: '3) third\n4. fourth',
        canonical: '3. third\n4. fourth',
      ),
      (
        name: 'fenced code alias and language',
        markdown: '~~~ts\nconst answer = 42;\n~~~',
        canonical: '```ts\nconst answer = 42;\n```',
      ),
      (
        name: 'mixed blocks',
        markdown: 'A paragraph\n\n- bullet\n\n7. item\n\n```\ncode\n```',
        canonical: 'A paragraph\n\n- bullet\n\n7. item\n\n```\ncode\n```',
      ),
    ];

    for (final fixture in fixtures) {
      test(fixture.name, () {
        final document = composerMarkdownToRichTextDocument(fixture.markdown);
        final canonical = richTextDocumentToCanonicalMarkdown(document);

        expect(canonical, fixture.canonical);
        expect(composerMarkdownToRichTextDocument(canonical), document);
      });
    }
  });

  test('model is structurally bounded and deeply immutable', () {
    final inputMarks = <ComposerRichTextMark>[
      const ComposerRichTextMark.bold(),
    ];
    final inputSpans = <ComposerRichTextSpan>[
      ComposerRichTextSpan(text: 'bold', marks: inputMarks),
    ];
    final inputBlocks = <ComposerRichTextBlock>[
      ComposerRichTextParagraph(content: inputSpans),
    ];
    final document = ComposerRichTextDocument(blocks: inputBlocks);

    inputMarks.clear();
    inputSpans.clear();
    inputBlocks.clear();

    final paragraph = document.blocks.single as ComposerRichTextParagraph;
    expect(paragraph.content.single.text, 'bold');
    expect(paragraph.content.single.marks, [const ComposerRichTextMark.bold()]);
    expect(
      () => document.blocks.add(ComposerRichTextParagraph()),
      throwsUnsupportedError,
    );
    expect(
      () => paragraph.content.add(ComposerRichTextSpan(text: 'other')),
      throwsUnsupportedError,
    );
    expect(
      () => paragraph.content.single.marks.add(
        const ComposerRichTextMark.italic(),
      ),
      throwsUnsupportedError,
    );
  });

  test('escaped markers and malformed input stay editable literal text', () {
    const escaped =
        r'\*literal\* and \[not a link\] and \`not code\` and \~tilde\~';
    final escapedDocument = composerMarkdownToRichTextDocument(escaped);
    final escapedParagraph =
        escapedDocument.blocks.single as ComposerRichTextParagraph;
    expect(
      escapedParagraph.content.single,
      ComposerRichTextSpan(
        text: '*literal* and [not a link] and `not code` and ~tilde~',
      ),
    );
    expect(richTextDocumentToCanonicalMarkdown(escapedDocument), escaped);

    const malformed = 'before **open and [broken](https://example.test';
    final malformedDocument = composerMarkdownToRichTextDocument(malformed);
    final malformedParagraph =
        malformedDocument.blocks.single as ComposerRichTextParagraph;
    expect(malformedParagraph.content.single.text, malformed);
    expect(malformedParagraph.content.single.marks, isEmpty);
    expect(
      richTextDocumentToCanonicalMarkdown(malformedDocument),
      r'before \*\*open and \[broken\](https://example.test',
    );

    const unclosedFence = '```ts\nstill editable';
    final fenceDocument = composerMarkdownToRichTextDocument(unclosedFence);
    expect(fenceDocument.blocks.single, isA<ComposerRichTextParagraph>());
    expect(
      _plainText(fenceDocument.blocks.single),
      unclosedFence,
    );
    expect(
      richTextDocumentToCanonicalMarkdown(fenceDocument),
      r'\`\`\`ts' '\nstill editable',
    );
  });

  test('unsupported Markdown constructs stay editable plain text', () {
    const unsupported =
        '# heading\n> quote\n![alt](https://example.test/image.png)';
    final document = composerMarkdownToRichTextDocument(unsupported);
    final paragraph = document.blocks.single as ComposerRichTextParagraph;

    expect(_plainText(paragraph), unsupported);
    expect(paragraph.content.expand((span) => span.marks), isEmpty);
    expect(
      richTextDocumentToCanonicalMarkdown(document),
      r'# heading'
      '\n'
      r'> quote'
      '\n'
      r'!\[alt\](https://example.test/image.png)',
    );
  });

  test('mention display text survives marked and unmarked round trips', () {
    const markdown = 'Hello @Display Name and **@Release Captain**';
    final document = composerMarkdownToRichTextDocument(markdown);

    expect(
      _plainText(document.blocks.single),
      'Hello @Display Name and @Release Captain',
    );
    expect(richTextDocumentToCanonicalMarkdown(document), markdown);
  });

  test('unsafe links remain inert and safe destinations are normalized', () {
    const unsafeDestinations = <String>[
      'javascript:alert(1)',
      'data:text/html,payload',
      'java\u0000script:alert(1)',
    ];
    for (final destination in unsafeDestinations) {
      final markdown = '[label]($destination)';
      final document = composerMarkdownToRichTextDocument(markdown);
      final paragraph = document.blocks.single as ComposerRichTextParagraph;

      expect(_plainText(paragraph), markdown);
      expect(paragraph.content.expand((span) => span.marks), isEmpty);
      expect(
        _plainText(composerMarkdownToRichTextDocument(
          richTextDocumentToCanonicalMarkdown(document),
        ).blocks.single),
        markdown,
      );
    }

    final controlledSafeLink = composerMarkdownToRichTextDocument(
      '[mail](ma\u0000ilto:person@example.test)',
    );
    final span = (controlledSafeLink.blocks.single as ComposerRichTextParagraph)
        .content
        .single;
    expect(
      span.marks,
      [const ComposerRichTextMark.link('mailto:person@example.test')],
    );
    expect(
      richTextDocumentToCanonicalMarkdown(controlledSafeLink),
      '[mail](mailto:person@example.test)',
    );
    expect(
      sanitizeComposerMarkdownLink('https://example.test\u007f/path'),
      'https://example.test/path',
    );
    expect(sanitizeComposerMarkdownLink('ftp://example.test/file'), isNull);
  });

  test('canonical output normalizes duplicate and reordered marks', () {
    final document = ComposerRichTextDocument(blocks: [
      ComposerRichTextParagraph(content: [
        ComposerRichTextSpan(
          text: 'formatted',
          marks: const [
            ComposerRichTextMark.code(),
            ComposerRichTextMark.italic(),
            ComposerRichTextMark.bold(),
            ComposerRichTextMark.bold(),
          ],
        ),
        ComposerRichTextSpan(text: ' literal * marker'),
      ]),
    ]);
    const canonical = r'**_`formatted`_** literal \* marker';

    expect(richTextDocumentToCanonicalMarkdown(document), canonical);
    expect(
      richTextDocumentToCanonicalMarkdown(
        composerMarkdownToRichTextDocument(canonical),
      ),
      canonical,
    );
  });

  test('unsafe constructed link marks never serialize as active links', () {
    final document = ComposerRichTextDocument(blocks: [
      ComposerRichTextParagraph(content: [
        ComposerRichTextSpan(
          text: 'label',
          marks: const [ComposerRichTextMark.link('javascript:alert(1)')],
        ),
      ]),
    ]);

    expect(richTextDocumentToCanonicalMarkdown(document), 'label');
  });

  test('fenced code chooses a deterministic delimiter longer than content', () {
    final document = ComposerRichTextDocument(blocks: const [
      ComposerRichTextCodeBlock(text: 'before ``` after'),
    ]);
    const canonical = '````\nbefore ``` after\n````';

    expect(richTextDocumentToCanonicalMarkdown(document), canonical);
    expect(composerMarkdownToRichTextDocument(canonical), document);
  });

  test('paragraph lines that look like list items remain paragraphs', () {
    final document = ComposerRichTextDocument(blocks: [
      ComposerRichTextParagraph(content: [
        ComposerRichTextSpan(text: '- literal\n2) also literal'),
      ]),
    ]);
    const canonical = r'\- literal' '\n' r'2\) also literal';

    expect(richTextDocumentToCanonicalMarkdown(document), canonical);
    final reparsed = composerMarkdownToRichTextDocument(canonical);
    expect(reparsed.blocks.single, isA<ComposerRichTextParagraph>());
    expect(_plainText(reparsed.blocks.single), '- literal\n2) also literal');
  });
}

String _plainText(ComposerRichTextBlock block) => switch (block) {
      ComposerRichTextParagraph(:final content) ||
      ComposerRichTextUnorderedListItem(:final content) ||
      ComposerRichTextOrderedListItem(:final content) =>
        content.map((span) => span.text).join(),
      ComposerRichTextCodeBlock(:final text) => text,
    };
