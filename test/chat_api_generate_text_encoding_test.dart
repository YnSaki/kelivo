import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/api/chat_api_service.dart';

ProviderConfig _openAIConfig(String baseUrl) {
  return ProviderConfig(
    id: 'EncodingCompatTest',
    enabled: true,
    name: 'EncodingCompatTest',
    apiKey: 'test-key',
    baseUrl: baseUrl,
    providerType: ProviderKind.openai,
  );
}

ProviderConfig _openAIReasoningConfig({
  required String id,
  required String baseUrl,
  required String modelId,
  List<String>? reasoningEfforts,
}) {
  return ProviderConfig(
    id: id,
    enabled: true,
    name: id,
    apiKey: 'test-key',
    baseUrl: baseUrl,
    providerType: ProviderKind.openai,
    models: [modelId],
    modelOverrides: {
      modelId: {
        'type': 'chat',
        'input': ['text'],
        'output': ['text'],
        'abilities': ['reasoning'],
        if (reasoningEfforts != null) 'reasoningEfforts': reasoningEfforts,
      },
    },
  );
}

class _ProxyHttpOverrides extends HttpOverrides {
  _ProxyHttpOverrides(this.port);

  final int port;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (_) => 'PROXY 127.0.0.1:$port';
    return client;
  }
}

Future<Map<String, dynamic>> _captureGenerateTextBody({
  required String providerId,
  required String modelId,
  required int thinkingBudget,
  String? configBaseUrl,
  List<String>? reasoningEfforts,
}) async {
  late Map<String, dynamic> requestBody;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() async {
    await server.close(force: true);
  });

  server.listen((request) async {
    requestBody = (jsonDecode(await utf8.decoder.bind(request).join()) as Map)
        .cast<String, dynamic>();

    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode({
        'choices': [
          {
            'message': {'content': '标题'},
          },
        ],
      }),
    );
    await request.response.close();
  });

  final localBaseUrl = 'http://${server.address.address}:${server.port}/v1';
  final effectiveBaseUrl = configBaseUrl ?? localBaseUrl;
  Future<String> generate() {
    return ChatApiService.generateText(
      config: _openAIReasoningConfig(
        id: providerId,
        baseUrl: effectiveBaseUrl,
        modelId: modelId,
        reasoningEfforts: reasoningEfforts,
      ),
      modelId: modelId,
      prompt: 'summarize',
      thinkingBudget: thinkingBudget,
    );
  }

  final title = configBaseUrl == null
      ? await generate()
      : await HttpOverrides.runZoned(
          generate,
          createHttpClient: (context) {
            return _ProxyHttpOverrides(server.port).createHttpClient(context);
          },
        );

  expect(title, '标题');
  return requestBody;
}

