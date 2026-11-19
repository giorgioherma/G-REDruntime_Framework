"""G-REDruntime owner contracts for optional CET-native site subscriptions.

Source-level tests, not REDscript SCC or gameplay. These check failure modes
that would otherwise silently break multi-mod location consumers.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "r6/scripts/G-RedRuntime"
NATIVE = ROOT / "optional-native/r6/scripts/G-RedRuntime/Native/GCETNativeLocationBackend.reds"


def body(source: str, name: str) -> str:
    match = re.search(r"\bfunc\s+" + re.escape(name) + r"\s*\(", source)
    if match is None:
        raise AssertionError("MISSING_METHOD_" + name)
    brace = source.find("{", match.end())
    if brace == -1:
        raise AssertionError("NO_BODY_" + name)
    depth = 0
    for pos in range(brace, len(source)):
        if source[pos] == "{":
            depth += 1
        elif source[pos] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1 : pos]
    raise AssertionError("UNBALANCED_" + name)


def verify(runtime: str, signals: str, backend: str) -> None:
    attach = body(runtime, "OnAttach")
    detach = body(runtime, "OnDetach")
    on_attach = body(runtime, "OnPlayerAttach")
    on_detach = body(runtime, "OnPlayerDetach")
    subscribe = body(signals, "SubscribeLocation")
    unsubscribe = body(signals, "UnsubscribeLocation")
    job = body(signals, "EnsureJob")
    shutdown = body(signals, "Shutdown")
    tick = body(signals, "Tick")
    read = body(signals, "ReadSnapshot")
    invalid = body(signals, "InvalidateSession")

    for item in (
        "this.m_nativeLocations = new NativeLocationSignals()",
        "this.m_nativeLocations.Initialize(this.m_scheduler, this.m_dirty)",
    ):
        assert item in attach, "MISSING_SHARED_SERVICE"
    assert attach.index("this.m_scheduler.Initialize") < attach.index(
        "this.m_nativeLocations.Initialize"), "SCHEDULER_OWNER_ORDER"
    assert detach.index("this.m_nativeLocations.Shutdown()") < detach.index(
        "this.m_scheduler.Shutdown()"), "SHUTDOWN_ORDER"
    assert "GetNativeLocations()" in runtime, "MISSING_PUBLIC_SERVICE"
    for part in (on_attach, on_detach):
        assert "this.m_nativeLocations.InvalidateSession()" in part, (
            "SESSION_STALE_NEAR_FAR")
    for existing in ("this.m_state.SetPlayer(player)", "this.m_state.InvalidatePlayer()"):
        assert existing in on_attach + on_detach, "PLAYER_LIFECYCLE_LOST"

    assert "GameInstance.GCETStatic" not in signals, (
        "OPTIONAL_NATIVE_SYMBOL_LEAKS_INTO_CORE")
    assert "GameInstance.GCETStatic" not in runtime, (
        "NATIVE_DLL_REQUIRED_FOR_UNTOUCHED_FRAMEWORK")
    assert "public class NativeLocationBackend" in signals
    assert "public class NativeLocationListener" in signals

    assert "this.m_backend = backend" in subscribe
    assert "existing.interestCount += 1" in subscribe, "DUPLICATE_NATIVE_OWNER_WATCH"
    assert "return this.AddInterest(owner, index, listener)" in subscribe
    assert "this.EnsureJob()" in subscribe
    assert "this.m_activeInterests -= 1" in unsubscribe
    assert "watch.interestCount -= 1" in unsubscribe
    assert "this.Stop()" in unsubscribe
    assert "if this.m_activeInterests == 0" in unsubscribe, (
        "LAST_SUBSCRIBER_DOES_NOT_STOP")
    assert "this.m_scheduler.Register(this.m_job)" in job
    assert "this.m_scheduler.Unregister(this.m_jobID)" in signals
    assert "this.m_consumer = 1702404" in signals, "CET_STREAM_COLLISION"
    assert "this.m_backend.Subscribe(this.m_consumer)" in tick
    assert "this.m_backend.Poll(this.m_consumer)" in tick
    assert "this.m_backend.NeedsSnapshot(this.m_consumer)" in tick
    assert "this.ReadSnapshot()" in tick
    assert "this.m_activeInterests <= 0" in tick, "LAST_UNSUBSCRIBE_REENTRANCY"
    assert "this.m_backend.OwnerCount(watch.owner) != watch.expectedCount" in read
    assert "this.m_backend.OwnerAnchor(watch.owner, watch.index)" in read
    assert "value != 0 && value != 1" in read, "UNKNOWN_AS_FAR"
    assert "this.m_backend.AckSnapshot(this.m_consumer)" in read
    assert "this.m_snapshotRequired = true" in invalid
    assert "watch.state = -1" in invalid, "STALE_SESSION_VALUE"
    assert "ArrayPush(owners, watch.owner)" in invalid, "INVALIDATION_TARGET_SNAPSHOT_MISSING"
    assert "ArrayPush(indexes, watch.index)" in invalid, "INVALIDATION_TARGET_SNAPSHOT_MISSING"
    assert "this.Deliver(owners[j], indexes[j], -1)" in invalid, "UNKNOWN_DELIVERY_MISSING"
    assert 'this.m_dirty.Mark(n"LOCATION")' in invalid
    assert "this.ResetNative()" in shutdown or "this.Stop()" in shutdown
    assert "entry.listener = null" in shutdown, "RETAINED_MOD_CALLBACK"

    # The existing CET runtime uses low-range source owners. Do not disarm
    # anchors that are shared with CET: reserved RED-generated ownership only.
    assert "watch.owner >= 100000000" in read, "FOREIGN_NATIVE_ANCHOR_MUTATED"

    expected = (
        "GCETStaticReady", "GCETStaticCoordinatorState",
        "GCETStaticOwnerCount", "GCETStaticOwnerAnchor", "GCETStaticState",
        "GCETStaticArm", "GCETStaticSubscribe", "GCETStaticUnsubscribe",
        "GCETStaticNeedsSnapshot", "GCETStaticAckSnapshot",
        "GCETStaticPoll", "GCETStaticPolledOwner", "GCETStaticPolledState"
    )
    for api in expected:
        assert ("native func " + api) in backend, "MISSING_CPP_ABI_" + api
    assert "extends NativeLocationBackend" in backend
    assert "GCETStaticSubscribe(consumer, 0)" in backend

    # Same CET C++ DLL also exposes typed STRICT-LIVE Vector4. Do not
    # accidentally bind the frame-keyed cached snapshot or invent polling.
    assert re.search(
        r"native func GCETPlayerVector4Live\(\) -> Vector4", backend
    ), "LIVE_VECTOR_RTTI_SIGNATURE_MISSING"
    assert re.search(
        r"native func GCETPlayerVector4Valid\(\) -> Bool", backend
    ), "LIVE_VECTOR_VALIDITY_RTTI_SIGNATURE_MISSING"
    assert "native func GCETPlayerVector4()" not in backend, (
        "UNPROVEN_FRAME_CACHED_VECTOR_ADOPTED")
    native_vector = body(backend, "LiveOrOriginal")
    assert "if !IsDefined(player)" in native_vector, (
        "NULL_RECEIVER_ORIGINAL_SEMANTICS_LOST")
    assert native_vector.count("return player.GetWorldPosition();") == 2, (
        "ORIGINAL_PLAYER_GETTER_FALLBACK_LOST")
    live_at = native_vector.find("GameInstance.GCETPlayerVector4Live()")
    valid_at = native_vector.find("GameInstance.GCETPlayerVector4Valid()")
    return_at = native_vector.find("return position;")
    assert 0 <= live_at < valid_at < return_at, (
        "LIVE_VECTOR_VALIDATION_ORDER")
    assert not re.search(r"\b(?:GCETPlayerVector4\s*\(|Schedule\.|Tick\s*\()", native_vector), (
        "LIVE_VECTOR_EXTRA_SNAPSHOT_OR_POLLER")
    assert "GCETPlayerVector4Live" not in runtime + signals, (
        "OPTIONAL_VECTOR_NATIVE_DEPENDENCY_LEAKS_INTO_CORE")

    # Source-driven location cohorts must reuse the SAME shared service,
    # native stream and lifecycle rather than creating mod-owned timers.
    assert "public class NativeLocationGroupListener" in signals
    assert "public func AllLocationGroupFar(" in signals
    group = body(signals, "AllLocationGroupFar")
    assert "this.SubscribeLocation(owner, i, expected," in group
    assert "this.m_nativeSubscribed" in group
    assert "this.m_snapshotRequired" in group
    assert "group.listener.AllFar()" in group
    assert "backend.OwnerCount(owner) != expected" in group
    assert "for prior in group.tokens { this.UnsubscribeLocation(prior); }" in group
    assert "ArrayClear(this.m_groups);" in shutdown
    assert "public abstract class GCETNativeLocationGuard" in backend
    gate = body(backend, "DefinitelyFarPlayer")
    assert "player != local" in gate
    assert "service.AllLocationGroupFar(" in gate
    assert "service.HasLocationGroup(owner, expected)" in gate
    assert "owner, expected, null" in gate
    assert gate.index("service.HasLocationGroup(") < (
        gate.index("new GCETNativeLocationBackend()"))
    assert "GetPlayer(game)" in gate
    assert "Schedule" not in gate
    assert "GCETStatic" not in gate
    assert "GameInstance.GCETStatic" not in signals


class FrameworkNativeLocationContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.runtime = (CORE / "Core/Runtime.reds").read_text(encoding="utf-8")
        cls.signals = (CORE / "Location/NativeLocationSignals.reds").read_text(
            encoding="utf-8")
        cls.backend = NATIVE.read_text(encoding="utf-8")

    def test_native_optionality_and_subscribers(self):
        verify(self.runtime, self.signals, self.backend)

    def test_reject_missing_player_invalidation(self):
        broken = self.runtime.replace(
            "this.m_nativeLocations.InvalidateSession();", "", 1)
        with self.assertRaisesRegex(AssertionError, "SESSION_STALE_NEAR_FAR"):
            verify(broken, self.signals, self.backend)

    def test_reject_last_consumer_leaving_job_running(self):
        broken = self.signals.replace(
            "if this.m_activeInterests == 0 {\n          this.Stop();",
            "if false {\n          this.Stop();")
        with self.assertRaisesRegex(AssertionError,
                                    "LAST_SUBSCRIBER_DOES_NOT_STOP"):
            verify(self.runtime, broken, self.backend)

    def test_reject_unknown_state_as_far(self):
        broken = self.signals.replace(
            "watch.state = -1;\n        ArrayPush(owners, watch.owner);",
            "watch.state = 0;\n        ArrayPush(owners, watch.owner);")
        with self.assertRaisesRegex(AssertionError, "STALE_SESSION_VALUE"):
            verify(self.runtime, broken, self.backend)

    def test_reject_missing_native_snapshot_ack(self):
        broken = self.signals.replace(
            "if !this.m_backend.AckSnapshot(this.m_consumer)",
            "if false")
        with self.assertRaisesRegex(AssertionError, ""):
            verify(self.runtime, broken, self.backend)

    def test_reject_missing_rtti_api_in_optional_backend(self):
        broken = self.backend.replace(
            "native func GCETStaticPolledState",
            "native func WrongPolledState")
        with self.assertRaisesRegex(AssertionError, "MISSING_CPP_ABI"):
            verify(self.runtime, self.signals, broken)

    def test_reject_unverified_group_far(self):
        broken = self.signals.replace(
            "this.m_snapshotRequired { return false; }",
            "false { return false; }", 1)
        with self.assertRaisesRegex(AssertionError, ".*"):
            verify(self.runtime, broken, self.backend)

    def test_reject_missing_strict_live_vector_validation(self):
        broken = self.backend.replace(
            "if GameInstance.GCETPlayerVector4Valid() {",
            "if true {")
        with self.assertRaisesRegex(AssertionError, "LIVE_VECTOR_VALIDATION_ORDER"):
            verify(self.runtime, self.signals, broken)

    def test_reject_snapshot_cache_instead_of_live_getter(self):
        broken = self.backend.replace(
            "GameInstance.GCETPlayerVector4Live();",
            "GameInstance.GCETPlayerVector4();")
        with self.assertRaisesRegex(AssertionError, "LIVE_VECTOR_VALIDATION_ORDER"):
            verify(self.runtime, self.signals, broken)

    def test_reject_lost_player_getter_fallback(self):
        broken = self.backend.replace(
            "return player.GetWorldPosition();",
            "return position;", 1)
        with self.assertRaisesRegex(AssertionError, "ORIGINAL_PLAYER_GETTER_FALLBACK_LOST"):
            verify(self.runtime, self.signals, broken)


if __name__ == "__main__":
    unittest.main(verbosity=2)
