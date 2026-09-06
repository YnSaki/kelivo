import 'package:uuid/uuid.dart';

import '../../providers/settings_provider.dart';
import '../model_override_payload_parser.dart';

const String _openRouterAppReferer = 'https://github.com/cuplivo/cuplivo';
const String _openRouterAppTitle = 'Cuplivo';
const String _openRouterAppCategories = 'general-chat';

const String _openCodeSessionHeader = 'x-opencode-session';

bool _hasSessionHeader(Map<String, String> headers) =>
    headers.keys.any((k) => k.toLowerCase() == _openCodeSessionHeader);

/// Resolve once per generation, before retries and tool follow-up rounds.
///
/// Auto-injects `x-opencode-session` only for providers whose host is exactly
/// `opencode.ai` (never suffix-domain typos). With a conversation context the
/// conversation id is used; without one a fresh v4 UUID is minted.
///
/// Cuplivo's header merge order is `custom -> extraHeaders` (extraHeaders
/// win, see `_customHeaders` / provider request builds), so an explicitly
/// user-configured session header — provider-level custom headers,
/// per-model override headers, or [extraHeaders] in any casing — suppresses
/// the auto value.
Map<String, String>? providerSessionHeaders(
  ProviderConfig config, {
  String? conversationId,
  Map<String, String>? extraHeaders,
  String? modelId,
}) {
  final host = Uri.tryParse(config.baseUrl)?.host.toLowerCase();
  if (host != 'opencode.ai') return extraHeaders;
  final userOverridden =
      (extraHeaders != null && _hasSessionHeader(extraHeaders)) ||
      _hasSessionHeader({
        ...ModelOverridePayloadParser.customHeaders({
          'headers': config.customHeaders,
        }),
        if (modelId != null)
          ...ModelOverridePayloadParser.customHeaders(
            ModelOverridePayloadParser.modelOverride(
              config.modelOverrides,
              modelId,
            ),
          ),
      });
  if (userOverridden) return extraHeaders;
  final id = conversationId?.trim() ?? '';
  return {
    _openCodeSessionHeader: id.isEmpty ? const Uuid().v4() : id,
    ...?extraHeaders,
  };
}

bool isOpenRouterProvider(ProviderConfig config) {
  final host = Uri.tryParse(config.baseUrl)?.host.toLowerCase() ?? '';
  return host.contains('openrouter.ai');
}

Map<String, String> providerDefaultHeaders(ProviderConfig config) {
  if (!isOpenRouterProvider(config)) return const <String, String>{};
  return const <String, String>{
    'HTTP-Referer': _openRouterAppReferer,
    'X-OpenRouter-Title': _openRouterAppTitle,
    'X-OpenRouter-Categories': _openRouterAppCategories,
  };
}
