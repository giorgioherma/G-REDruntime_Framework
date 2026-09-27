# G-REDruntime

A REDscript runtime and optimization framework for Cyberpunk 2077.

**Current version:** `0.6.0`  
**Status:** development source; acceptance still depends on compile, runtime, regression and profiling review.

## Purpose

G-REDruntime exists to reduce duplicated REDscript work across a heavily modded Cyberpunk 2077 installation.

The framework is designed around one rule:

> Shared work should be performed once, centrally, and reused by compatible mods.

Instead of multiple mods repeatedly resolving the same game systems, decoding the same input action, polling the same stable state, or stacking equivalent hot-path work, G-REDruntime provides reusable runtime services that integrations can consume.

It is **not a profiler**. GRSP/redscript-profiler is used during development to measure the framework and identify optimization targets, but is not required by G-REDruntime itself.

## Development model

Development is organized into meaningful passes.

Each accepted pass becomes the new base for all later work:

```text
BASE 0
  ↓
Pass 2 tested successfully
  ↓
BASE 1
  ↓
Pass 3 starts from BASE 1
  ↓
...
```

A patch is not considered part of the accepted base until it has passed:

```text
compile
runtime
functional regression testing
profiling/review
```

Later changes to the same file are always built on the last accepted version. Earlier accepted work is never intentionally rolled back.

Third-party mod patches are distributed separately from the framework repository and contain only changed files.

## Pass 1 — Core Framework

Pass 1 established the reusable runtime foundation and has passed compile and runtime testing in the full mod stack.

### Runtime

- `ScriptableSystem` singleton
- lifecycle ownership
- shared component access
- player-attach propagation
- framework version reporting
- manual diagnostics dump

### StateCache

Lazy cached access to commonly reused game systems:

- `PlayerSystem`
- local `PlayerPuppet`
- `QuestsSystem`
- `StatsSystem`
- `DelaySystem`
- `TransactionSystem`
- `BlackboardSystem`
- `ScriptableSystemsContainer`

Cache hit/miss counters are available through diagnostics.

### DirtyFlags

- named dirty flags
- monotonically increasing version/generation per flag
- consume-once dirty checks
- groundwork for version-based shared invalidation

### EventBus

- topic subscriptions
- wildcard subscriptions
- explicit unsubscribe handles
- no dispatch work while empty

### InputHub

Pass 1 introduced the shared input infrastructure:

- one lazily registered input bridge
- no permanent player input listener while unused
- action name/type decoded centrally
- specific-action and wildcard subscriptions
- listener removed when no subscribers remain

### Scheduler

- one lazy central `DelaySystem` loop
- dormant while no jobs exist
- arbitrary interval jobs with a 50 ms minimum
- repeating and one-shot jobs
- stale callback generation guard
- shutdown cancellation

### HookBus

- registration/dispatch infrastructure for future consolidated hooks
- no broad game-hook takeover in Pass 1

### Diagnostics

Counters for:

- scheduler wakeups
- scheduler job executions
- event publications/deliveries
- input observations/deliveries
- hook dispatches/deliveries
- state-cache hits/misses

There is no periodic diagnostic logging.

## Pass 2.0 — Shared Input & Hotpath Integration

Pass 2 is the first real integration pass.

The goal is not to add more framework infrastructure for its own sake. It connects the framework to real workloads and extends the framework only where those integrations require it.

### Framework changes

The Pass 2 InputHub now supports:

- global/wildcard subscriptions
- specific-action subscriptions
- automatic switching between global and action-specific engine registration
- deduplicated registration of specific actions
- input-consumption propagation through `InputEvent.consumed`
- central decoding of `ListenerAction.GetName()` and `ListenerAction.GetType()`

The framework version is now:

```text
0.2.0-pass2
```

### Integration patch set

The associated Pass 2.0 mod patch set targets representative real workloads:

- `custom_quickslots`
- `FlushingEtiquette`
- `BrowserExtension`
- `Enhanced Vehicle System`

The integration patches are intentionally kept outside this repository so third-party mod source is not duplicated here.

The current optimization direction includes:

- consolidating compatible input processing through G-REDruntime
- removing repeated action-name/type decoding
- reducing unnecessary per-action scans
- caching stable or reusable references where behavior remains live
- reducing repeated same-callback lookups in hot vehicle input paths

Pass 2.0 is considered accepted only after its complete patch set passes compile, gameplay regression testing, and profiler comparison.

## Compatibility-first integration

G-REDruntime fits the mod layout already installed; mods do not need to be repackaged into a framework-specific structure.

The compatibility contract is:

```text
preserve existing r6/scripts paths
preserve public mod surface where possible
require no framework-specific manifest
keep optional adapters outside the core
ship measured changes as differential in-place overlays
leave unknown/unproven mods untouched
```

A mod integration may change implementation code when profiling proves the need, but it should not require a new package format. See `documentation/COMPATIBILITY_CONTRACT.md`.

For concrete package/adaptation patterns, see `documentation/INTEGRATION_OVERLAY_MODEL.md`.

## Performance design rules

G-REDruntime is event-first, but not event-only.

The framework avoids replacing many small polling loops with one permanently expensive central loop. Shared state is sampled only where justified, then changes are propagated to consumers.

Conceptually:

```text
game state / input
       ↓
G-REDruntime
       ↓
cache / decode / detect once
       ↓
multiple consumers
```

The framework does **not** use player movement as a global activation boundary. Movement is only relevant to systems that genuinely depend on it.

The framework should remain cheap when integrations are absent.

## Install

Copy the repository's `r6` folder into the Cyberpunk 2077 game root.

Installed framework path:

```text
Cyberpunk 2077/
└─ r6/
   └─ scripts/
      └─ G-RedRuntime/
```

## Dependencies

Required:

- redscript

Not required by the framework core:

- Codeware
- CET
- GRSP / redscript-profiler
- TweakXL
- ArchiveXL

Individual third-party integrations may of course depend on the mods they patch.

## Manual diagnostic check

After loading a save, the framework exposes the manual diagnostic helper used during development:

```text
Game.GetPlayer():GRedRuntimeDump()
```

This is not periodic work. It only logs when explicitly invoked.

## Repository scope

This repository contains the G-REDruntime framework source.

It does **not** contain complete copies of third-party mods.

Optimization releases are kept as differential patch sets containing only:

- changed third-party files
- new integration files
- changed G-REDruntime files when applicable

Framework and third-party mod patches are packaged separately.

## Project status

The repository source currently reports `0.6.0`.

Pass 1 remains the explicitly documented validated baseline. Later passes remain development work until their compile/runtime/regression/profile acceptance is recorded.

The profiler remains enabled during development so each meaningful pass can be compared against the accepted baseline.
