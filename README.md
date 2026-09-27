# G-REDruntime Developer Blueprint

This document describes the public architecture and intended integration model of G-REDruntime `0.6.0`.

It is written for REDscript mod developers and integration authors. The goal is not only to list methods, but to explain what each service owns, when it is appropriate, what assumptions it makes, and how to integrate it without changing the identity or behavior of the mod being optimized.

---

# 1. Core design

G-REDruntime exists to reduce duplicated REDscript runtime work across compatible mods.

The framework is built around one rule:

> **Shared work should be performed once where possible and reused by compatible consumers.**

That does not mean every callback, timer or lookup should be centralized. An integration should only move work into the framework when the behavior, lifetime and invalidation rules are understood.

A useful model is:

```text
game state / input / existing mod callback
                  │
                  ▼
            G-REDruntime
                  │
       ┌──────────┼───────────┐
       ▼          ▼           ▼
     cache     shared       routed
               timing       events
       │          │           │
       └──────────┴───────────┘
                  │
                  ▼
        compatible consumers
```

G-REDruntime is **event-first, but not event-only**. Polling is still appropriate when no reliable event boundary exists. The goal is to avoid duplicated or unnecessarily frequent work, not to replace every poll with a more complicated abstraction.

---

# 2. Runtime lifecycle

The framework core is a `ScriptableSystem`:

```reds
GRedRuntime.Runtime
```

During `OnAttach()` it creates and initializes the shared services in this order:

```text
Diagnostics
StateCache
DirtyFlags
ContextService
EventBus
Scheduler
InputHub
HookBus
```

The Scheduler is initialized before InputHub because InputHub uses it for low-frequency input-device observation.

When the runtime detaches, the framework shuts down its services and cancels scheduler activity.

On player attach, the runtime:

1. resolves the local `PlayerPuppet`;
2. updates `StateCache`;
3. invalidates shared context;
4. informs `InputHub` that the player is available;
5. marks the `PLAYER` dirty flag;
6. publishes a `PLAYER / ATTACHED` runtime event when that topic has subscribers.

## Accessing the runtime

From code that already has a `GameInstance`:

```reds
let runtime = GRedRuntime.Runtime.Get(game);

if !IsDefined(runtime) || !runtime.IsReady() {
  return;
}
```

The runtime exposes:

```reds
runtime.GetStateCache()
runtime.GetDirtyFlags()
runtime.GetEventBus()
runtime.GetInputHub()
runtime.GetScheduler()
runtime.GetContextService()
runtime.GetHookBus()
runtime.GetDiagnostics()
```

Version:

```reds
runtime.GetVersion()
```

Current source version:

```text
0.6.0
```

Do not cache the `Runtime` across a lifetime where the game/system container itself may be torn down and recreated unless your integration already has a lifecycle that guarantees the reference remains valid.

---

# 3. StateCache

## Purpose

`StateCache` provides lazy cached access to game systems that are frequently resolved by REDscript mods.

Instead of repeatedly doing this inside hot callbacks:

```reds
let quests = GameInstance.GetQuestsSystem(game);
```

an integration can use:

```reds
let quests = runtime.GetStateCache().GetQuestsSystem();
```

The first request resolves the system. Later requests reuse the cached weak reference while it remains defined.

## Available getters

The current framework exposes:

```reds
GetGame()
GetPlayer()

GetPlayerSystem()
GetQuestsSystem()
GetStatsSystem()
GetDelaySystem()
GetTransactionSystem()
GetBlackboardSystem()
GetScriptableSystemsContainer()
GetTimeSystem()
GetUISystem()
GetStatPoolsSystem()
GetTargetingSystem()
GetMarketSystem()
GetSystemRequestsHandler()
GetPreventionSystem()
```

Player-specific helpers:

```reds
SetPlayer(player)
InvalidatePlayer()
```

`Runtime` manages the normal player-attach path for the framework.

## Example

```reds
let runtime = GRedRuntime.Runtime.Get(game);
if !IsDefined(runtime) {
  return;
}

let state = runtime.GetStateCache();
let player = state.GetPlayer();
let quests = state.GetQuestsSystem();

if !IsDefined(player) || !IsDefined(quests) {
  return;
}
```

