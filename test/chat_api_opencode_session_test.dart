import 'dart:convert';

import 'package:Cuplivo/core/models/auto_retry_options.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/api/chat_api_service.dart';
import 'package:Cuplivo/core/services/api/provider_request_headers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

class _ScriptedReply {
  const _ScriptedReply(
    this.status,
    this.body, {
    this.contentType = 'application/json',
  });

  final int status;
  final String body;
  final String contentType;
}

/// Fake [http.BaseClient] injected via [ChatApiService.debugClientFactory]:
/// records every request's path + session header and answers from a scripted
/// queue, so routing / header merge / retry / tool-follow-up logic all run
/// against the real provider code without sockets.
///
/// The same client instance is returned for every factory call: the factory is
/// invoked per retry attempt, and one generation must reuse one queue.
class _RecordingClient extends http.BaseClient {
  _RecordingClient(this._replies, this._log);

  final List<_ScriptedReply> _replies;
  final List<({String path, String? session})> _log;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    String? session;
    request.headers.forEach((key, value) {
      if (key.toLowerCase() == 'x-opencode-session') session = value;
    });
    _log.add((path: request.url.path, session: session));
    final reply = _replies.isNotEmpty ? _replies.removeAt(0) : null;
    final r = reply ?? const _ScriptedReply(200, '{}');
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(r.body)),
      r.status,
      headers: {'content-type': r.contentType},
    );
  }
}

ProviderConfig _config({
  String host = 'opencode.ai',
  ProviderKind kind = ProviderKind.openai,
  bool responses = false,
}) => ProviderConfig(
  id: 'Custom',
  name: 'Custom',
  enabled: true,
  apiKey: 'test-key',
  baseUrl: 'http://$host/zen/go/v1',
  providerType: kind,
  useResponseApi: responses,
);

const String _replyBody =
    '{"choices":[{"message":{"role":"assistant","content":"ok"}}],'
    '"content":[{"type":"text","text":"ok"}],'
    '"output":[{"type":"message","role":"assistant","content":['
    '{"type":"output_text","text":"ok"}]}]}';

final _uuidRe = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

