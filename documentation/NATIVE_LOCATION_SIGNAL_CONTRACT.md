# G-REDruntime native player/location subscription contract

**Owner:** `G-REDruntime_Framework/main`. **2026-11-18:** experimental source integration, no gameplay validation. Native C++ authority remains CET's `GCETStaticLocations.dll`; GCO REDscript Resolver generates mod consumers and dispatches the single DLL/manifest pair. The framework **does not** contain or rebuild C++.

## Two source surfaces

- Always-on framework code: `r6/scripts/G-RedRuntime/Location/NativeLocationSignals.reds`. This contains a dormant, opt-in subscriber registry and a virtual backend interface **without native declarations**. Existing installations with no CET-generated native DLL remain unaffected.
- Optional C++ adapter: `optional-native/r6/scripts/G-RedRuntime/Native/GCETNativeLocationBackend.reds`. GCO stages the actual owner file **only alongside the single CET native DLL**. Its `@addMethod(GameInstance)` declarations describe CET's existing RTTI, and `GCETNativeLocationBackend` implements the framework backend interface. Never install the optional file in a game without its corresponding DLL.

## Consumer subscription

The Resolver scans source and plans independently of whether the component is already installed. When generating a compatible per-mod adapter, it can perform:

```reds
let runtime = GRedRuntime.Runtime.Get(game);
if IsDefined(runtime) && runtime.IsReady() {
  let service = runtime.GetNativeLocations();
  // owner and expectedCount come from the source-derived GCAS manifest.
  // index is zero-based. Retain subscriptionID in the mod's lifecycle.
  let subscriptionID = service.SubscribeLocation(
    owner, index, expectedCount, listener,
    new GRedRuntime.GCETNativeLocationBackend()
  );
}
```

A listener extends `GRedRuntime.NativeLocationListener` and implements `OnGRedNativeLocation(owner, index, state)`. **State -1 = UNKNOWN; 0 = FAR; 1 = NEAR.** The mod must retain its original authored checks and callbacks when UNKNOWN or when subscription returns 0. Source-specific negative-proof is needed before an actual FAR bypass. The framework makes no whole-method skip decision.

The mod's original cleanup/teardown path must call `runtime.GetNativeLocations().UnsubscribeLocation(subscriptionID)` exactly once when still valid. `Runtime.OnDetach` also releases all remaining subscriptions. The returned token is per consumer; repeated subscriptions to the same owner/index use one internal watch.

The first adapter supplies a `NativeLocationBackend`; subsequent mod adapters share that same backend object in the runtime. Native stream consumer ID `1702404` is distinct from CET Lua's `1702403`. The shared `Scheduler` runs **one 0.10s** native event-drain job only while there are active REDscript subscribers. It never polls player position itself and never adds timers to each mod.

## Snapshot and fallback

- Initial readings, session changes, and native ring-buffer resync require an authoritative snapshot. Validate owner count, anchor identity and state before emitting NEAR/FAR.
- The source-generated REDscript owner range begins at 100,000,000. Only such REDscript-owned anchors are armed/disarmed by this service; already-armed CET-owned anchors are not disarmed on REDscript cleanup.
- On player attach/detach, native coordinator UNKNOWN, invalid source mapping or lost snapshot, invalidate observed values to -1 and notify subscribers. Consumer behavior must fall back to the original REDscript mod logic.
- An event callback may unsubscribe itself or other consumers. Subscription tokens are deactivated before cleanup and the native job is stopped after the last consumer.
- This is opt-in. The framework does not automatically attach any mod-specific listener, replace input handlers, change quest-fact callbacks or install anything into the live game.

## Ownership and gates

- **CET Resolver:** owns native C++ DLL and compiled Lua-side owners.
- **GCO REDscript Resolver:** identifies compatible mod subscribers, computes source-driven REDscript location records and emits mod-specific registration/cleanup adapters. It **must copy the optional backend from this repository**, not generate another variant.
- **G-REDruntime:** owns one subscription service and the optional binding source.
- **GRSP:** profiling/evidence; no resolver source ownership.

Checks: framework contract tests for dormant core, single job, token cleanup, UNKNOWN invalidation and native declaration inventory. GCO CI must compile the framework with the whole effective REDscript stack and compile the optional adapter **in a separate native-enabled lane** using official SCC 0.5.31. Gameplay remains necessary for native RTTI ABI calls, load/teleport/session resets, spatial boundaries and subscriber ordering.

**Status:** source-level integration only. No player mod migrations or shipped optimization ZIP are implied by adding this service. User-approved experiment; keep earlier geometry and action-event changes as independent checkpoints.
