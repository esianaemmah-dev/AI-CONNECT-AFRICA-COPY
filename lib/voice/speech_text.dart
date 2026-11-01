import '../ai_core/inference/sanitize_llm_response.dart';

/// Converts displayed lesson/chat text into prose for the device voice.
/// Formatting, hidden model tokens, URLs and stored resource records are not
/// speech. Mathematical content is retained without its LaTeX commands.
String speechText(String text) {
  var out = sanitizeLLMResponse(text);
  out = out.replaceAll(
    RegExp(r'```[\s\S]*?(?:```|$)|~~~[\s\S]*?(?:~~~|$)'),
    ' ',
  );
  out = out.replaceAll(
    RegExp(r'<(script|style)\b[^>]*>[\s\S]*?</\1>', caseSensitive: false),
    ' ',
  );
  out = out.replaceAll(RegExp(
    r'<\|(?:im_start|start_header_id)\|>\s*(?:system|assistant|user|analysis|final)\s*(?:<\|end_header_id\|>)?',
    caseSensitive: false), ' ');
  out = out.replaceAll(RegExp(r'<\|[^>]*\|>|\[/?INST\]|<<\/?SYS>>'), ' ');
  out = out.replaceAll(
    RegExp(r'^\s*\[(?:PDF|QUIZ|ASSIGNMENT)[^\]\n]*\].*$', multiLine: true),
    ' ',
  );
  out = out.replaceAll(RegExp(r'\[DIAGRAM:[^\]]*\]'), ' ');
  out = out.replaceAll(RegExp(r'__(?:MATH|CODE|FORMULA|LATEX)_?\d+__'), ' ');
  out = out.replaceAll(RegExp(r'⟦\d+⟧'), ' ');
  out = out.replaceAllMapped(RegExp(r'!?\[([^\]]*)\]\([^)]*\)'), (m) => m[1]!);
  out = out.replaceAll(RegExp(r'https?://[^\s<>]+|www\.[^\s<>]+'), ' ');
  out = out.replaceAll(RegExp(r'<[a-zA-Z/!][^>]*>'), ' ');
  out = out.replaceAllMapped(
    RegExp(
      r'&(#x[0-9a-f]+|#\d+|amp|lt|gt|quot|apos|nbsp);',
      caseSensitive: false,
    ),
    (m) {
      final entity = m[1]!.toLowerCase();
      if (entity.startsWith('#')) {
        final code = entity.startsWith('#x')
            ? int.tryParse(entity.substring(2), radix: 16)
            : int.tryParse(entity.substring(1));
        return code != null &&
                code > 0 &&
                code <= 0x10ffff &&
                !(code >= 0xd800 && code <= 0xdfff)
            ? String.fromCharCode(code)
            : ' ';
      }
      return const {
        'amp': '&',
        'lt': '<',
        'gt': '>',
        'quot': '"',
        'apos': "'",
        'nbsp': ' ',
      }[entity]!;
    },
  );
  out = out.replaceAll(RegExp(r'\\(?:begin|end)\s*\{[^{}]*\}'), ' ');
  // Unwrap readable LaTeX content before removing remaining command names.
  for (var i = 0; i < 4; i++) {
    out = out.replaceAllMapped(
      RegExp(r'\\(?:d?frac)\s*\{([^{}]*)\}\s*\{([^{}]*)\}'),
      (m) => '${m[1]} over ${m[2]}',
    );
    out = out.replaceAllMapped(
      RegExp(r'\\sqrt\s*\{([^{}]*)\}'),
      (m) => 'square root of ${m[1]}',
    );
    out = out.replaceAllMapped(
      RegExp(r'\\(?:text|mathrm|mathbf|operatorname)\s*\{([^{}]*)\}'),
      (m) => m[1]!,
    );
  }
  const commands = {
    'times': 'times',
    'cdot': 'times',
    'div': 'divided by',
    'pm': 'plus or minus',
    'leq': 'less than or equal to',
    'geq': 'greater than or equal to',
    'neq': 'not equal to',
    'to': 'to',
    'pi': 'pi',
  };
  out = out.replaceAllMapped(
    RegExp(r'\\([a-zA-Z]+)'),
    (m) => ' ${commands[m[1]] ?? ''} ',
  );
  out = out.replaceAll(RegExp(r'\\[()[\]{}]'), ' ');
  out = out.replaceAll(RegExp(r'\$+'), '');
  out = out.replaceAllMapped(
    RegExp(r'\^\{([^{}]*)\}|\^(\d+)'),
    (m) => ' to the power of ${m[1] ?? m[2]}',
  );
  out = out.replaceAll(RegExp(r'(?<=\d)\s*\*\s*(?=\d)'), ' times ');
  out = out.replaceAll(
    RegExp(r'^\s*(?:#{1,6}\s+|>\s*|[-*+]\s+)', multiLine: true),
    '',
  );
  out = out.replaceAll(RegExp(r'^\s*[-=*_]{3,}\s*$', multiLine: true), ' ');
  out = out.replaceAll(RegExp(r'[*_`{}\\|]'), ' ');
  return out.replaceAll(RegExp(r'\s+'), ' ')
      .replaceAllMapped(RegExp(r'\s+([.,;:!?])'), (m) => m[1]!).trim();
}
