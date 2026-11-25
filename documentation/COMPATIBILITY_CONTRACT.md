# G-REDruntime compatibility contract

G-REDruntime is a shared REDscript runtime. It adapts to the normal Cyberpunk 2077 REDscript mod layout; third-party mods are not required to adopt a G-REDruntime package format.

## Non-negotiable layout rules

Third-party integrations must preserve the mod's normal install structure.

```text
original:
r6/scripts/<existing mod path>/...

integrated:
r6/scripts/<same existing mod path>/...
r6/scripts/G-RedRuntime/...          <- shared framework core only
```

An integration must not require a mod to:

- move under `r6/scripts/G-RedRuntime`;
- rename its existing top-level folder merely for framework compatibility;
- add a G-REDruntime or GRSP manifest;
- rename public modules, classes or methods merely to fit the framework;
- install a shadow copy of the mod in a framework-specific directory.

The framework core must compile and remain dormant with zero integrations, against the vanilla game script cache and REDscript alone. No optional third-party script provider or global logging declarations may be required. Manual diagnostic output is returned to the caller; no global logging headers are introduced.

## Supported integration forms

### 0. Transparent core service

No third-party source change.

Use this only when a shared optimization can be supplied without changing mod semantics, for example framework-owned state/cache infrastructure or a proven engine-level bridge.

### 1. Additive in-place adapter

The original mod files remain at their existing paths. A small integration file may be added beside them when it can consume the mod's existing public surface without changing it.

Example:

```text
r6/scripts/ExistingMod/ExistingFiles.reds
r6/scripts/ExistingMod/GRedRuntimeAdapter.reds
```

The adapter is shipped with the integration patch, not with the framework core, because referencing an optional mod type from the core would make that mod a hard compile dependency.

### 2. Differential in-place implementation patch

When a measured optimization requires changing the mod's implementation, patch only the necessary existing source files at their original paths.

The integration should preserve:

- the mod's package/folder layout;
- public type and method names where possible;
- expected external behavior;
- dependencies and load assumptions unrelated to the optimization.

A differential patch may change implementation code. "Unchanged mod format" is a compatibility rule, not a requirement that all third-party files remain byte-identical.

## What the framework must not do

G-REDruntime must not become a generic source rewriter that guesses at arbitrary mods.

Unknown mods remain untouched until profiler evidence and a reviewed integration establish a safe optimization boundary.

No optimization should be applied solely because two functions have similar names or cadence. GRSP evidence can identify candidates, but semantic compatibility must be established before an integration is shipped.

## Ownership model shared with GRSP

For profiling and integration planning, the existing REDscript source layout is authoritative:

```text
r6/scripts/ModName/.../*.reds  -> ModName
r6/scripts/Foo.reds            -> Foo
```

Foldered and root-level REDscript mods are both valid. Absolute/game-relative paths and slash direction are profiler concerns, not requirements imposed on the mod.

## Packaging rule

Framework and integration releases remain separate:

```text
G-REDruntime core
  -> only framework-owned files

per-mod integration overlay
  -> only new/changed files for that mod
  -> mirrors the mod's existing game-root paths
```

This keeps the framework reusable and prevents one optional integration from turning another mod into a required dependency.

## Acceptance gate

A compatibility integration is accepted only after:

```text
compile
runtime load
feature regression test
GRSP comparison
CapFrameX comparison when frame pacing is relevant
restore/uninstall verification for the patch package
```

If preserving the mod's public behavior or package contract cannot be demonstrated, the integration stays experimental or the mod stays untouched.
