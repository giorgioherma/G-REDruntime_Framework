# Player lifecycle shared-state signal (development contract)

**Owner:** G-REDruntime `main`. **Status:** source-level implementation for REDscript source consumers; real gameplay and measured performance are unverified. This is an additive contract in the existing `Runtime` + `StateCache`, not a second scheduler, polling service or CET native ABI.

## Authoritative producer

`GRedRuntime.Runtime` receives the engine's `PlayerAttachRequest` and `PlayerDetachRequest` as `ScriptableSystem` lifecycle notifications. The current live REDscript mod stack independently contains both notifications in working ScriptableSystem patterns; the implementation does not guess state transitions from frame time.

- **Attach:** `StateCache.SetPlayer(player)` records the current weak player reference, marks it known if defined and increments `GetPlayerSignalGeneration()`. Runtime then invalidates its existing `ContextService`, rebinds the existing `InputHub`, marks `DirtyFlags.PLAYER`, and publishes `PLAYER / ATTACHED` only when listeners exist.
- **Detach:** if `request.owner` names an earlier player different from the currently signaled player, ignore it. Otherwise `InvalidatePlayer()` first clears the weak handle, sets status to **UNKNOWN**, blocks re-adoption into the shared cache until the next authoritative attach, and increments generation. Runtime invalidates its context, unregisters existing input bridges / stops its opt-in device observation through `InputHub.OnPlayerUnavailable()`, marks `DirtyFlags.PLAYER`, and publishes `PLAYER / DETACHED` only when subscribed.
- **Shutdown:** invalidates signal knowledge and weak reference, bumps generation. The runtime's existing shutdown and owner cleanup remain authoritative.

## Consumer contract

Read only after confirming `Runtime.Get(game)` is defined and `runtime.IsReady()` is true:

```reds
let state = runtime.GetStateCache();
let epoch = state.GetPlayerSignalGeneration();
if state.HasAuthoritativePlayer() {
    let player = state.GetAttachedPlayer();
    // Current signaled player reference is valid for this access.
} else {
    // UNKNOWN: use the original live source getter if required.
}
```

`HasAuthoritativePlayer()` means a valid handle was observed through an attach notification and remains defined. It does **not** imply combat, mounted vehicle, location, menu, blackboard values, inventory state, or player position is current. `GetPlayerSignalGeneration()` is a change/invalidation token **within one Runtime lifetime**, not a saved-game identifier or global monotonic time; do not persist it.

`StateCache.GetPlayer()` preserves its historical lazy PlayerSystem lookup before the first authoritative player event. After a detach, it calls the original PlayerSystem getter **on demand without caching the returned player as authoritative**. InputHub separately refuses registration and device notifications until the next attach, even if that live getter still returns the old player during a transition. Source-generated adapters must retain the **original author getter** when the signal is UNKNOWN, when the framework is missing, or when a session replaces its Runtime. No generic override of existing player-getter semantics is approved by this service alone.

## Proof and remaining gates

- Owner source: `r6/scripts/G-RedRuntime/Core/Runtime.reds`, `State/StateCache.reds`; no new owner files, extra subscriptions or high-frequency pollers.
- GCO `dev/redscript/resolver_handoff` compiles the authoritative framework checkout with the private 2,319-file effective REDscript source stack and official SCC 0.5.31. The same workflow runs mutation-backed lifecycle contracts for missing detach, stale-owner mismatch, forgotten listener cleanup, re-acquiring between detach and attach, and missing generation invalidation.
- **Not proven by these source tests or SCC:** engine/gameplay detach timing, reentrant subscription behavior under real scene reload, runtime CPU savings, cross-mod generic consumers, or safe substitution of combat/vehicle/NEAR-FAR/ink state. A matched game test and a source-admitted consumer are prerequisites to shipping optimizations.

Do not add generic state-change polling, add another framework-wide timer, conflate `DirtyFlags` with value authority, or replace unrelated mod state without explicit source and lifecycle proof.

## Shared source-generated player provider (2026-11-18)

The existing `StateCache.reds` now also contains `GRedRuntime.SharedProviders`. This is only a thin facade over `Runtime.Get(game)` and `StateCache`; it creates no second player producer, listener, timer or cache. Methods:

- `Player(game)`: returns the `StateCache.GetAttachedPlayer()` only when the authoritative attach signal is known and the handle valid; else calls the original live `GameInstance.GetPlayerSystem(game).GetLocalPlayerMainGameObject() as PlayerPuppet`.
- `Quests(game)`: uses the existing cached `QuestsSystem` when the runtime is ready; else the original `GameInstance.GetQuestsSystem(game)`.
- `Delay(game)`: uses the existing cached `DelaySystem` when ready; else the original `GameInstance.GetDelaySystem(game)`.

GCO REDscript Resolver development branch generates the exact typed player-getter consumer using `import GRedRuntime.*` and `SharedProviders.Player(game)` under `SHARED_PLAYER_SIGNAL_V1`. The current source replay found 46 syntactically eligible callsites across 17 live files in its snapshot. **Those are syntactic rewrites, not proof of performance gain or gameplay equivalence.** A source-level/compiler pass does not assert game-test acceptance.

The separately generated CET C++ player position/location coordinator remains owned by CET. The REDscript native RTTI adapter is staged by GCO and is not part of this StateCache; neither requires or creates duplicate location observation.

