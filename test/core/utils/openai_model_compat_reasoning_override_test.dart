import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/utils/openai_model_compat.dart';

void main() {
  group('reasoningEffortsOverride parsing', () {
    test('returns null when the model carries no override', () {
      expect(reasoningEffortsOverride(null), isNull);
      expect(reasoningEffortsOverride(<String, dynamic>{}), isNull);
      expect(reasoningEffortsOverride(<String, dynamic>{'name': 'x'}), isNull);
      expect(
        reasoningEffortsOverride(<String, dynamic>{'reasoningEfforts': 'low'}),
        isNull,
      );
    });

    test('drops unknown values and returns canonical order', () {
      final efforts = reasoningEffortsOverride(<String, dynamic>{
        'reasoningEfforts': <String>['max', 'bogus', 'low', 'HIGH', ' Xhigh '],
      });
      expect(efforts, <String>['low', 'high', 'xhigh', 'max']);
    });

    test('keeps an explicit empty list as a no-effort override', () {
      final efforts = reasoningEffortsOverride(<String, dynamic>{
        'reasoningEfforts': <String>[],
      });
      expect(efforts, <String>[]);

      final junkOnly = reasoningEffortsOverride(<String, dynamic>{
        'reasoningEfforts': <String>['nonsense'],
      });
      expect(junkOnly, <String>[]);

      final snakeCase = reasoningEffortsOverride(<String, dynamic>{
        'reasoning_efforts': <String>['high'],
      });
      expect(snakeCase, <String>['high']);
    });
  });

  group('reasoningSupportFromOverride', () {
    test('null efforts keeps the built-in registry path', () {
      expect(reasoningSupportFromOverride(null), isNull);
    });

    test('empty efforts builds a no-parameter support', () {
      final support = reasoningSupportFromOverride(const <String>[]);
      expect(support, isNotNull);
      expect(support!.effortParameterSupported, isFalse);
      expect(support.supportedEfforts, isEmpty);
    });

    test('non-empty efforts builds a synthetic support', () {
      final support = reasoningSupportFromOverride(const <String>[
        'low',
        'high',
        'xhigh',
      ]);
      expect(support!.supportsXhigh, isTrue);
      expect(support.supportsMax, isFalse);
    });
  });

  group('openAINormalizeReasoningEffort with override support', () {
    const nicheModel = 'my-niche-reasoner';

    test('without override, unmatched models clamp xhigh/max to high', () {
      expect(openAINormalizeReasoningEffort('xhigh', nicheModel), 'high');
      expect(openAINormalizeReasoningEffort('max', nicheModel), 'high');
    });

    test('override vocabulary lets xhigh pass through verbatim', () {
      final support = reasoningSupportFromOverride(const <String>[
        'low',
        'medium',
        'high',
        'xhigh',
      ]);
      expect(
        openAINormalizeReasoningEffort(
          'xhigh',
          nicheModel,
          overrideSupport: support,
        ),
        'xhigh',
      );
      // max without 'max' in the vocabulary follows the existing preference
      // ladder: it upgrades to the closest supported level above it.
      expect(
        openAINormalizeReasoningEffort(
          'max',
          nicheModel,
          overrideSupport: support,
        ),
        'xhigh',
      );
    });

    test('override vocabulary clamps out-of-vocabulary efforts', () {
      final support = reasoningSupportFromOverride(const <String>[
        'low',
        'high',
      ]);
      expect(
        openAINormalizeReasoningEffort(
          'medium',
          nicheModel,
          overrideSupport: support,
        ),
        'high',
      );
    });

    test('empty vocabulary disables the effort parameter', () {
      final support = reasoningSupportFromOverride(const <String>[]);
      expect(
        openAINormalizeReasoningEffort(
          'high',
          nicheModel,
          overrideSupport: support,
        ),
        'auto',
      );
      expect(
        openAINormalizeReasoningEffort(
          'off',
          nicheModel,
          overrideSupport: support,
        ),
        'auto',
      );
    });

    test('override replaces the registry for matched models', () {
      // gpt-5.2 registry: none/low/medium/high/xhigh + samplingRequiresNone.
      expect(
        openAINormalizeReasoningEffort(
          'xhigh',
          'gpt-5.2',
          overrideSupport: reasoningSupportFromOverride(const <String>[
            'low',
            'high',
          ]),
        ),
        'high',
      );
      // Without the override the registry keeps xhigh.
      expect(openAINormalizeReasoningEffort('xhigh', 'gpt-5.2'), 'xhigh');
    });
  });

  group('openAISupportsXhigh/MaxReasoning with override support', () {
    test('unmatched model without override stays capped', () {
      expect(openAISupportsXhighReasoning('my-niche-reasoner'), isFalse);
      expect(openAISupportsMaxReasoning('my-niche-reasoner'), isFalse);
    });

    test('override vocabulary unlocks the stops', () {
      final support = reasoningSupportFromOverride(kReasoningEffortVocabulary);
      expect(
        openAISupportsXhighReasoning(
          'my-niche-reasoner',
          overrideSupport: support,
        ),
        isTrue,
      );
      expect(
        openAISupportsMaxReasoning(
          'my-niche-reasoner',
          overrideSupport: support,
        ),
        isTrue,
      );
    });
  });
}