## When to use it

Good candidate:

```text
hot callback
  ↓
same stable game-system getter
  ↓
called repeatedly
```

Use `StateCache` when the returned handle has a lifetime that is safe to reuse for the current game session.

## When not to use it

Do not use `StateCache` as a generic cache for arbitrary changing gameplay values.

Examples such as:

```text
current combat state
mounted vehicle
current derived mod state
temporary target
changing quest-derived condition
```

need their own invalidation or refresh rules.

For some shared gameplay context, use `ContextService`. For mod-owned derived state, use explicit invalidation or `DirtyFlags`.

---

# 4. ContextService

## Purpose

`ContextService` provides shared access to selected gameplay context that changes over time but does not necessarily need to be re-evaluated on every call.

Current public methods:

```reds
GetPlayer()
GetMountedVehicle()
IsInCombat()
Invalidate()
```

The mounted-vehicle and combat checks use a `0.05` second refresh window.

This is **demand-driven**, not a permanent 20 Hz polling loop. The underlying state is refreshed when a consumer asks for it and the cached result is older than the refresh window.

## Example

```reds
let context = runtime.GetContextService();

let player = context.GetPlayer();
let vehicle = context.GetMountedVehicle();
let inCombat = context.IsInCombat();
```

## Dirty flags emitted by ContextService

When the detected mounted vehicle changes:

```text
VEHICLE
```

is marked dirty.

When a previously known combat state changes:

```text
COMBAT
```

is marked dirty.

The runtime invalidates ContextService when a player attaches.

## Use case

Instead of several compatible systems independently doing:

```text
GetPlayer()
GetMountedVehicle()
GetMountedVehicle()
GetMountedVehicle()
...
```

within the same short time window, they can share the context result.

Do not assume ContextService contains every useful game-state value. It should remain selective. Add shared context only when there is a demonstrated multi-consumer reason for it.

---

# 5. Scheduler

## Purpose

`Scheduler` provides one lazy `DelaySystem`-based runtime scheduler for compatible recurring and one-shot work.

It is intended for work that:

- does not need to run every frame;
- already runs on a timer;
- can safely run at a defined cadence;
- benefits from sharing scheduling infrastructure with other jobs.

The scheduler stays dormant when no jobs are registered.

## Job class

Create a job by subclassing:

```reds
GRedRuntime.ScheduledJob
```

and implement:

```reds
public func Execute(runtime: ref<GRedRuntime.Runtime>) -> Void
```

Example:

```reds
public class MyRuntimeJob extends GRedRuntime.ScheduledJob {
  public func Execute(runtime: ref<GRedRuntime.Runtime>) -> Void {
    let player = runtime.GetStateCache().GetPlayer();

    if !IsDefined(player) {
      return;
    }

    // recurring work
  }
}
```

## Configure and register

```reds
let job = new MyRuntimeJob();

job.Configure(
  n"MyRuntimeJob",
  0.25,
  true
);

let handle = runtime.GetScheduler().Register(job);
```

`Configure()` arguments:

```text
name
interval in seconds
repeat
```

Intervals below `0.05` seconds are clamped to `0.05`.

The scheduler returns an integer handle.

Store the handle if the job may later be removed or rescheduled.

## Repeating job

```reds
job.Configure(n"MyRepeatingJob", 0.50, true);
let handle = runtime.GetScheduler().Register(job);
```

## One-shot job

```reds
job.Configure(n"MyOneShot", 0.25, false);
let handle = runtime.GetScheduler().Register(job);
```

For a one-shot job, the configured interval is the initial delay before execution.

After it executes, the scheduler retires it automatically unless the job has already changed its own state.

## Unregister

```reds
runtime.GetScheduler().Unregister(handle);
```

## Reschedule

```reds
runtime.GetScheduler().RescheduleJob(
  handle,
  1.00,
  0.25
);
```

Arguments:

```text
job handle
new interval
delay before next execution
```

The requested delay is also clamped to at least `0.05` seconds.

Use `RescheduleJob()` when changing a live registered job. Calling `SetInterval()` on the job object changes the stored interval, but does not by itself rebuild the scheduler's already-selected next wakeup.

## Scheduling behavior

