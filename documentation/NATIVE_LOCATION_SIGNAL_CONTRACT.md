# G-REDruntime native player/location subscription contract

## 2026-11-19 — generic location cohorts without per-mod lifecycle

**Source-owner implementation:** `r6/scripts/G-RedRuntime/Location/NativeLocationSignals.reds` now owns `NativeLocationGroupListener`, `NativeLocationGroup`, `AllLocationGroupFar(owner, expectedCount, backend)` and `HasLocationGroup(owner, expectedCount)`. The first call lazily registers all source-compiled owner anchors through the **existing** `SubscribeLocation` API. Their generated mod consumer does not register a new scheduler job or require a `ScriptableSystem` Start/Stop method; one framework-owned job drains the same C++ stream. Each group listener tracks known FAR counts, and only **all sites FAR** yields a negative result. UNKNOWN, no/invalid native data, an incomplete group, a missing player and source-mapping mismatches run original author code. Session invalidation invalidates the group observations; Runtime shutdown clears all group listeners/tokens.

**Optional bridge:** `GCETNativeLocationGuard.DefinitelyFarPlayer(player, owner, expectedCount)` in the existing optional CET-native backend verifies the supplied GameObject matches the current local player and delegates to the service. A previously registered group uses the service without allocating another `GCETNativeLocationBackend`; the backend is created only during first registration. Neither core nor standalone REDscript requires CET native symbols.

**Experiment scope:** GCO's same source-owned `GenericNativeLocationSubscriberPass` recognizes (1) literal Vector4 arrays tested through a source-defined near helper and (2) strict local-player comparisons against source-defined constant Vector4 factories. The native coordinate inventory comes from the same parser as generation. Group-array FAR bypasses repeated array construction and distance searches. Quest FAR becomes an additional Boolean short-circuit operand in the **original distance comparison**, preserving unrelated quest facts and callback state. The generator admits source range <=128m for 256m native array anchors; fixed quest thresholds use original radius plus 32m. These margins mitigate but do not eliminate stale FAR risk after teleport/rapid movement. Dynamic sites, NPC/vehicle positions, arbitrary callback suppression and global vector caching are not authorized.

**Evidence:** framework source contracts [#11 SUCCESS](https://github.com/giorgioherma/G-REDruntime_Framework/actions/runs/44611667162), [#12 SUCCESS](https://github.com/giorgioherma/G-REDruntime_Framework/actions/runs/44614674499). REDscript official SCC and game validation are separate GCO checks. No profiler rebuilt, no gameplay optimization ZIP, no measured gains.


## 2026-11-19 — existing CET strict-live player Vector4 adapter completed

- **Framework owner:** `optional-native/r6/scripts/G-RedRuntime/Native/GCETNativeLocationBackend.reds` now declares the **existing C++ DLL's** `GameInstance.GCETPlayerVector4Live() -> Vector4` and `GameInstance.GCETPlayerVector4Valid() -> Bool` native methods alongside the original location methods. No second player observer, native binary, independent timer, or new core framework dependency was introduced.
- **Typed REDscript call:** `GCETNativePlayerVector.LiveOrOriginal(player: ref<PlayerPuppet>) -> Vector4` calls the strict-live vector getter and reads the immediately associated validity before using its result; invalid native readings run the original `player.GetWorldPosition()`. Null receivers also take the original expression path. It uses neither the unproven frame-keyed `GCETPlayerVector4()` snapshot nor any cached vector.
- **Admission:** this helper must be used **only** for source-proven local-player receivers. A typed `PlayerPuppet` argument is insufficient on its own; NPC, vehicle, aliases with unresolved caller identity and stored historical positions are not authorized. A native on-demand read is not automatically faster than the author getter and does not authorize removing callbacks or changing timing.
- **Staging:** GCO requires the exact framework-owned optional adapter and CET owner DLL together; native-capability and bridge-shape validation happens before any native output. Core `StateCache` and `NativeLocationSignals` stay independent of optional symbols.
- **Verification:** [G-REDruntime #10 SUCCESS](https://github.com/giorgioherma/G-REDruntime_Framework/actions/runs/44599499137) verifies source contracts including negative failures for missing validity and original fallback. Official full-stack SCC and gameplay/runtime ABI parity remain separate acceptance gates, not claimed by this framework-only CI.



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
