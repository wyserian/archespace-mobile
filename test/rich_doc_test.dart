import 'package:flutter_test/flutter_test.dart';

import 'package:archespace_mobile/src/features/items/domain/rich_doc.dart';
import 'package:archespace_mobile/src/features/items/domain/space_item.dart';
import 'package:archespace_mobile/src/shared/export/pdf_exporter.dart';

Map<String, dynamic> _text(String t, [List<String> marks = const []]) => {
  'type': 'text',
  'text': t,
  if (marks.isNotEmpty)
    'marks': [
      for (final m in marks) {'type': m},
    ],
};

Map<String, dynamic> _p(List<Map<String, dynamic>> inline) => {
  'type': 'paragraph',
  'content': inline,
};

Map<String, dynamic> _cell(String type, String t) => {
  'type': type,
  'content': [
    _p([_text(t)]),
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final longText = List.filled(300, 'A long line that keeps going.').join(' ');

  // A document with every block the editor can make (as Tiptap saves it).
  final doc = {
    'type': 'doc',
    'content': [
      {
        'type': 'heading',
        'attrs': {'level': 1},
        'content': [_text('Title')],
      },
      _p([
        _text('Some '),
        _text('bold', ['bold']),
        _text(' and '),
        _text('under', ['underline', 'italic']),
      ]),
      {
        'type': 'paragraph',
        'attrs': {'textAlign': 'center'},
        'content': [
          _text('mark', ['highlight']),
          _text('2', ['superscript']),
          _text('x', ['subscript']),
        ],
      },
      {
        'type': 'bulletList',
        'content': [
          {
            'type': 'listItem',
            'content': [
              _p([_text('a')]),
              {
                'type': 'orderedList',
                'content': [
                  {
                    'type': 'listItem',
                    'content': [
                      _p([_text('nested')]),
                    ],
                  },
                ],
              },
            ],
          },
          {
            'type': 'listItem',
            'content': [
              _p([_text(longText)]),
            ],
          },
        ],
      },
      {
        'type': 'taskList',
        'content': [
          {
            'type': 'taskItem',
            'attrs': {'checked': true},
            'content': [
              _p([_text('done')]),
            ],
          },
        ],
      },
      {
        'type': 'blockquote',
        'content': [
          _p([_text('quote')]),
        ],
      },
      {
        'type': 'codeBlock',
        'content': [_text('code()')],
      },
      {'type': 'horizontalRule'},
      {
        'type': 'table',
        'content': [
          {
            'type': 'tableRow',
            'content': [_cell('tableHeader', 'A'), _cell('tableHeader', 'B')],
          },
          {
            'type': 'tableRow',
            'content': [_cell('tableCell', '1'), _cell('tableCell', '2')],
          },
        ],
      },
    ],
  };

  test('reads plain text: a line per block, tabs between cells', () {
    final text = richContentPlainText('richtext', {'doc': doc});
    expect(text, startsWith('Title\nSome bold and under\nmark2x\na\nnested\n'));
    expect(text, endsWith('done\nquote\ncode()\nA\tB\n1\t2'));
  });

  test('reads a very long document quickly', () {
    final long = {
      'type': 'doc',
      'content': [
        for (var i = 0; i < 20000; i++)
          {
            'type': 'paragraph',
            'content': [
              {'type': 'text', 'text': 'Line $i of a long note'},
            ],
          },
      ],
    };
    final watch = Stopwatch()..start();
    final text = richContentPlainText('richtext', {'doc': long});
    watch.stop();
    expect(text.split('\n'), hasLength(20000));
    // Linear time: copying the text so far at every line break made this
    // take minutes.
    expect(watch.elapsedMilliseconds, lessThan(1000));
  });

  test('tells the new format from the older ones', () {
    expect(isRichDoc({'doc': doc}), isTrue);
    expect(isRichDoc({'html': '<b>x</b>'}), isFalse);
    expect(richContentPlainText('richtext', {'html': '<b>x</b> y'}), 'x y');
    expect(richContentPlainText('markdown', {'text': '# md'}), '# md');
  });

  test('exports a rich text item (including over-long text) to PDF', () async {
    final bytes = await PdfExporter.buildItem(
      SpaceItem(
        id: 'r',
        type: 'richtext',
        title: 'Rich',
        content: {'doc': doc},
        pinned: false,
      ),
    );
    expect(bytes, isNotEmpty);
  });
}
