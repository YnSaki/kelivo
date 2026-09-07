import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/services/api/builtin_tools.dart';

void main() {
  group('Built-in search tools', () {
    test('enables official Qwen 3.7 / 3.8 search SKUs', () {
      expect(
        BuiltInToolsHelper.isDashScopeResponsesBuiltInSearchSupportedModel(
          'qwen3.7-plus',
        ),
        isTrue,
      );
      expect(
        BuiltInToolsHelper.isDashScopeResponsesBuiltInSearchSupportedModel(
          'qwen3.7-max',
        ),
        isTrue,
      );
      expect(
        BuiltInToolsHelper.isDashScopeResponsesBuiltInSearchSupportedModel(
          'qwen3.7-max-preview',
        ),
        isTrue,
      );
      expect(
        BuiltInToolsHelper.isDashScopeResponsesBuiltInSearchSupportedModel(
          'qwen3.7-flash',
        ),
        isTrue,
      );
      expect(
        BuiltInToolsHelper.isDashScopeResponsesBuiltInSearchSupportedModel(
          'qwen3.8-max-preview',
        ),
        isTrue,
      );
      expect(
        BuiltInToolsHelper.isDashScopeResponsesBuiltInSearchSupportedModel(
          'qwen3.8-max',
        ),
        isTrue,
      );
      expect(
        BuiltInToolsHelper.isDashScopeResponsesBuiltInSearchSupportedModel(
          'qwen3.8-max-0902',
        ),
        isTrue,
      );
      expect(
        BuiltInToolsHelper.isDashScopeResponsesBuiltInSearchSupportedModel(
          'qwen3.8-flash',
        ),
        isTrue,
      );
      expect(
        BuiltInToolsHelper.isDashScopeChatBuiltInSearchSupportedModel(
          'qwen3.7-max',
        ),
        isTrue,
      );
      expect(
        BuiltInToolsHelper.isDashScopeChatBuiltInSearchSupportedModel(
          'qwen3.8-flash',
        ),
        isTrue,
      );
      expect(
        BuiltInToolsHelper.isOpenAIResponsesBuiltInSearchSupportedModel(
          'gpt-6-astra',
        ),
        isTrue,
      );
    });

    test('keeps unlisted Qwen SKUs closed', () {
      expect(
        BuiltInToolsHelper.isDashScopeResponsesBuiltInSearchSupportedModel(
          'qwen2.5-max',
        ),
        isFalse,
      );
      expect(
        BuiltInToolsHelper.isDashScopeChatBuiltInSearchSupportedModel(
          'qwen3.6-max',
        ),
        isFalse,
      );
      expect(
        BuiltInToolsHelper.isDashScopeResponsesBuiltInSearchSupportedModel(
          'qwen3.6-max',
        ),
        isFalse,
      );
    });

    test('opens text-only qwen3.8-2.4t-a95b for search', () {
      expect(
        BuiltInToolsHelper.isDashScopeChatBuiltInSearchSupportedModel(
          'qwen3.8-2.4t-a95b',
        ),
        isTrue,
      );
      expect(
        BuiltInToolsHelper.isDashScopeResponsesBuiltInSearchSupportedModel(
          'qwen3.8-2.4t-a95b',
        ),
        isTrue,
      );
    });

    test('Claude Fable 5.1 supports built-in and dynamic web search', () {
      expect(
        BuiltInToolsHelper.isClaudeBuiltInSearchSupportedModel(
          'claude-fable-5-1',
        ),
        isTrue,
      );
      expect(
        BuiltInToolsHelper.isClaudeDynamicWebSearchSupportedModel(
          'claude-fable-5-1',
        ),
        isTrue,
      );
    });
  });
}
