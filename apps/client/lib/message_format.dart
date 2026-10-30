// Already supplied by Matrix; keep parsing and escaping consistent with the SDK.
import 'package:markdown/markdown.dart' as md;

class _StrikeSyntax extends md.DelimiterSyntax {
  _StrikeSyntax()
    : super(
        '~+',
        requiresDelimiterRun: true,
        tags: [md.DelimiterTag('del', 2)],
      );
}

/// Only enabled inline styles are interpreted. HTML remains ordinary text.
List<md.Node> parseMessageFormat(String text) => md.Document(
  inlineSyntaxes: [md.EscapeSyntax(), _StrikeSyntax()],
  withDefaultInlineSyntaxes: false,
  withDefaultBlockSyntaxes: false,
  encodeHtml: false,
).parseInline(text);
