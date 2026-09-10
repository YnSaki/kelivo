# ADR-0063: Per-Model Reasoning Effort Vocabulary Override (推理等级词表自定义)

The reasoning budget slider tops out at 重度推理 (`reasoning_effort: high`) for
registry-unmatched ("niche") models: `openAIReasoningSupport` returns null and
the normalizer clamps xhigh/max to high, while `_claudeSupportsXhigh/MaxReasoning`
and `_normalizeClaudeEffort` gate the Claude line by hard-coded version regexes.
Users cannot unlock 极限/全力 for models they know better than the app. This ADR
adds a per-model override in the same shape as the existing abilities/modalities
overrides.

## Decision

`ProviderConfig.modelOverrides[key]['reasoningEfforts']` holds an explicit
vocabulary — a list drawn from `low / medium / high / xhigh / max` (`'none'` is
deliberately excluded: reasoning-off means the parameter is omitted, never
sent). Three rules:

1. **The override wins globally** — it applies to registry-matched models too
   (gpt-5.2, glm-5.3, …), replacing the built-in support object entirely,
   **including its `offFallback`** (an overridden gpt-5-pro turns off for real
   instead of being forced to `high`). Same rule as abilities/modalities, which
   never consult a registry. Unset = built-in registry behavior, unchanged.
2. **The vocabulary is the slider** — the reasoning budget sheet / desktop
   popover show exactly Off/Auto + the configured levels + the custom-budget
   row, so out-of-vocabulary selection is impossible by construction. Legacy
   persisted budgets and custom token values that land outside the vocabulary
   still resolve through the existing `_pickSupportedEffort` preference ladder
   (no new mechanism). An explicit empty list means "no effort parameter"
   (normalizes to `auto`, mirroring the muse family).
3. **Parameter shape stays host-keyed** — the override changes only *which
   value* flows, never *which parameter*. Vendor shapes (OpenRouter, DashScope,
   Zhipu, SiliconFlow, …) keep dispatching by host; unknown hosts keep the
   OpenAI standard `reasoning_effort` / `reasoning.effort`. Accepted *values*
   for a niche model are unknowable in advance — the user's vocabulary is the
   knowledge, a 400 from the provider is the feedback, no probing or fallback
   is added. For exotic shapes the existing per-model custom-body KV remains
   the escape hatch (documented trap: a static `reasoning_effort` body key
   always overrides the dynamic slider value).

Scope: OpenAI-compatible and Claude lines. The Claude line does not send effort
strings for non-adaptive niche models (budget passes as `budget_tokens`), so
there the vocabulary gates the slider stops and budget size; for adaptive
5.x-family relays it normalizes all effort levels through the same vocabulary
ladder (unlock and clamp) and an empty vocabulary omits `output_config`; the
DeepSeek-Claude branch only emits `high`/`max` when the vocabulary allows them,
otherwise it stays silent. The Gemini line has no effort vocabulary and is out
of scope.

UI: mobile `model_detail_sheet.dart` + desktop `model_edit_dialog.dart`, below
the Abilities row, visible only for chat models with the reasoning ability on
non-Google providers. First enable prefills from the registry (openai kind) or
the `low/medium/high` passthrough (claude kind); turning the switch off and
re-enabling within one edit session restores the in-memory list.

## Considered options

- **Registry stays authoritative for matched models**: rejected — "app regex is
  wrong/outdated" cases (e.g. a new `gpt-5.4-turbo` variant inheriting the
  wrong family's efforts) become unfixable by the user, and the codebase would
  carry two override semantics. A user-forced wrong value on a known model
  yields a provider 400 — an explicit, self-inflicted, visible failure.
- **Two booleans (unlock xhigh / unlock max) only**: rejected — cannot express
  "this model only accepts low/high" (e.g. Kimi-K3-shaped niche models), and
  does not unify with the `SegmentedToggleMulti` ability/modality idiom.
- **Full `OpenAIReasoningSupport` editing (offFallback, samplingRequiresNone)**:
  rejected — disproportionate UI complexity; sampling rules stay registry-owned
  (conservative: params are dropped, never sent invalidly).
- **Unlock-only semantics (low/medium/high always pass through)**: rejected —
  vocabulary-as-slider gives one mental model; the clamp ladder only handles
  legacy values.

## Consequences

- The override rides `provider_configs_v1` (backup / LAN sync / LWW) with no
  schema change; old builds ignore the unknown key.
- Once saved, the vocabulary is frozen — later app-side registry improvements
  do not retro-apply to a model with an explicit override; switching the toggle
  off re-follows the registry.
- `openAIAllowsSamplingParams` keeps re-normalizing with the registry support:
  for an overridden matched model the sampling check is conservative (params
  may be dropped even when the overridden effort would have allowed them) —
  accepted, never the reverse (invalid params sent).
