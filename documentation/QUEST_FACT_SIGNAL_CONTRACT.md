# G-REDruntime — opt-in quest fact change signals

**Owner:** `G-REDruntime_Framework/main`. **Status:** candidate/source implementation, **not** a released optimization, proven in-game callback replacement or measured performance improvement. It is a transparent infrastructure extension: with **zero consumers**, no quest fact is registered, read or polled by the new service.

## Contract

`Runtime.GetQuestFactSignals()` returns the `QuestFactSignals` service created in the existing Runtime lifecycle. The service is not a second runtime, timer, polling scheduler, native hook or new mod format.

- `AcquireFact(fact: CName) -> Int32`: returns a unique positive **interest token** after registering the first listener for that exact fact; returns 0 when the runtime/QuestsSystem/registration is unavailable. Two consumers of the same fact get two different interest tokens but share **one** underlying `QuestsSystem.RegisterListener`.
- `ReleaseFact(interestID: Int32) -> Bool`: removes only the matching active interest. Duplicate releases are rejected. The final release calls `QuestsSystem.UnregisterListener` with the **original exact fact name and returned listener ID**, clears any last observed value and frees the unused watch and token. Runtime shutdown releases any remaining registrations, clearing its arrays.

**Late callback safety:** each listener bridge carries its own object identity, checked against the currently registered watch before a callback can advance a generation or publish state. A delayed callback from a previously released listener must never update a newly acquired listener for the same fact. Distinct consumer interest IDs still govern release and last-interest cleanup.

- `Version(fact: CName) -> Uint32`: per-fact generation advances on **each** delivered callback, **including repeated Int32 values**. A missing/unwatched fact reports 0. Versions apply only to this Runtime lifetime and are not saved-game IDs.
- `HasObservedValue(fact)` and `LastObservedValue(fact)`: unknown until the engine calls the bridge. **Always check HasObservedValue first**. A registration does not mean a snapshot exists. Use the original `QuestsSystem.GetFact` on unknown, missing framework, failed registration, unload/reload, and any unverified alternate writer.
- The source-owned `protected cb func OnFactChanged(value: Int32) -> Bool` is an *additional* observation-only listener with a `false` return, as verified in existing REDscript source patterns. It does **not** replace or reorder existing mod registrations/callbacks. Runtime gameplay must still establish the engine's additive callback ordering and reentrancy behavior.
- On each observed callback, the service marks the already-existing `DirtyFlags` name `QUEST_FACT`, and conditionally publishes an existing `EventBus` event `topic=n"QUEST_FACT", name=n"CHANGED", nameValue=<fact>, intValue=<value>`. No event object is constructed without EventBus subscribers.
- On player attach/detach, the service invalidates known values and increments generations; `DirtyFlags.QUEST_FACT` and one `EventBus` event `name=n"SESSION_INVALIDATED"` (without a valid value) notify interested consumers. These are **session invalidations, not fact changes**.
- No automatic `AcquireFact`, GetFact, observer polling or timers run from `Runtime.OnAttach`. All registrations are explicitly requested and must be released by the adopting source-owned integration.

## Example only — not an approved generated rewrite

```reds
let runtime = GRedRuntime.Runtime.Get(game);
if IsDefined(runtime) && runtime.IsReady() {
    let token: Int32 = runtime.GetQuestFactSignals().AcquireFact(n"source_proven_fact");
    // Retain token in the integration owner; on detach call:
    // runtime.GetQuestFactSignals().ReleaseFact(token);
    // While unknown, call ORIGINAL QuestsSystem.GetFact(game, name).
}
```

The `CName` above is **illustrative**, not a fixed mod or fact allowlist. The game source is authoritative for actual fact names and callbacks. Consumers may use `Version` for their own version comparison, or subscribe to the existing `EventBus` `QUEST_FACT` topic and filter by `nameValue`. The globally shared `DirtyFlags.QUEST_FACT` marks **any watched fact**, so it is not sufficient to skip a specific fact reader without additionally checking exact name/version. Never use global `DirtyFlags.Consume` to starve other readers.

## Admission and proof

Before applying an optimizer patch to an existing mod:

1. Read every current live source owner; prove exact `CName`, `QuestsSystem` receiver, all literal/dynamic paths, original subscriber callback return and dispatch order, world and runtime lifecycle. A `GetFact` call or method named `RegisterListener` is **not** enough; other engine/UI systems use `RegisterListener`.
2. Prove complete writer and alias coverage, including external engine/quest graph writes and mod helper calls. `SetFact` source searches alone never establish a closed writer set.
3. Preserve the original callback timing, first-use read, unknown/missing framework fallback, repeated-value delivery, unsubscribing and cleanup. A polling reader cannot be suppressed merely because this service exists.
4. Verify official SCC with actual full source, untouched/partially/fully optimized sources, idempotence and source-drift refusal, real game load/reload behavior, F11 original versus changed and real PresentMon A/B.
5. Only the original GCO REDscript Resolver may emit a source-owned overlay at the original `r6/scripts/<mod>/...` paths after all proof. No broad auto-subscribe of every quest fact and no new data registry with fixed mod names.

**Related:** GCO [R5 shared dependency inventory](https://github.com/giorgioherma/Gs-Cyberpunk2077_Optimizations/blob/dev/redscript/resolver_handoff/docs/integration/R5-SHARED-DEPENDENCY-TRIGGER-STATUS.md), real-source quest-fact graph `scan-quest-facts` (GCO `dev/redscript/resolver_handoff`). That graph distinguishes literal names, dynamic expressions and source-typed versus unproven listener receivers. It is evidence, not deployment authority.
