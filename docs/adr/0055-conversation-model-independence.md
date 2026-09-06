# ADR-0055: Conversation Model Independence (会话模型独立)

In-chat model switches once wrote to the assistant (`Assistant.chatModel*`)
via `showModelSelectSheet`, so switching in one conversation leaked to every
other conversation of the same assistant and to future assistant settings.
This ADR adds an opt-in mode in which a conversation's model stops
correlating with its assistant's.

## Decision

A user toggle, `conversation_model_independent_v1` (default OFF, Display &
Behavior, SQLite business preference), gates a **conversation model binding**:
two new nullable columns on `conversation_rows`
(`chat_model_provider` / `chat_model_id`, schema v22, mirroring
`Assistant.chatModel*` naming).

- **Effective model chain (toggle-aware)**: toggle ON = `convo.chatModel* →
  assistant.chatModel* → global default`; toggle OFF =
  `assistant.chatModel* → global default`. Turning the toggle off *ignores but
  keeps* existing bindings (the conversation follows the assistant again);
  turning it back on restores them.
- **Atomic pair**: the binding is both-or-none. A partial pair (provider
  without model or vice versa, e.g. from damaged restore data) is normalized
  to unbound at every read boundary (`Conversation.fromJson`, both
  `ChatDatabaseRepository` conversation row mappers, and
  `conversationModelBindingActive`), so `Gemini + claude-4` hybrids can never
  resolve.
- **Snapshot at creation**: with the toggle ON, new `kindNormal` conversations
  (via `ChatService.createConversation` and `createDraftConversation` —
  handoff, proactive care, and forks all funnel through them) snapshot the
  effective model. Group conversations never bind (per-speaker models rule).
  Unresolvable (either field null) stays unbound.
- **Write-target rule**: with the toggle OFF an in-conversation switch writes
  the assistant (status quo, even when a binding is stored — the binding is
  ignored but preserved); with the toggle ON it writes the conversation
  binding (the first switch creates it, with a one-shot "仅当前会话生效"
  snackbar). The assistant is never touched by in-chat switches while the
  toggle is ON.
- **Clear operation ("follow assistant")**: when the conversation stores a
  binding, the model selector shows a "跟随助手模型" row (ADR-0055 in
  `model_select_sheet.dart`, mobile bottom sheet and desktop dialog) that
  clears the binding via `ChatService.clearConversationModelBinding`; the
  conversation then dynamically follows the assistant model (it does not copy
  the current effective value).
- **Coverage**: send, regenerate, and continue-after-tool all resolve
  through the chain (the chat `getModelConfig` call sites), as do the model
  capsule, input-bar image-routing/warning gates, reasoning availability
  gates, and the model selector's preselect. Regenerate follows the chain
  (not per-message replay) so a bound conversation stays on its own model.

## Considered options

- **Retroactive snapshot at toggle-enable** (freeze all existing
  conversations when the toggle flips): rejected — a preference change
  silently mass-mutates chat data, and users enabling the mode for new
  conversations would unintentionally freeze old ones.
- **Nullable override only** (conversation follows the assistant until the
  user first switches): rejected — assistant changes would still leak into
  untouched conversations, breaking direction (b) of the decoupling.
- **Regenerate replays the message's stored model**: rejected — diverges
  from send and would make regenerate out of sync with the conversation's
  chosen model.
- **Toggle OFF clears all bindings**: rejected — destructive and surprising;
  a conversation's model would jump back to the assistant's. The chosen
  ignore-but-keep behavior satisfies the acceptance criteria of issue #678
  (off = assistant everywhere, re-on = stored overrides resume).
- **Sticky read chain (toggle-agnostic)**: the first implementation; rejected
  under review — with the toggle OFF a bound conversation kept using its own
  model, contradicting the issue's "关闭后使用助手模型" requirement.

## Capability gates vs assistant-owned configuration

Model-identity capability UI follows the conversation's effective model:
the model icon, reasoning entry visibility (`isReasoningModel`), the
reasoning budget popover's X-high/max option availability, the Tools Hub /
built-in-search tool gates, and image routing/warning gates. Assistant-owned
*configuration* stays assistant-level: the reasoning budget value itself,
MCP/local-tool/workspace/skill bindings, prompt and request parameters —
the binding changes *which model talks*, not the assistant's kit. A bound
conversation therefore shows the affordances of its own model but still
sends with the assistant's request settings.

## Out of scope (unchanged)

Per-speaker group-chat models, Multi-AI engine threads, translation/search/
global-default model selections, the assistant settings page model selector,
title/summary/suggestion/compress/proactive-care model chains (they have
their own dedicated settings), and proactive care's assistant-level send flow.

## Consequences

- New conversations default to OFF behavior; existing conversations never
  bind retroactively.
- `Conversation` is a `??`-pattern `copyWith` model. The new nullable fields
  use a `clearChatModel` flag (mirroring `Assistant.copyWith(clearChatModel:)`)
  instead of a sentinel: mixing the sentinel pattern with the existing `??`
  pattern inside one model is forbidden, so the flag is the documented
  stopgap for the null-clear trap.
- Backup/restore, LAN sync, and trash recovery round-trip the two fields
  through the existing `Conversation.toJson/fromJson`; old builds ignore
  them on restore; old zips restore with null bindings; partial pairs are
  normalized to unbound.