The scheduler:

- owns one current `DelaySystem` callback;
- finds the nearest active deadline;
- wakes for that deadline;
- runs all jobs that are due;
- schedules the next nearest deadline.

For repeating jobs it attempts to preserve cadence.

If a hitch or load causes a deadline to be missed, the scheduler does **not** replay a backlog of missed executions. The next deadline is moved forward from the current time.

This is intentional. A temporary stall should not produce a burst of old timer work afterward.

## Registration during execution

Registering or unregistering scheduler jobs from inside a running scheduler job is supported by the current implementation. Structural cleanup and selection of the next wakeup are handled after the active tick.

## Important integration rule

Do not move a callback to the shared scheduler simply because it is frequent.

First establish that the original feature does not require:

- frame-accurate execution;
- a tighter latency guarantee;
- engine callback ordering that the scheduler would change.

The correct cadence is a behavior requirement, not just a performance setting.

---

# 6. InputHub

## Purpose

`InputHub` provides shared player-input registration and routing.

It supports:

- action-specific subscriptions;
- wildcard subscriptions;
- input consumption propagation;
- input-device change subscriptions;
- lazy engine listener registration;
- automatic listener removal when no corresponding subscribers remain.

## Input listener

Create a listener by subclassing:

```reds
GRedRuntime.InputListener
```

Example:

```reds
public class MyInputListener extends GRedRuntime.InputListener {
  public func OnGRedInput(evt: ref<GRedRuntime.InputEvent>) -> Void {
    if Equals(evt.actionName, n"Jump") {
      // handle input
    }
  }
}
```

Subscribe:

```reds
let listener = new MyInputListener();

let handle = runtime.GetInputHub().Subscribe(
  n"Jump",
  listener
);
```

## Specific actions are preferred

If the integration only needs one or a small set of actions, subscribe to those actions directly.

```reds
Subscribe(n"Jump", listener)
Subscribe(n"Choice1", listener)
Subscribe(n"Reload", listener)
```

The hub deduplicates engine registration for specific action names.

This is preferable to receiving every player action and filtering afterward.

## Wildcard input

To receive all input traffic:

```reds
runtime.GetInputHub().SubscribeAll(listener);
```

or:

```reds
runtime.GetInputHub().Subscribe(n"*", listener);
```

The current implementation also treats an empty `CName` as wildcard:

```reds
n""
```

Use wildcard subscriptions only when the consumer genuinely needs global input traffic.

## InputEvent

Callbacks receive:

```reds
GRedRuntime.InputEvent
```

with:

```reds
evt.actionName
evt.actionType
evt.consumed
```

A listener may set:

```reds
evt.consumed = true;
```

The hub returns the resulting consumed state through its input bridge.

The `InputEvent` object is reused internally for synchronous dispatch. Treat it as callback-scoped data.

**Do not store the `InputEvent` reference for later use.**

Copy individual values if they must survive beyond the callback.

## Unsubscribe

```reds
runtime.GetInputHub().Unsubscribe(handle);
```

## Wildcard and specific registrations

The current implementation uses separate engine bridges for wildcard traffic and action-specific traffic.

If both wildcard and specific subscriptions exist, both registration paths may be active.

Do not build integration correctness around an assumption that wildcard and specific delivery are one single combined callback path. Prefer specific subscriptions where possible and use wildcard only when it is actually required.

## Subscription changes during callback dispatch

The current InputHub mutates its subscription arrays directly during `Unsubscribe()`.

For public integrations, the safe contract is:

> **Do not structurally add/remove InputHub subscriptions from inside the same active input callback unless that exact behavior has been tested.**

Perform subscription lifecycle changes outside the active `OnGRedInput()` dispatch.

## Input-device changes

Subclass:

```reds
GRedRuntime.InputDeviceListener
```

and implement:

```reds
public func OnGRedInputDeviceChanged(lastUsedKBM: Bool) -> Void
```

Register:

```reds
let handle = runtime.GetInputHub().SubscribeDevice(listener);
```

Remove:

```reds
runtime.GetInputHub().UnsubscribeDevice(handle);
```

When at least one device subscriber exists, InputHub creates a scheduler-backed polling job at:

```text
0.10 seconds
```

