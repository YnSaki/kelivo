import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/api/chat_api_service.dart';

ProviderConfig _responsesConfig(String baseUrl) {
  return ProviderConfig(
    id: 'ResponsesTest',
    enabled: true,
    name: 'ResponsesTest',
    apiKey: 'test-key',
    baseUrl: baseUrl,
    providerType: ProviderKind.openai,
    useResponseApi: true,
  );
}

String _baseUrl(HttpServer server) {
  return 'http://${server.address.address}:${server.port}/v1';
}

void main() {
  group('OpenAI Responses reasoning previews', () {
    test('reads OAuth summary parts from non-stream output', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        await utf8.decoder.bind(request).join();
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'output_text': 'Answer',
            'output': [
              {
                'type': 'reasoning',
                'content': const <dynamic>[],
                'summary': const [
                  {'type': 'summary_text', 'text': 'Compare the tenths place.'},
                  {'type': 'summary_text', 'text': 'Choose the larger value.'},
                ],
              },
            ],
          }),
        );
        await request.response.close();
      });

      final chunks = await ChatApiService.sendMessageStream(
        config: _responsesConfig(_baseUrl(server)),
        modelId: 'gpt-5',
        messages: const [
          {'role': 'user', 'content': 'which is larger, 3.4 or 3.35?'},
        ],
        stream: false,
      ).toList();

      expect(chunks, hasLength(1));
      expect(chunks.single.content, 'Answer');
      expect(
        chunks.single.reasoning,
        'Compare the tenths place.Choose the larger value.',
      );
    });

    test(
      'streams summary deltas once without duplicating done or terminal text',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() async {
          await server.close(force: true);
        });

        server.listen((request) async {
          await utf8.decoder.bind(request).join();
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
          );
          void send(Map<String, dynamic> event) {
            request.response.write('data: ${jsonEncode(event)}\n\n');
          }

          send({
            'type': 'response.output_item.added',
            'output_index': 0,
            'item': {
              'id': 'rs_1',
              'type': 'reasoning',
              'content': const <dynamic>[],
              'summary': const <dynamic>[],
              'encrypted_content': 'cipher',
            },
          });
          send({
            'type': 'response.reasoning_summary_text.delta',
            'item_id': 'rs_1',
            'output_index': 0,
            'summary_index': 0,
            'delta': 'First step. ',
          });
          send({
            'type': 'response.reasoning_summary_text.delta',
            'item_id': 'rs_1',
            'output_index': 0,
            'summary_index': 0,
            'delta': 'Second step.',
          });
          // Repeats everything streamed so far; must not be emitted twice.
          send({
            'type': 'response.reasoning_summary_text.done',
            'item_id': 'rs_1',
            'output_index': 0,
            'summary_index': 0,
            'text': 'First step. Second step.',
          });
          send({'type': 'response.output_text.delta', 'delta': 'Hello'});
          send({
            'type': 'response.completed',
            'response': {
              'output': [
                {
                  'id': 'rs_1',
                  'type': 'reasoning',
                  'content': const <dynamic>[],
                  'summary': const [
                    {'type': 'summary_text', 'text': 'First step.'},
                    {'type': 'summary_text', 'text': ' Second step.'},
                  ],
                },
                {
                  'type': 'message',
                  'content': const [
                    {'type': 'output_text', 'text': 'Hello'},
                  ],
                },
              ],
            },
          });
          await request.response.close();
        });

        final chunks = await ChatApiService.sendMessageStream(
          config: _responsesConfig(_baseUrl(server)),
          modelId: 'gpt-5',
          messages: const [
            {'role': 'user', 'content': 'hi'},
          ],
        ).toList();

        expect(chunks.map((c) => c.content).join(), 'Hello');
        // The terminal item repeats the streamed summary; the decoder must
        // emit only what was not streamed yet, so no text is duplicated.
        expect(chunks.map((c) => c.reasoning ?? '').join(), 'First step. Second step.');
      },
    );

    test('replays a reasoning item that never streamed deltas', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        await utf8.decoder.bind(request).join();
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        void send(Map<String, dynamic> event) {
          request.response.write('data: ${jsonEncode(event)}\n\n');
        }

        send({
          'type': 'response.output_item.done',
          'output_index': 0,
          'item': {
            'id': 'rs_2',
            'type': 'reasoning',
            'content': const <dynamic>[],
            'summary': const [
              {'type': 'summary_text', 'text': 'Only in the final item.'},
            ],
          },
        });
        send({'type': 'response.output_text.delta', 'delta': 'Hi'});
        send({
          'type': 'response.completed',
          'response': {
            'output': const <dynamic>[],
          },
        });
        await request.response.close();
      });

      final chunks = await ChatApiService.sendMessageStream(
        config: _responsesConfig(_baseUrl(server)),
        modelId: 'gpt-5',
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
      ).toList();

      expect(chunks.map((c) => c.content).join(), 'Hi');
      expect(
        chunks.map((c) => c.reasoning ?? '').join(),
        'Only in the final item.',
      );
    });
  });
}
