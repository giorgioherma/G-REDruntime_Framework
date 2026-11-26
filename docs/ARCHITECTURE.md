# G-REDruntime approved architecture

The runtime is a vanilla-compatible REDscript ScriptableSystem with shared StateCache, ContextService, Scheduler, InputHub, DirtyFlags, EventBus, HookBus, Diagnostics and opt-in signals. The [developer blueprint](../README.md) is the detailed public API and lifecycle reference.

- One runtime owner, shared scheduler and explicit subscriptions. Use compatible event/dirty-state signals where proven; preserve correct synchronous lookup and polling when necessary. Unknown state retains the original live fallback.
- Player attach/detach establishes and invalidates authoritative handles/generations. Quest facts pool listeners per exact fact with per-consumer tokens, observed/UNKNOWN state and last-release cleanup. These APIs do not alone authorize arbitrary mod source rewrites.
- Experimental native location subscriptions are dormant/opt-in, with shared CET transition drain, per-mod interests and explicit UNKNOWN fallback. No independent player position acquisition. Optional backend declarations stay outside the dependency-free core; existing CET native DLL remains CET-owned.
- GCO generates source-owned per-mod adapters only for accepted rules and includes the framework only when required. No duplicated framework or mandatory new mod format; preserve unrelated source, gameplay, lifetimes and fallback.
- Core sources must compile against vanilla alone; combined source proof and official SCC belong to GCO CI. Owner package contracts and actual gameplay acceptance remain separate.

Detailed contracts: [compatibility](../documentation/COMPATIBILITY_CONTRACT.md), [overlay model](../documentation/INTEGRATION_OVERLAY_MODEL.md), [player signal](../documentation/PLAYER_STATE_SIGNAL_CONTRACT.md), [quest fact signal](../documentation/QUEST_FACT_SIGNAL_CONTRACT.md), [native location signal](../documentation/NATIVE_LOCATION_SIGNAL_CONTRACT.md). The changelog and research are historical evidence, not scope.
