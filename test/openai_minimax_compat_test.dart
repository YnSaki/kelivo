import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/api/chat_api_service.dart';

ProviderConfig _minimaxConfig(
  String baseUrl, {
  String modelId = 'MiniMax-M3',
  List<String> abilities = const ['tool', 'reasoning'],
}) {
  return ProviderConfig(
    id: 'MiniMaxTest',
    enabled: true,
    name: 'MiniMaxTest',
    apiKey: 'test-key',
    baseUrl: baseUrl,
    providerType: ProviderKind.openai,
    models: const ['MiniMax-M3'],
    modelOverrides: {
      modelId: {
        'type': 'chat',
        'input': ['text'],
        'output': ['text'],
        'abilities': abilities,
      },
    },
  );
}

Future<HttpServer> _startCaptureServer(
  List<Map<String, dynamic>> requests,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    requests.add(
      jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>,
    );

    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType(
      'text',
      'event-stream',
      charset: 'utf-8',
    );
    request.response.write(
      'data: ${jsonEncode({
        'id': 'cmpl-minimax',
        'object': 'chat.completion.chunk',
        'created': 0,
        'model': 'MiniMax-M3',
        'choices': [
          {
            'index': 0,
            'delta': {'role': 'assistant', 'content': 'ok'},
            'finish_reason': 'stop',
          },
        ],
      })}\n\n',
    );
    request.response.write('data: [DONE]\n\n');
    await request.response.close();
  });
  return server;
}

void main() {
  group('MiniMax thinking control', () {
    test('MiniMax-M3 with thinking off sends thinking disabled', () async {
      final requests = <Map<String, dynamic>>[];
      final server = await _startCaptureServer(requests);
      addTearDown(() async {
        await server.close(force: true);
      });

      final baseUrl = 'http://${server.address.address}:${server.port}/v1';
      await ChatApiService.sendMessageStream(
        config: _minimaxConfig(baseUrl),
        modelId: 'MiniMax-M3',
        messages: const [
          {'role': 'user', 'content': 'hello'},
        ],
        thinkingBudget: 0,
      ).toList();

      expect(requests, hasLength(1));
      expect(requests[0]['thinking'], {'type': 'disabled'});
      expect(requests[0].containsKey('reasoning_effort'), isFalse);
    });

    test('MiniMax-M3 with thinking budget sends thinking adaptive', () async {
      final requests = <Map<String, dynamic>>[];
      final server = await _startCaptureServer(requests);
      addTearDown(() async {
        await server.close(force: true);
      });

      final baseUrl = 'http://${server.address.address}:${server.port}/v1';
      await ChatApiService.sendMessageStream(
        config: _minimaxConfig(baseUrl),
        modelId: 'MiniMax-M3',
        messages: const [
          {'role': 'user', 'content': 'hello'},
        ],
        thinkingBudget: 1024,
      ).toList();

      expect(requests, hasLength(1));
      expect(requests[0]['thinking'], {'type': 'adaptive'});
      expect(requests[0].containsKey('reasoning_effort'), isFalse);
    });

    test('non-reasoning MiniMax model gets no thinking key', () async {
      final requests = <Map<String, dynamic>>[];
      final server = await _startCaptureServer(requests);
      addTearDown(() async {
        await server.close(force: true);
      });

      final baseUrl = 'http://${server.address.address}:${server.port}/v1';
      await ChatApiService.sendMessageStream(
        config: _minimaxConfig(
          baseUrl,
          modelId: 'MiniMax-Text-01',
          abilities: const ['tool'],
        ),
        modelId: 'MiniMax-Text-01',
        messages: const [
          {'role': 'user', 'content': 'hello'},
        ],
        thinkingBudget: 0,
      ).toList();

      expect(requests, hasLength(1));
      expect(requests[0].containsKey('thinking'), isFalse);
    });
  });
}
