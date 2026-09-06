import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/home/utils/conversation_model_binding.dart';
import 'package:Cuplivo/features/home/utils/model_display_helper.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resolveConversationModelWriteTarget (ADR-0055)', () {
    test('toggle on writes the conversation binding (bound or unbound)', () {
      final bound = Conversation(
        title: 'C',
        chatModelProvider: 'OpenAI',
        chatModelId: 'gpt-4o',
      );
      expect(
        resolveConversationModelWriteTarget(
          conversationModelIndependent: true,
          conversation: bound,
        ),
        ConversationModelWriteTarget.conversationBinding,
      );
      expect(
        resolveConversationModelWriteTarget(
          conversationModelIndependent: true,
          conversation: Conversation(title: 'C'),
        ),
        ConversationModelWriteTarget.conversationBinding,
      );
    });

    test('toggle off writes the assistant even when a binding exists', () {
      final bound = Conversation(
        title: 'C',
        chatModelProvider: 'OpenAI',
        chatModelId: 'gpt-4o',
      );
      expect(
        resolveConversationModelWriteTarget(
          conversationModelIndependent: false,
          conversation: bound,
        ),
        ConversationModelWriteTarget.assistant,
      );
    });

    test(
      'unbound conversation with toggle off keeps writing the assistant',
      () {
        final convo = Conversation(title: 'C');
        expect(
          resolveConversationModelWriteTarget(
            conversationModelIndependent: false,
            conversation: convo,
          ),
          ConversationModelWriteTarget.assistant,
        );
      },
    );

    test('no conversation never targets the binding', () {
      expect(
        resolveConversationModelWriteTarget(
          conversationModelIndependent: true,
          conversation: null,
        ),
        ConversationModelWriteTarget.assistant,
      );
    });

    test(
      'conversationModelBindingActive is false for unbound and partial pairs',
      () {
        expect(
          conversationModelBindingActive(Conversation(title: 'C')),
          isFalse,
        );
        expect(
          conversationModelBindingActive(
            Conversation(title: 'C', chatModelId: 'm1'),
          ),
          isFalse,
          reason: 'provider without model is an invalid half-pair',
        );
        expect(
          conversationModelBindingActive(
            Conversation(title: 'C', chatModelProvider: 'OpenAI'),
          ),
          isFalse,
          reason: 'model without provider is an invalid half-pair',
        );
        expect(
          conversationModelBindingActive(
            Conversation(title: 'C', chatModelProvider: 'G', chatModelId: 'm'),
          ),
          isTrue,
        );
        expect(conversationModelBindingActive(null), isFalse);
      },
    );
  });

  group('resolveChatModel chain (ADR-0055 toggle-aware)', () {
    var businessPrefs = BusinessPreferences.memoryForTests(const {
      'selected_model_v1': 'DeepSeek::deepseek-v4-flash',
    });

    test(
      'toggle on: conversation binding wins over assistant and global',
      () async {
        final settings = SettingsProvider(preferences: businessPrefs);
        await _waitUntil(() => settings.currentModelId != null);
        final assistant = Assistant(
          id: 'a1',
          name: 'Alpha',
          chatModelProvider: 'Claude',
          chatModelId: 'claude-4',
        );
        final convo = Conversation(
          title: 'C',
          chatModelProvider: 'Gemini',
          chatModelId: 'gemini-3',
        );
        final r = resolveChatModel(
          settings,
          assistant,
          convo,
          conversationModelIndependent: true,
        );
        expect(r.providerKey, 'Gemini');
        expect(r.modelId, 'gemini-3');
      },
    );

    test(
      'toggle off ignores the stored binding and follows the assistant',
      () async {
        final settings = SettingsProvider(preferences: businessPrefs);
        await _waitUntil(() => settings.currentModelId != null);
        final assistant = Assistant(
          id: 'a1',
          name: 'Alpha',
          chatModelProvider: 'Claude',
          chatModelId: 'claude-4',
        );
        final convo = Conversation(
          title: 'C',
          chatModelProvider: 'Gemini',
          chatModelId: 'gemini-3',
        );
        final r = resolveChatModel(
          settings,
          assistant,
          convo,
          conversationModelIndependent: false,
        );
        expect(r.providerKey, 'Claude');
        expect(r.modelId, 'claude-4');
      },
    );

    test(
      'toggle on: unbound conversation follows the assistant binding',
      () async {
        final settings = SettingsProvider(preferences: businessPrefs);
        await _waitUntil(() => settings.currentModelId != null);
        final assistant = Assistant(
          id: 'a1',
          name: 'Alpha',
          chatModelProvider: 'Claude',
          chatModelId: 'claude-4',
        );
        final r = resolveChatModel(
          settings,
          assistant,
          Conversation(title: 'C'),
          conversationModelIndependent: true,
        );
        expect(r.providerKey, 'Claude');
        expect(r.modelId, 'claude-4');
      },
    );

    test('no assistant falls back to the global default', () async {
      final settings = SettingsProvider(preferences: businessPrefs);
      await _waitUntil(() => settings.currentModelId != null);
      final r = resolveChatModel(
        settings,
        null,
        Conversation(title: 'C'),
        conversationModelIndependent: true,
      );
      expect(r.providerKey, 'DeepSeek');
      expect(r.modelId, 'deepseek-v4-flash');
    });

    test(
      'uses the seeded default when never persisted (one-time seed)',
      () async {
        final nonePrefs = BusinessPreferences.memoryForTests(const {});
        final settings = SettingsProvider(preferences: nonePrefs);
        await _waitUntil(() => settings.currentModelId != null);
        final r = resolveChatModel(
          settings,
          null,
          Conversation(title: 'C'),
          conversationModelIndependent: true,
        );
        expect(r.providerKey, 'DeepSeek');
        expect(r.modelId, 'deepseek-v4-flash');
      },
    );
  });

  group('Conversation model binding atomicity and round-trip', () {
    test('keeps the binding and tolerates its absence (old backups)', () {
      final convo = Conversation(
        title: 'C',
        chatModelProvider: 'OpenAI',
        chatModelId: 'gpt-4o',
      );
      final revived = Conversation.fromJson(convo.toJson());
      expect(revived.chatModelProvider, 'OpenAI');
      expect(revived.chatModelId, 'gpt-4o');

      final legacy = Conversation.fromJson({
        'id': 'x',
        'title': 'X',
        'createdAt': DateTime(2026, 1, 1).toIso8601String(),
        'updatedAt': DateTime(2026, 1, 1).toIso8601String(),
      });
      expect(legacy.chatModelProvider, isNull);
      expect(legacy.chatModelId, isNull);
    });

    test('json with provider only or model only is normalized to unbound', () {
      final providerOnly = {
        'id': 'x',
        'title': 'X',
        'createdAt': DateTime(2026, 1, 1).toIso8601String(),
        'updatedAt': DateTime(2026, 1, 1).toIso8601String(),
        'chatModelProvider': 'Gemini',
      };
      final revivedProvider = Conversation.fromJson(providerOnly);
      expect(revivedProvider.chatModelProvider, isNull);
      expect(revivedProvider.chatModelId, isNull);

      final modelOnly = {
        ...providerOnly,
        'chatModelProvider': null,
        'chatModelId': 'gemini-3',
      };
      final revivedModel = Conversation.fromJson(modelOnly);
      expect(revivedModel.chatModelProvider, isNull);
      expect(revivedModel.chatModelId, isNull);
    });

    test('copyWith(clearChatModel: true) clears the binding pair', () {
      final convo = Conversation(
        title: 'C',
        chatModelProvider: 'OpenAI',
        chatModelId: 'gpt-4o',
      );
      final cleared = convo.copyWith(clearChatModel: true);
      expect(cleared.chatModelProvider, isNull);
      expect(cleared.chatModelId, isNull);
      // The no-op mirror: copyWith without a value keeps the binding.
      final kept = convo.copyWith(title: 'T2');
      expect(kept.chatModelProvider, 'OpenAI');
      expect(kept.chatModelId, 'gpt-4o');
    });
  });
}

Future<void> _waitUntil(bool Function() predicate) async {
  for (var i = 0; i < 200; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('timed out waiting for condition');
}