void main() {
  tearDown(() {
    ChatApiService.debugClientFactory = null;
  });

  test('automatic session header is limited to the exact official host', () {
    for (final host in [
      'example.com',
      'opencode.ai.example.com',
      'fakeopencode.ai',
    ]) {
      expect(
        providerSessionHeaders(_config(host: host), conversationId: 'chat'),
        isNull,
      );
    }
    expect(
      providerSessionHeaders(
        _config(host: 'OPENCODE.AI'),
        conversationId: 'chat',
      ),
      {'x-opencode-session': 'chat'},
    );
  });

  test('session value: conversation id, trimmed; fresh UUID without one', () {
    expect(providerSessionHeaders(_config(), conversationId: '  chat  '), {
      'x-opencode-session': 'chat',
    });
    final noId = providerSessionHeaders(_config());
    expect(noId?.values.single, matches(_uuidRe));
    final blank = providerSessionHeaders(_config(), conversationId: '   ');
    expect(blank?.values.single, matches(_uuidRe));
    expect(blank?.values.single, isNot(noId?.values.single));
  });

  test('explicit user session header overrides the auto value', () {
    expect(
      providerSessionHeaders(
        _config().copyWith(
          customHeaders: const [
            {'name': 'X-OPENCODE-SESSION', 'value': 'manual'},
          ],
        ),
        conversationId: 'chat-a',
      ),
      isNull, // user header wins: no auto value is injected
    );
    expect(
      providerSessionHeaders(
        _config(),
        conversationId: 'chat-a',
        extraHeaders: const {'x-opencode-session': 'extra'},
      ),
      {'x-opencode-session': 'extra'},
    );
    expect(
      providerSessionHeaders(
        _config(),
        conversationId: 'chat-a',
        extraHeaders: const {'X-Other': '1'},
      ),
      {'x-opencode-session': 'chat-a', 'X-Other': '1'},
    );
  });

  test('per-model override session header suppresses the auto value', () {
    final config = _config().copyWith(
      modelOverrides: {
        'test-model': {
          'headers': [
            {'name': 'x-opencode-session', 'value': 'manual-model'},
          ],
        },
      },
    );
    expect(
      providerSessionHeaders(
        config,
        conversationId: 'chat-a',
        modelId: 'test-model',
      ),
      isNull,
    );
    // Without the model id (no per-model context) the auto value is injected.
    expect(providerSessionHeaders(config, conversationId: 'chat-a'), {
      'x-opencode-session': 'chat-a',
    });
  });

  test('mixed-case extraHeaders session key wins and never duplicates', () {
    final userProvided = const {'X-OpenCode-Session': 'mixed'};
    expect(
      providerSessionHeaders(
        _config(),
        conversationId: 'chat-a',
        extraHeaders: userProvided,
      ),
      userProvided,
    );
  });

  group('requests to opencode.ai carry the header across routes', () {
    for (final route in [
      (kind: ProviderKind.openai, responses: false, path: '/chat/completions'),
      (kind: ProviderKind.openai, responses: true, path: '/responses'),
      (kind: ProviderKind.claude, responses: false, path: '/messages'),
    ]) {
      test(
        '${route.path} uses stable conversation IDs, distinct task IDs',
        () async {
          final log = <({String path, String? session})>[];
          final client = _RecordingClient(
            List.generate(6, (_) => const _ScriptedReply(200, _replyBody)),
            log,
          );
          ChatApiService.debugClientFactory = (cfg, {proxy}) => client;

          for (final id in ['chat-a', 'chat-a', 'chat-b']) {
            final result = await ChatApiService.generateText(
              config: _config(kind: route.kind, responses: route.responses),
              modelId: 'test-model',
              prompt: 'hello',
              conversationId: id,
            );
            expect(result, 'ok');
          }
          for (var i = 0; i < 2; i++) {
            await ChatApiService.generateText(
              config: _config(kind: route.kind, responses: route.responses),
              modelId: 'test-model',
              prompt: 'hello',
            );
          }
          await ChatApiService.generateText(
            config: _config(kind: route.kind, responses: route.responses),
            modelId: 'test-model',
            prompt: 'hello',
            conversationId: 'chat-a',
          );

          expect(log, hasLength(6));
          expect(log.take(3).map((e) => e.session).toList(), [
            'chat-a',
            'chat-a',
            'chat-b',
          ]);
          expect(log[3].session, matches(_uuidRe));
          expect(log[4].session, matches(_uuidRe));
          expect(log[3].session, isNot(log[4].session));
          expect(log[5].session, 'chat-a');
          expect(log.map((e) => e.path), everyElement(endsWith(route.path)));
        },
      );

      test('${route.path} user custom and extra headers win', () async {
        final log = <({String path, String? session})>[];
        final client = _RecordingClient(
          List.generate(2, (_) => const _ScriptedReply(200, _replyBody)),
          log,
        );
        ChatApiService.debugClientFactory = (cfg, {proxy}) => client;

        final config = _config(kind: route.kind, responses: route.responses);
        await ChatApiService.generateText(
          config: config.copyWith(
            customHeaders: const [
              {'name': 'X-OPENCODE-SESSION', 'value': 'manual'},
            ],
          ),
          modelId: 'test-model',
          prompt: 'hello',
          conversationId: 'chat-a',
        );
        await ChatApiService.generateText(
          config: config,
          modelId: 'test-model',
          prompt: 'hello',
          conversationId: 'chat-a',
          extraHeaders: const {'x-opencode-session': 'extra'},
        );

        expect(log[0].session, 'manual');
        expect(log[1].session, 'extra');
      });

      test('${route.path} per-model override session header wins', () async {
        final log = <({String path, String? session})>[];
        final client = _RecordingClient(
          List.generate(1, (_) => const _ScriptedReply(200, _replyBody)),
          log,
        );
        ChatApiService.debugClientFactory = (cfg, {proxy}) => client;

        await ChatApiService.generateText(
          config: _config(kind: route.kind, responses: route.responses)
              .copyWith(
                modelOverrides: {
                  'test-model': {
                    'headers': [
                      {'name': 'x-opencode-session', 'value': 'manual-model'},
                    ],
                  },
                },
              ),
          modelId: 'test-model',
          prompt: 'hello',
          conversationId: 'chat-a',
        );

        expect(log.single.session, 'manual-model');
      });
    }

    test('non-opencode hosts never get the auto header', () async {
      final log = <({String path, String? session})>[];
      final client = _RecordingClient(
        List.generate(2, (_) => const _ScriptedReply(200, _replyBody)),
        log,
      );
      ChatApiService.debugClientFactory = (cfg, {proxy}) => client;

      await ChatApiService.generateText(
        config: _config(host: 'example.com'),
        modelId: 'test-model',
        prompt: 'hello',
        conversationId: 'chat-a',
      );
      await ChatApiService.generateText(
        config: _config(host: 'fakeopencode.ai'),
        modelId: 'test-model',
        prompt: 'hello',
        conversationId: 'chat-a',
      );
      expect(log, everyElement((e) => e.session == null));
    });
  });

  for (final conversationId in ['chat-a', null]) {
    test(
      'stream: 429 retry and tool follow-up reuse session $conversationId',
      () async {
        final log = <({String path, String? session})>[];
        var toolCalls = 0;
        const toolEvent =
            '{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,'
            '"id":"call_1","type":"function","function":{"name":"get_time",'
            '"arguments":"{}"}}]}}]}';
        const textEvent = '{"choices":[{"index":0,"delta":{"content":"ok"}}]}';
        String sse(String event) => 'data: $event\n\ndata: [DONE]\n\n';
        final client = _RecordingClient([
          const _ScriptedReply(429, 'retry', contentType: 'text/plain'),
          _ScriptedReply(200, sse(toolEvent), contentType: 'text/event-stream'),
          _ScriptedReply(200, sse(textEvent), contentType: 'text/event-stream'),
        ], log);
        ChatApiService.debugClientFactory = (cfg, {proxy}) => client;

        final chunks = await ChatApiService.sendMessageStream(
          config: _config(),
          modelId: 'test-model',
          conversationId: conversationId,
          messages: const [
            {'role': 'user', 'content': 'hello'},
          ],
          tools: const [
            {
              'type': 'function',
              'function': {
                'name': 'get_time',
                'parameters': {
                  'type': 'object',
                  'properties': <String, dynamic>{},
                },
              },
            },
          ],
          onToolCall: (name, args, {toolCallId}) async {
            toolCalls++;
            return '12:34';
          },
          retryOverride: AutoRetryOptions(
            enabled: true,
            maxRetries: 2,
            initialDelayMs: 0,
            multiplier: 1,
            maxDelayMs: 0,
            jitter: false,
            retryOnNetworkError: true,
            retryStatusCodes: const {429},
            retryKeywords: const [],
            stopKeywords: const [],
          ),
        ).toList();

        expect(log, hasLength(3));
        expect(log.first.session, isNotNull);
        expect(
          log.map((e) => e.session).toList(),
          everyElement(conversationId ?? log.first.session),
        );
        expect(toolCalls, 1);
        expect(
          chunks
              .where((c) => c.content.isNotEmpty)
              .map((c) => c.content)
              .join(),
          'ok',
        );
        expect(chunks.any((c) => c.retryPending != null), isTrue);
      },
    );
  }
}
