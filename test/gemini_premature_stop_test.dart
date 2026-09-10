import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/api/chat_api_service.dart';

ProviderConfig _geminiConfig(String baseUrl) {
  return ProviderConfig(
    id: 'GeminiPrematureStopTest',
    enabled: true,
    name: 'GeminiPrematureStopTest',
    apiKey: 'test-key',
    baseUrl: baseUrl,
    providerType: ProviderKind.google,
  );
}

/// Mirrors the proxy frame shape that triggers the bug: `content` is always
/// present (its `parts` may be empty) and may carry a `finishReason` while
/// sending no part at all.
String _frame({String? text, String? finishReason}) {
  return 'data: ${jsonEncode({
    'candidates': [
      {
        'content': {
          'role': 'model',
          'parts': [
            if (text != null) {'text': text},
          ],
        },
        if (finishReason != null) 'finishReason': finishReason,
      },
    ],
  })}\n\n';
}

bool _isGenerationDone(List<ChatStreamChunk> chunks) =>
    chunks.any((chunk) => chunk.isDone);

String _joinedContent(List<ChatStreamChunk> chunks) =>
    chunks.map((chunk) => chunk.content).join();

Stream<ChatStreamChunk> _streamFrom(HttpServer server) {
  return ChatApiService.sendMessageStream(
    config: _geminiConfig(
      'http://${server.address.address}:${server.port}/v1beta',
    ),
    modelId: 'gemini-2.5-flash',
    messages: const [
      {'role': 'user', 'content': 'hi'},
    ],
  );
}

void main() {
  group('premature empty STOP semantics', () {
    test(
      'leading empty STOP cannot finish the stream before a later STOP',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        var requestCount = 0;
        final finalStop = Completer<void>();
        server.listen((request) async {
          requestCount++;
          await utf8.decoder.bind(request).join();
          request.response
            ..statusCode = HttpStatus.ok
            ..bufferOutput = false
            ..headers.contentType = ContentType(
              'text',
              'event-stream',
              charset: 'utf-8',
            );
          request.response
            ..write(_frame(finishReason: 'STOP'))
            ..write(_frame(finishReason: 'STOP'));
          for (final text in ['Hello', ' world', '!']) {
            request.response.write(_frame(text: text));
          }
          await request.response.flush();
          await finalStop.future;
          request.response.write(_frame(finishReason: 'STOP'));
          await request.response.flush();
          // Deliberately keep the response open: completion must be driven by
          // the new STOP, not by EOF.
        });

        final chunks = <ChatStreamChunk>[];
        final done = Completer<void>();
        final textArrived = Completer<void>();
        const expected = 'Hello world!';
        final sub = _streamFrom(server).listen((chunk) {
          chunks.add(chunk);
          if (chunk.isDone && !done.isCompleted) done.complete();
          if (!textArrived.isCompleted && _joinedContent(chunks) == expected) {
            textArrived.complete();
          }
        });
        addTearDown(sub.cancel);

        await textArrived.future.timeout(const Duration(seconds: 5));
        expect(
          _isGenerationDone(chunks),
          isFalse,
          reason: 'a leading empty STOP must not complete the stream',
        );

        finalStop.complete();
        await done.future.timeout(const Duration(seconds: 5));
        expect(_joinedContent(chunks), expected);
        expect(_isGenerationDone(chunks), isTrue);
        expect(requestCount, 1);
      },
    );

    test('empty MAX_TOKENS frame still completes immediately', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var requestCount = 0;
      server.listen((request) async {
        requestCount++;
        await utf8.decoder.bind(request).join();
        request.response
          ..statusCode = HttpStatus.ok
          ..bufferOutput = false
          ..headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
        request.response.write(_frame(finishReason: 'MAX_TOKENS'));
        await request.response.flush();
        // Keep the response open: completion must come from the frame itself.
      });

      final chunks = await _streamFrom(
        server,
      ).toList().timeout(const Duration(seconds: 5));

      expect(requestCount, 1);
      expect(_joinedContent(chunks), '');
      expect(_isGenerationDone(chunks), isTrue);
      expect(chunks.last.truncationReason, 'max_tokens');
    });
  });

  group('premature empty STOP E2E matrix', () {
    for (final ending in ['STOP', 'EOF', 'DONE']) {
      for (final hasText in [true, false]) {
        test(
          'leading empty STOP preserves text=$hasText with $ending ending',
          () async {
            final server = await HttpServer.bind(
              InternetAddress.loopbackIPv4,
              0,
            );
            addTearDown(() => server.close(force: true));
            var requestCount = 0;
            server.listen((request) async {
              requestCount++;
              await utf8.decoder.bind(request).join();
              request.response
                ..statusCode = HttpStatus.ok
                ..bufferOutput = false
                ..headers.contentType = ContentType(
                  'text',
                  'event-stream',
                  charset: 'utf-8',
                );
              request.response
                ..write(_frame(finishReason: 'STOP'))
                ..write(_frame(finishReason: 'STOP'));
              if (hasText) {
                for (final text in ['第一段正文。', '第二段正文。', '最后一段。']) {
                  request.response.write(_frame(text: text));
                }
              }
              if (ending == 'STOP') {
                request.response
                  ..write(_frame(finishReason: 'STOP'))
                  ..write(_frame(finishReason: 'STOP'));
              } else if (ending == 'DONE') {
                request.response.write('data: [DONE]\n\n');
              }
              await request.response.close();
            });

            final chunks = await _streamFrom(
              server,
            ).toList().timeout(const Duration(seconds: 10));

            expect(requestCount, 1);
            expect(_joinedContent(chunks), hasText ? '第一段正文。第二段正文。最后一段。' : '');
            expect(_isGenerationDone(chunks), isTrue);
          },
        );
      }
    }
  });
}
