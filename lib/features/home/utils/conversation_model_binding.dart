import '../../../core/models/conversation.dart';

/// Where an in-conversation model selection should be persisted.
enum ConversationModelWriteTarget {
  /// Write the conversation's own binding (freezes this conversation).
  conversationBinding,

  /// Update the assistant's chat model (status quo: unbound + toggle off).
  assistant,

  /// Update the global default (settings contexts).
  global,
}

/// Write-target rule for in-conversation model switches (ADR-0055):
/// - toggle on → the conversation binding (the first switch creates it);
/// - toggle off → the assistant (status quo). Existing bindings are
///   ignored-but-kept: consecutive switches write the assistant until the
///   toggle is re-enabled.
ConversationModelWriteTarget resolveConversationModelWriteTarget({
  required bool conversationModelIndependent,
  required Conversation? conversation,
}) {
  if (conversation == null) return ConversationModelWriteTarget.assistant;
  if (conversationModelIndependent) {
    return ConversationModelWriteTarget.conversationBinding;
  }
  return ConversationModelWriteTarget.assistant;
}

/// True when the conversation carries a complete model binding.
///
/// The pair is atomic: a partial pair (one field alone, e.g. from damaged
/// restore data or an interrupted write) is treated as unbound so no
/// `provider-from-conversation + model-from-assistant` hybrid can resolve.
bool conversationModelBindingActive(Conversation? conversation) {
  if (conversation == null) return false;
  return conversation.chatModelProvider != null &&
      conversation.chatModelId != null;
}