The polling job is removed when there are no device subscribers.

The first observation establishes the baseline device state and does not emit a change callback.

---

# 7. DirtyFlags

## Purpose

`DirtyFlags` support invalidation-driven work.

Instead of repeatedly recalculating derived state:

```text
check
check
check
check
```

a producer can mark the relevant state when it changes:

```reds
runtime.GetDirtyFlags().Mark(n"MY_STATE");
```

Consumers then decide whether work needs to be repeated.

## API

```reds
Mark(name)
IsDirty(name)
Consume(name)
Version(name)
ChangedSince(name, lastSeenVersion)
ClearAll()
```

## Mark

```reds
let version = runtime.GetDirtyFlags().Mark(n"MY_STATE");
```

`Mark()`:

- creates the flag if needed;
- sets it dirty;
- increments its monotonically increasing `Uint32` version;
- returns the new version.

## IsDirty

```reds
if runtime.GetDirtyFlags().IsDirty(n"MY_STATE") {
  // state has been marked
}
```

This does not clear the flag.

## Consume

```reds
if runtime.GetDirtyFlags().Consume(n"MY_STATE") {
  // handle the change once
}
```

`Consume()` clears the flag's shared dirty state.

### Important: Consume is global

`Consume()` is appropriate when there is effectively one consumer for that dirty state.

If several independent consumers need to observe the same change, do **not** make them compete over one shared consume-once flag.

Use the version model instead.

## Version-based observation

Producer:

```reds
runtime.GetDirtyFlags().Mark(n"MY_STATE");
```

Consumer:

```reds
let dirty = runtime.GetDirtyFlags();

if dirty.ChangedSince(n"MY_STATE", this.m_lastSeenVersion) {
  this.m_lastSeenVersion = dirty.Version(n"MY_STATE");

  // refresh this consumer's derived state
}
```

Each consumer keeps its own last-seen version, so multiple consumers can independently observe the same generation change.

## ClearAll

```reds
runtime.GetDirtyFlags().ClearAll();
```

This clears dirty booleans but does not reset version numbers.

Use it deliberately. It affects every named dirty flag.

---

# 8. EventBus

## Purpose

`EventBus` provides lightweight topic-based runtime event delivery.

Use it when one producer detects or owns an event and several compatible consumers may need to react to it.

It should not be used merely to replace a direct method call with extra indirection.

## RuntimeEvent

Base event:

```reds
GRedRuntime.RuntimeEvent
```

Fields:

```reds
topic
name
boolValue
intValue
floatValue
nameValue
entityID
```

Create:

```reds
let evt = GRedRuntime.RuntimeEvent.Create(
  n"MY_TOPIC",
  n"CHANGED"
);
```

Example payload:

```reds
evt.boolValue = true;
evt.entityID = entity.GetEntityID();
```

Publish:

```reds
runtime.GetEventBus().Publish(evt);
```

## Listener

Subclass:

```reds
GRedRuntime.EventListener
```

Example:

```reds
public class MyEventListener extends GRedRuntime.EventListener {
  public func OnGRedEvent(evt: ref<GRedRuntime.RuntimeEvent>) -> Void {
    if Equals(evt.name, n"CHANGED") {
      // react
    }
  }
}
```

Subscribe:

```reds
let handle = runtime.GetEventBus().Subscribe(
  n"MY_TOPIC",
  listener
);
```

## Wildcard

Use:

```reds
n"*"
```

to receive all topics.

Unlike InputHub, EventBus wildcard matching is specifically `n"*"`.

## Remove

```reds
runtime.GetEventBus().Unsubscribe(handle);
```

## Check before producing optional events

Where producing the event itself has a cost, a producer can check:

```reds
runtime.GetEventBus().HasSubscribersFor(n"MY_TOPIC")
```

The runtime uses this pattern for its `PLAYER / ATTACHED` event.

## Dispatch behavior

The current implementation delivers synchronously.

Listener work therefore runs inside `Publish()`.

Keep event listeners small and avoid turning the bus into a hidden expensive hot path.

The current EventBus subscription array is modified directly by `Unsubscribe()`. As a public integration rule, avoid restructuring EventBus subscriptions from inside the same active event callback unless that exact behavior has been tested.