void main() {
  group('ChatApiService.generateText encoding compatibility', () {
    test(
      'decodes OpenAI compatible JSON as UTF-8 when content type lacks charset',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() async {
          await server.close(force: true);
        });

        server.listen((request) async {
          await utf8.decoder.bind(request).join();

          request.response.statusCode = HttpStatus.ok;
          request.response.headers.set(
            HttpHeaders.contentTypeHeader,
            'text/plain',
          );
          request.response.add(
            utf8.encode('{"choices":[{"message":{"content":"问候交流"}}]}'),
          );
          await request.response.close();
        });

        final baseUrl = 'http://${server.address.address}:${server.port}/v1';
        final title = await ChatApiService.generateText(
          config: _openAIConfig(baseUrl),
          modelId: 'title-model',
          prompt: 'summarize',
        );

        expect(title, '问候交流');
      },
    );

    test(
      'omits fixed Kimi K2.7 Code params from OpenAI compatible JSON',
      () async {
        late Map<String, dynamic> requestBody;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() async {
          await server.close(force: true);
        });

        server.listen((request) async {
          requestBody =
              (jsonDecode(await utf8.decoder.bind(request).join()) as Map)
                  .cast<String, dynamic>();

          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': '标题'},
                },
              ],
            }),
          );
          await request.response.close();
        });

        final baseUrl = 'http://${server.address.address}:${server.port}/v1';
        final title = await ChatApiService.generateText(
          config: _openAIConfig(baseUrl),
          modelId: 'kimi-k2.7-code',
          prompt: 'summarize',
          thinkingBudget: 0,
        );

        expect(title, '标题');
        expect(requestBody['model'], 'kimi-k2.7-code');
        expect(requestBody.containsKey('thinking'), isFalse);
        expect(requestBody.containsKey('reasoning_effort'), isFalse);
        expect(requestBody.containsKey('temperature'), isFalse);
        expect(requestBody.containsKey('top_p'), isFalse);
        expect(requestBody.containsKey('n'), isFalse);
        expect(requestBody.containsKey('presence_penalty'), isFalse);
        expect(requestBody.containsKey('frequency_penalty'), isFalse);
      },
    );

    test('maps Kimi K3 effort and omits fixed request parameters', () async {
      final maxBody = await _captureGenerateTextBody(
        providerId: 'MoonshotCompatTest',
        modelId: 'kimi-k3',
        thinkingBudget: 128000,
      );
      final minimumBody = await _captureGenerateTextBody(
        providerId: 'MoonshotCompatTest',
        modelId: 'kimi-k3',
        thinkingBudget: 0,
      );

      expect(maxBody['reasoning_effort'], 'max');
      expect(minimumBody['reasoning_effort'], 'low');
      for (final body in [maxBody, minimumBody]) {
        expect(body.containsKey('thinking'), isFalse);
        expect(body.containsKey('temperature'), isFalse);
        expect(body.containsKey('top_p'), isFalse);
        expect(body.containsKey('n'), isFalse);
        expect(body.containsKey('presence_penalty'), isFalse);
        expect(body.containsKey('frequency_penalty'), isFalse);
      }
    });

    test(
      'maps DeepSeek reasoning knobs for non-streaming text generation',
      () async {
        final enabledBody = await _captureGenerateTextBody(
          providerId: 'DeepSeekCompatTest',
          modelId: 'deepseek-v4-pro',
          thinkingBudget: 64000,
        );
        final disabledBody = await _captureGenerateTextBody(
          providerId: 'DeepSeekCompatTest',
          modelId: 'deepseek-v4-pro',
          thinkingBudget: 0,
        );

        expect(enabledBody['thinking'], {'type': 'enabled'});
        expect(enabledBody['reasoning_effort'], 'xhigh');
        expect(disabledBody['thinking'], {'type': 'disabled'});
        expect(disabledBody.containsKey('reasoning_effort'), isFalse);
      },
    );

    test(
      'maps DashScope reasoning knobs for non-streaming text generation',
      () async {
        final enabledBody = await _captureGenerateTextBody(
          providerId: 'DashScopeCompatTest',
          modelId: 'qwen3-plus',
          thinkingBudget: 2048,
          configBaseUrl: 'http://dashscope.aliyuncs.com/compatible-mode/v1',
        );
        final disabledBody = await _captureGenerateTextBody(
          providerId: 'DashScopeCompatTest',
          modelId: 'qwen3-plus',
          thinkingBudget: 0,
          configBaseUrl: 'http://dashscope.aliyuncs.com/compatible-mode/v1',
        );

        expect(enabledBody['enable_thinking'], isTrue);
        expect(enabledBody['thinking_budget'], 2048);
        expect(enabledBody.containsKey('reasoning_effort'), isFalse);
        expect(disabledBody['enable_thinking'], isFalse);
        expect(disabledBody.containsKey('thinking_budget'), isFalse);
        expect(disabledBody.containsKey('reasoning_effort'), isFalse);
      },
    );

    test(
      'DashScope thinking-only models omit enable_thinking instead of disabling',
      () async {
        final enabledBody = await _captureGenerateTextBody(
          providerId: 'DashScopeCompatTest',
          modelId: 'qwen3.7-max-preview',
          thinkingBudget: 2048,
          configBaseUrl: 'http://dashscope.aliyuncs.com/compatible-mode/v1',
        );
        final disabledBody = await _captureGenerateTextBody(
          providerId: 'DashScopeCompatTest',
          modelId: 'qwen3-235b-a22b-thinking-2507',
          thinkingBudget: 0,
          configBaseUrl: 'http://dashscope.aliyuncs.com/compatible-mode/v1',
        );

        expect(enabledBody.containsKey('enable_thinking'), isFalse);
        expect(enabledBody['thinking_budget'], 2048);
        expect(disabledBody.containsKey('enable_thinking'), isFalse);
        expect(disabledBody.containsKey('thinking_budget'), isFalse);
      },
    );

    test(
      'maps SiliconFlow reasoning knobs for non-streaming text generation',
      () async {
        final enabledBody = await _captureGenerateTextBody(
          providerId: 'SiliconFlow',
          modelId: 'Qwen/Qwen3-8B',
          thinkingBudget: 1024,
        );
        final disabledBody = await _captureGenerateTextBody(
          providerId: 'SiliconFlow',
          modelId: 'Qwen/Qwen3-8B',
          thinkingBudget: 0,
        );

        expect(enabledBody['thinking_budget'], 1024);
        expect(enabledBody.containsKey('enable_thinking'), isFalse);
        expect(enabledBody.containsKey('reasoning_effort'), isFalse);
        expect(disabledBody['enable_thinking'], isFalse);
        expect(disabledBody.containsKey('thinking_budget'), isFalse);
        expect(disabledBody.containsKey('reasoning_effort'), isFalse);
      },
    );
  });

  group('per-model reasoning effort vocabulary override', () {
    const nicheModel = 'my-niche-reasoner';

    test('baseline: unmatched model clamps xhigh budget to high', () async {
      final body = await _captureGenerateTextBody(
        providerId: 'NicheProvider',
        modelId: nicheModel,
        thinkingBudget: 64000,
      );
      expect(body['reasoning_effort'], 'high');
    });

    test('vocabulary unlock sends xhigh verbatim', () async {
      final body = await _captureGenerateTextBody(
        providerId: 'NicheProvider',
        modelId: nicheModel,
        thinkingBudget: 64000,
        reasoningEfforts: const ['low', 'medium', 'high', 'xhigh'],
      );
      expect(body['reasoning_effort'], 'xhigh');
    });

    test('vocabulary unlock sends max verbatim', () async {
      final body = await _captureGenerateTextBody(
        providerId: 'NicheProvider',
        modelId: nicheModel,
        thinkingBudget: 128000,
        reasoningEfforts: const ['low', 'medium', 'high', 'xhigh', 'max'],
      );
      expect(body['reasoning_effort'], 'max');
    });

    test('restrictive vocabulary clamps out-of-vocabulary budget', () async {
      final body = await _captureGenerateTextBody(
        providerId: 'NicheProvider',
        modelId: nicheModel,
        thinkingBudget: 16000,
        reasoningEfforts: const ['low', 'high'],
      );
      expect(body['reasoning_effort'], 'high');
    });

    test('empty vocabulary omits the effort parameter', () async {
      final body = await _captureGenerateTextBody(
        providerId: 'NicheProvider',
        modelId: nicheModel,
        thinkingBudget: 32000,
        reasoningEfforts: const [],
      );
      expect(body.containsKey('reasoning_effort'), isFalse);
    });

    test('matched model honors the override over the registry', () async {
      final overriddenBody = await _captureGenerateTextBody(
        providerId: 'OpenAICompatTest',
        modelId: 'kimi-k3',
        thinkingBudget: 128000,
        reasoningEfforts: const ['low', 'high'],
      );
      final registryBody = await _captureGenerateTextBody(
        providerId: 'OpenAICompatTest',
        modelId: 'kimi-k3',
        thinkingBudget: 128000,
      );

      // Kimi K3 registry supports max; the restrictive override clamps it.
      expect(overriddenBody['reasoning_effort'], 'high');
      expect(registryBody['reasoning_effort'], 'max');
    });
  });
}