---

# 9. HookBus

## Purpose

`HookBus` is dispatch infrastructure for shared hook boundaries.

It does **not** automatically install broad game hooks.

A framework-owned or integration-owned wrapper can detect a reviewed hook boundary once and dispatch a `HookContext` to compatible consumers.

Conceptually:

```text
reviewed REDscript hook/wrapper
          │
          ▼
      HookContext
          │
          ▼
        HookBus
       /   |   \
      /    |    \
 consumer consumer consumer
```

## HookContext

Base context:

```reds
GRedRuntime.HookContext
```

Fields:

```reds
topic
source
entityID
boolValue
intValue
floatValue
nameValue
```

Create:

```reds
let ctx = GRedRuntime.HookContext.Create(
  n"MY_HOOK",
  n"MySource"
);
```

Dispatch:

```reds
runtime.GetHookBus().Dispatch(ctx);
```

## Listener

Subclass:

```reds
GRedRuntime.HookListener
```

and implement:

```reds
public func OnGRedHook(ctx: ref<GRedRuntime.HookContext>) -> Void
```

Register:

```reds
let handle = runtime.GetHookBus().Subscribe(
  n"MY_HOOK",
  listener
);
```

Remove:

```reds
runtime.GetHookBus().Unsubscribe(handle);
```

Wildcard topic:

```reds
n"*"
```

Check:

```reds
runtime.GetHookBus().HasSubscribersFor(n"MY_HOOK")
```

## Integration boundary

Do not put optional-mod-specific wrappers into the G-REDruntime core.

If a wrapper references types owned by an optional mod, keep that wrapper in the integration overlay for that mod. Otherwise the optional mod becomes a hard compile dependency of the framework.

The HookBus is a shared dispatch mechanism, not permission to take over arbitrary hooks globally.

---

# 10. Diagnostics

Diagnostics are counters intended for development and verification.

Current snapshot fields:

```reds
schedulerWakeups
schedulerJobRuns

eventPublishes
eventDeliveries

inputEventsSeen
inputDeliveries

hookDispatches
hookDeliveries

stateCacheHits
stateCacheMisses
```

Get a snapshot:

```reds
let snap = runtime.GetDiagnostics().Snapshot();
```

Reset:

```reds
runtime.GetDiagnostics().Reset();
```

The runtime also exposes:

```reds
runtime.DumpDiagnostics();
```

and adds a helper method to `PlayerPuppet`:

```reds
Game.GetPlayer():GRedRuntimeDump()```

The dump writes to the `G-RedRuntime` log channel.

There is no periodic diagnostic logging in the framework core.

Diagnostics should be treated as development visibility, not as gameplay logic.

---

# 11. Choosing the correct service

A profiler result is evidence that something deserves investigation. It is not automatically evidence that it should be cached, throttled or centralized.

A useful mapping is:

| Observed pattern | Candidate G-REDruntime service | What must be true |
| --- | --- | --- |
| Repeated stable game-system lookup | `StateCache` | The handle is safe to reuse for the intended lifetime |
| Repeated derived state with clear change points | `DirtyFlags` | Every relevant mutation/invalidation path is known |
| Frequently requested shared combat/vehicle context | `ContextService` | Its refresh semantics are sufficient |
| Independent recurring timers | `Scheduler` | The original cadence and latency requirements are preserved |
| Duplicate compatible input handling | `InputHub` | Action filtering and consumption behavior remain correct |
| One producer, several event consumers | `EventBus` | Synchronous delivery and ordering do not break semantics |
| Several consumers at one proven hook boundary | `HookBus` | One wrapper can preserve the original hook behavior |

High call count alone is not enough.

---

# 12. Integration model

G-REDruntime does not require third-party mods to adopt a new package layout.

The original REDscript layout remains authoritative.

```text
original:
r6/scripts/ExistingMod/...

with framework:
r6/scripts/ExistingMod/...
r6/scripts/G-RedRuntime/...
```

Do not:

- move another mod under `G-RedRuntime`;
- rename its folder merely for framework compatibility;
- require a G-REDruntime manifest;
- rename public classes or methods just to fit the framework;
- install a second shadow copy of the mod.

## Preferred integration order

Use the least invasive approach that preserves behavior.

### 1. Transparent use

No third-party source change when the mod can consume a shared service safely through an existing boundary.

### 2. Additive adapter

Keep the original mod intact and add a small integration file beside it.

```text
r6/scripts/ExistingMod/Main.reds
r6/scripts/ExistingMod/Feature.reds
r6/scripts/ExistingMod/GRedRuntimeAdapter.reds
```

The adapter belongs to the integration overlay, not to the framework core.

### 3. Differential implementation patch

Patch only the measured implementation point when the optimization cannot be expressed safely through an additive adapter.

Examples:

- replace a private repeated search with an index;
- reuse a stable value inside a private hot callback;
- move a private timer onto the shared Scheduler;
- add invalidation exactly where the mod changes its own state.

Keep the original path and public surface where possible.

### 4. No integration

If lifetime, invalidation, ordering or behavior cannot be established safely, leave the mod alone.

---

# 13. Optional dependencies

The G-REDruntime core must not reference types belonging to arbitrary optional mods.

Why:

```text
core references OptionalMod.SomeType
                ↓
OptionalMod becomes a compile dependency
```

Instead:

```text
G-REDruntime core
        +
optional integration overlay
        └─ may reference that optional mod
```

This keeps the framework usable whether or not that mod is installed.

---

# 14. Lifecycle and cleanup rules

An integration should own its registrations explicitly.

Store handles for:

```text
Scheduler jobs
InputHub subscriptions
Input-device subscriptions
EventBus subscriptions
HookBus subscriptions
```

and release them when the integration's lifecycle ends.

Example ownership pattern:

```reds
private let m_jobID: Int32;
private let m_inputID: Int32;
private let m_eventID: Int32;
```

Cleanup:

```reds
if this.m_jobID > 0 {
  runtime.GetScheduler().Unregister(this.m_jobID);
  this.m_jobID = 0;
}

if this.m_inputID > 0 {
  runtime.GetInputHub().Unsubscribe(this.m_inputID);
  this.m_inputID = 0;
}

if this.m_eventID > 0 {
  runtime.GetEventBus().Unsubscribe(this.m_eventID);
  this.m_eventID = 0;
}
```

Do not assume that losing your own reference automatically unregisters work from the framework.

---

# 15. Performance rules

G-REDruntime is not useful if it merely moves duplicated work into one permanently expensive central loop.

Use the framework to reduce work, not to hide it.

## Prefer

```text
specific input subscription
over
wildcard input + filtering
```

```text
0.25 s shared scheduled job
over
per-frame polling
```

when the feature does not require frame frequency.

```text
versioned invalidation
over
recalculating stable derived state
```

when every mutation path is known.

```text
shared stable handle
over
repeated system resolution
```

when lifetime is safe.

## Do not

- throttle a callback without proving its latency requirement;
- cache a value without a valid invalidation path;
- centralize unrelated work only because it has a similar frequency;
- replace one cheap direct operation with a more expensive abstraction;
- use wildcard input when specific action registration is sufficient;
- put optional-mod code into the framework core;
- treat profiler call count alone as proof of an optimization.

---

# 16. Example: moving repeated timer work to Scheduler

Before:

```text
Mod A -> its own DelaySystem loop
Mod B -> its own DelaySystem loop
Mod C -> its own DelaySystem loop
```

After, where semantics allow:

```text
                G-REDruntime Scheduler
                 /        |        \
                /         |         \
             Job A      Job B      Job C
```

REDscript:

```reds
public class MyRefreshJob extends GRedRuntime.ScheduledJob {
  public func Execute(runtime: ref<GRedRuntime.Runtime>) -> Void {
    let context = runtime.GetContextService();

    if context.IsInCombat() {
      // refresh feature state
    }
  }
}
```

Registration:

```reds
this.m_refreshJob = new MyRefreshJob();
this.m_refreshJob.Configure(n"MyRefreshJob", 0.25, true);

this.m_refreshJobID =
  runtime.GetScheduler().Register(this.m_refreshJob);
```

Removal:

```reds
runtime.GetScheduler().Unregister(this.m_refreshJobID);
this.m_refreshJobID = 0;
```

---

# 17. Example: shared invalidation with multiple consumers

Producer:

```reds
runtime.GetDirtyFlags().Mark(n"MY_SHARED_STATE");
```

Consumer A:

```reds
let dirty = runtime.GetDirtyFlags();

if dirty.ChangedSince(n"MY_SHARED_STATE", this.m_seenVersion) {
  this.m_seenVersion = dirty.Version(n"MY_SHARED_STATE");
  this.RefreshA();
}
```

Consumer B:

```reds
let dirty = runtime.GetDirtyFlags();

if dirty.ChangedSince(n"MY_SHARED_STATE", this.m_seenVersion) {
  this.m_seenVersion = dirty.Version(n"MY_SHARED_STATE");
  this.RefreshB();
}
```

Neither consumer clears the shared state for the other.

---

# 18. Example: specific InputHub integration

```reds
public class MyJumpListener extends GRedRuntime.InputListener {
  public func OnGRedInput(evt: ref<GRedRuntime.InputEvent>) -> Void {
    if Equals(evt.actionName, n"Jump") {
      // feature logic
    }
  }
}
```

Setup:

```reds
this.m_jumpListener = new MyJumpListener();

this.m_jumpHandle = runtime.GetInputHub().Subscribe(
  n"Jump",
  this.m_jumpListener
);
```

Cleanup:

```reds
runtime.GetInputHub().Unsubscribe(this.m_jumpHandle);
this.m_jumpHandle = 0;
```

Do not use `SubscribeAll()` for this case.

---

# 19. Example: EventBus fan-out

Producer:

```reds
if runtime.GetEventBus().HasSubscribersFor(n"MY_SYSTEM") {
  let evt = GRedRuntime.RuntimeEvent.Create(
    n"MY_SYSTEM",
    n"STATE_CHANGED"
  );

  evt.intValue = newState;
  runtime.GetEventBus().Publish(evt);
}
```

Consumer:

```reds
public class MySystemListener extends GRedRuntime.EventListener {
  public func OnGRedEvent(evt: ref<GRedRuntime.RuntimeEvent>) -> Void {
    if Equals(evt.name, n"STATE_CHANGED") {
      // consume evt.intValue
    }
  }
}
```

---

# 20. Validation workflow

Do not accept an integration from source inspection alone.

A useful workflow is:

```text
1. establish a baseline
2. profile the actual runtime path
3. identify the repeated or expensive work
4. understand the original behavior
5. choose the least invasive framework service
6. compile
7. load the game
8. regression-test the feature
9. profile again
10. compare frame pacing when relevant
```

For this project, GRSP is the profiler used to identify and compare REDscript runtime behavior.

When frame pacing is relevant, use a frame-time capture alongside the REDscript profile.

The important question is not:

> "Did the call count go down?"

It is:

> "Did total runtime work, cost per call, spike behavior or duplicated work improve without changing the feature's behavior?"

---

# 21. Integration packaging

Framework and integrations should remain separate.

```text
G-REDruntime release
└─ only G-REDruntime-owned game files
```

```text
integration overlay
└─ only the new/changed files required for that integration
```

A public framework release should therefore be installable as:

```text
r6/
└─ scripts/
   └─ G-RedRuntime/
```

Documentation does not need to be inside the game archive.

For integration overlays, keep an explicit ownership list for:

```text
added files
modified existing files
original files required for restoration
```

Never blindly overwrite a third-party file that may have changed since the integration was created.

---

# 22. Summary

G-REDruntime is most useful when it provides a proven shared boundary for work that compatible mods would otherwise repeat independently.

Its services solve different problems:

```text
StateCache      -> stable shared game-system references
ContextService  -> lightweight changing shared context
Scheduler       -> recurring / one-shot timing
InputHub        -> shared player-input routing
DirtyFlags      -> invalidation and generation tracking
EventBus        -> shared runtime events
HookBus         -> reviewed shared hook dispatch
Diagnostics     -> development visibility
```

The framework should not decide that work is safe to centralize merely because the profiler shows it is frequent.

The intended process is:

```text
measure
  ↓
understand
  ↓
integrate
  ↓
regression-test
  ↓
measure again
```

That is the core G-REDruntime integration model.