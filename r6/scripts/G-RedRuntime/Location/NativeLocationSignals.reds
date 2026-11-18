module GRedRuntime

// Source owner: G-REDruntime. The core never refers to optional CET native
// symbols. A generated game overlay can provide the native backend separately.
// Values: -1 UNKNOWN; 0 FAR; 1 NEAR. Never skip original mod behavior for UNKNOWN.
public class NativeLocationBackend extends IScriptable {
  public func IsReady() -> Bool { return false; }
  public func CoordinatorState() -> Int32 { return -1; }
  public func OwnerCount(owner: Int32) -> Int32 { return 0; }
  public func OwnerAnchor(owner: Int32, index: Int32) -> Int32 { return 0; }
  public func AnchorState(anchor: Int32) -> Int32 { return -1; }
  public func Arm(anchor: Int32, armed: Bool) -> Bool { return false; }
  public func Subscribe(consumer: Int32) -> Bool { return false; }
  public func Unsubscribe(consumer: Int32) -> Void {}
  public func NeedsSnapshot(consumer: Int32) -> Bool { return true; }
  public func AckSnapshot(consumer: Int32) -> Bool { return false; }
  public func Poll(consumer: Int32) -> Int32 { return -1; }
  public func PolledOwner(consumer: Int32) -> Int32 { return 0; }
  public func PolledState(consumer: Int32) -> Int32 { return -1; }
}

// Generator-created adapters subclass this. Callbacks carry the source owner
// and zero-based site index, not an arbitrary runtime anchor ID.
public class NativeLocationListener extends IScriptable {
  public func OnGRedNativeLocation(owner: Int32, index: Int32,
                                   state: Int32) -> Void {}
}

public class NativeLocationInterest extends IScriptable {
  public let id: Int32;
  public let owner: Int32;
  public let index: Int32;
  public let listener: ref<NativeLocationListener>;
  public let active: Bool;
}

// One watch per owner+index regardless of consumer count. The engine native
// coordinator, NOT this service, determines location/position/near-far state.
public class NativeLocationWatch extends IScriptable {
  public let owner: Int32;
  public let index: Int32;
  public let expectedCount: Int32;
  public let anchor: Int32;
  public let state: Int32;
  public let known: Bool;
  public let interestCount: Int32;
  public let pendingState: Int32;
  public let armedByUs: Bool;
}

public class NativeLocationPollJob extends ScheduledJob {
  public let service: wref<NativeLocationSignals>;
  public func Execute(runtime: ref<Runtime>) -> Void {
    if IsDefined(this.service) {
      this.service.Tick();
    }
  }
}

public class NativeLocationSignals extends IScriptable {
  // CET Lua host uses consumer 1702403. REDscript uses a distinct native stream.
  private let m_consumer: Int32;
  private let m_backend: ref<NativeLocationBackend>;
  private let m_scheduler: wref<Scheduler>;
  private let m_dirty: wref<DirtyFlags>;
  private let m_interests: array<ref<NativeLocationInterest>>;
  private let m_watches: array<ref<NativeLocationWatch>>;
  private let m_nextInterest: Int32;
  private let m_activeInterests: Int32;
  private let m_job: ref<NativeLocationPollJob>;
  private let m_jobID: Int32;
  private let m_nativeSubscribed: Bool;
  private let m_snapshotRequired: Bool;
  private let m_ready: Bool;
  private let m_dispatchDepth: Int32;
  private let m_needsCompact: Bool;

  public func Initialize(scheduler: ref<Scheduler>, dirty: ref<DirtyFlags>) -> Void {
    this.m_scheduler = scheduler;
    this.m_dirty = dirty;
    this.m_nextInterest = 1;
    this.m_consumer = 1702404;
    this.m_snapshotRequired = true;
    this.m_ready = true;
  }

  // Use only through source-proven generated adapters; native backend is
  // optional and may be absent. Never load optional native methods from core.
  // Each consumer gets its own interest token; duplicate owner/index watches
  // share a native anchor and ONE polling job.
  public func SubscribeLocation(owner: Int32, index: Int32,
                                expectedCount: Int32,
                                listener: ref<NativeLocationListener>,
                                backend: ref<NativeLocationBackend>) -> Int32 {
    if !this.m_ready || !IsDefined(listener) ||
       (!IsDefined(backend) && !IsDefined(this.m_backend)) ||
       owner <= 0 || index < 0 || expectedCount <= 0 ||
       expectedCount > 100000 || index >= expectedCount {
      return 0;
    }
    // A missing/unready native owner must not create a permanent 10 Hz
    // fallback timer. The original mod polling remains authoritative.
    if !IsDefined(this.m_backend) && !backend.IsReady() {
      return 0;
    }
    // First adapter supplies the backend; subsequent mods reuse it rather
    // than creating another native stream or requiring object identity.
    if !IsDefined(this.m_backend) {
      this.m_backend = backend;
    }

    let w: Int32 = 0;
    while w < ArraySize(this.m_watches) {
      let existing = this.m_watches[w];
      if existing.owner == owner && existing.index == index {
        if existing.expectedCount != expectedCount {
          return 0;
        }
        existing.interestCount += 1;
        return this.AddInterest(owner, index, listener);
      }
      w += 1;
    }
    // Admission does not require native player availability at registration:
    // UNKNOWN retains the original author code until a valid snapshot.
    let watch = new NativeLocationWatch();
    watch.owner = owner;
    watch.index = index;
    watch.expectedCount = expectedCount;
    watch.state = -1;
    watch.known = false;
    watch.interestCount = 1;
    ArrayPush(this.m_watches, watch);
    let id = this.AddInterest(owner, index, listener);
    if !this.EnsureJob() {
      this.UnsubscribeLocation(id);
      return 0;
    }
    this.m_snapshotRequired = true;
    return id;
  }

  private func AddInterest(owner: Int32, index: Int32,
                           listener: ref<NativeLocationListener>) -> Int32 {
    let entry = new NativeLocationInterest();
    entry.id = this.m_nextInterest;
    entry.owner = owner;
    entry.index = index;
    entry.listener = listener;
    entry.active = true;
    this.m_nextInterest += 1;
    this.m_activeInterests += 1;
    ArrayPush(this.m_interests, entry);
    return entry.id;
  }

  public func UnsubscribeLocation(id: Int32) -> Bool {
    let i: Int32 = 0;
    while i < ArraySize(this.m_interests) {
      let entry = this.m_interests[i];
      if entry.id == id && entry.active {
        entry.active = false;
        entry.listener = null;
        this.m_activeInterests -= 1;
        let w: Int32 = 0;
        while w < ArraySize(this.m_watches) {
          let watch = this.m_watches[w];
          if watch.owner == entry.owner && watch.index == entry.index {
            watch.interestCount -= 1;
            if watch.interestCount == 0 {
              // Invalidate cached state; never publish FAR as a teardown.
              watch.known = false;
              watch.state = -1;
              if watch.armedByUs && IsDefined(this.m_backend) {
                this.m_backend.Arm(watch.anchor, false);
                watch.armedByUs = false;
              }
              if this.m_dispatchDepth == 0 {
                ArrayErase(this.m_watches, w);
              } else {
                this.m_needsCompact = true;
              }
              this.m_snapshotRequired = true;
            }
            break;
          }
          w += 1;
        }
        if this.m_dispatchDepth == 0 {
          this.Compact();
        } else {
          this.m_needsCompact = true;
        }
        if this.m_activeInterests == 0 {
          this.Stop();
        }
        return true;
      }
      i += 1;
    }
    return false;
  }

  public func HasSubscribers() -> Bool {
    return this.m_activeInterests > 0;
  }

  public func State(owner: Int32, index: Int32) -> Int32 {
    let i: Int32 = 0;
    while i < ArraySize(this.m_watches) {
      let watch = this.m_watches[i];
      if watch.owner == owner && watch.index == index &&
         watch.interestCount > 0 && watch.known {
        return watch.state;
      }
      i += 1;
    }
    return -1;
  }

  public func InvalidateSession() -> Void {
    this.ResetNative();
    // UNKNOWN is emitted only for previously known sites. No event is ever
    // misrepresented as FAR after teleport/load/detach/source failure.
    let i: Int32 = 0;
    let invalidated = false;
    while i < ArraySize(this.m_watches) {
      let watch = this.m_watches[i];
      if watch.interestCount > 0 && watch.known {
        watch.known = false;
        watch.state = -1;
        invalidated = true;
        this.Deliver(watch.owner, watch.index, -1);
      }
      i += 1;
    }
    if invalidated && IsDefined(this.m_dirty) {
      this.m_dirty.Mark(n"LOCATION");
    }
    this.m_snapshotRequired = true;
  }

  private func EnsureJob() -> Bool {
    if this.m_jobID != 0 {
      return true;
    }
    if !IsDefined(this.m_scheduler) {
      return false;
    }
    this.m_job = new NativeLocationPollJob();
    this.m_job.service = this;
    this.m_job.Configure(n"G-RED-NativeLocationSignals", 0.10, true);
    this.m_jobID = this.m_scheduler.Register(this.m_job);
    return this.m_jobID != 0;
  }

  private func Stop() -> Void {
    this.ResetNative();
    if this.m_jobID != 0 && IsDefined(this.m_scheduler) {
      this.m_scheduler.Unregister(this.m_jobID);
    }
    this.m_jobID = 0;
    this.m_job = null;
    if this.m_activeInterests == 0 {
      this.m_backend = null;
    }
  }

  private func ResetNative() -> Void {
    if this.m_nativeSubscribed && IsDefined(this.m_backend) {
      this.m_backend.Unsubscribe(this.m_consumer);
    }
    this.m_nativeSubscribed = false;
    this.m_snapshotRequired = true;
  }

  private func Compact() -> Void {
    let i: Int32 = ArraySize(this.m_interests) - 1;
    while i >= 0 {
      if !this.m_interests[i].active {
        ArrayErase(this.m_interests, i);
      }
      i -= 1;
    }
    let j: Int32 = ArraySize(this.m_watches) - 1;
    while j >= 0 {
      if this.m_watches[j].interestCount <= 0 {
        ArrayErase(this.m_watches, j);
      }
      j -= 1;
    }
    this.m_needsCompact = false;
  }

  private func Deliver(owner: Int32, index: Int32, state: Int32) -> Void {
    this.m_dispatchDepth += 1;
    let i: Int32 = 0;
    let count = ArraySize(this.m_interests);
    while i < count {
      let sub = this.m_interests[i];
      if sub.active && sub.owner == owner && sub.index == index &&
         IsDefined(sub.listener) {
        sub.listener.OnGRedNativeLocation(owner, index, state);
      }
      i += 1;
    }
    this.m_dispatchDepth -= 1;
    if this.m_dispatchDepth == 0 && this.m_needsCompact {
      this.Compact();
    }
  }

  private func SetState(watch: ref<NativeLocationWatch>,
                        value: Int32) -> Void {
    if watch.interestCount <= 0 || (value != 0 && value != 1) {
      return;
    }
    if !watch.known || watch.state != value {
      watch.known = true;
      watch.state = value;
      if IsDefined(this.m_dirty) {
        this.m_dirty.Mark(n"LOCATION");
      }
      this.Deliver(watch.owner, watch.index, value);
    }
  }

  public func Tick() -> Void {
    if !this.m_ready || this.m_activeInterests <= 0 ||
       !IsDefined(this.m_backend) {
      return;
    }
    if !this.m_backend.IsReady() ||
       this.m_backend.CoordinatorState() != 2 {
      this.InvalidateSession();
      return;
    }
    if !this.m_nativeSubscribed {
      if !this.m_backend.Subscribe(this.m_consumer) {
        this.InvalidateSession();
        return;
      }
      this.m_nativeSubscribed = true;
      this.m_snapshotRequired = true;
    }
    if this.m_snapshotRequired ||
       this.m_backend.NeedsSnapshot(this.m_consumer) {
      if !this.ReadSnapshot() {
        this.InvalidateSession();
        return;
      }
    }
    let n: Int32 = 0;
    while n < 512 {
      let anchor = this.m_backend.Poll(this.m_consumer);
      if anchor == 0 {
        return;
      }
      if anchor < 0 {
        this.InvalidateSession();
        return;
      }
      let owner = this.m_backend.PolledOwner(this.m_consumer);
      let value = this.m_backend.PolledState(this.m_consumer);
      if value != 0 && value != 1 {
        this.InvalidateSession();
        return;
      }
      let i: Int32 = 0;
      while i < ArraySize(this.m_watches) {
        let watch = this.m_watches[i];
        if watch.interestCount > 0 && watch.owner == owner &&
           watch.anchor == anchor {
          this.SetState(watch, value);
        }
        if !this.m_ready || this.m_activeInterests <= 0 ||
           !this.m_nativeSubscribed || !IsDefined(this.m_backend) {
          // Last consumer may unsubscribe inside the event callback.
          return;
        }
        i += 1;
      }
      n += 1;
    }
  }

  private func ReadSnapshot() -> Bool {
    // Validate all requested sites before publishing any state. Otherwise a
    // partially mismatched source inventory could emit false FAR/NEAR.
    let i: Int32 = 0;
    while i < ArraySize(this.m_watches) {
      let watch = this.m_watches[i];
      if watch.interestCount > 0 {
        if this.m_backend.OwnerCount(watch.owner) != watch.expectedCount {
          return false;
        }
        let anchor = this.m_backend.OwnerAnchor(watch.owner, watch.index);
        if anchor <= 0 {
          return false;
        }
        watch.anchor = anchor;
        if watch.owner >= 100000000 && !watch.armedByUs {
          // Compiled sites may be dormant until armed. Arm before reading
          // their initial state, as in CET's attachCompiled() owner.
          if !this.m_backend.Arm(anchor, true) {
            return false;
          }
          watch.armedByUs = true;
        }
        let value = this.m_backend.AnchorState(anchor);
        if value != 0 && value != 1 {
          return false;
        }
        watch.pendingState = value;
      }
      i += 1;
    }
    if !this.m_backend.AckSnapshot(this.m_consumer) {
      return false;
    }
    this.m_snapshotRequired = false;
    let j: Int32 = 0;
    while j < ArraySize(this.m_watches) {
      let watch = this.m_watches[j];
      if watch.interestCount > 0 {
        this.SetState(watch, watch.pendingState);
      }
      j += 1;
    }
    return true;
  }

  public func Shutdown() -> Void {
    this.m_ready = false;
    let w: Int32 = 0;
    while w < ArraySize(this.m_watches) {
      let watch = this.m_watches[w];
      if watch.armedByUs && IsDefined(this.m_backend) {
        this.m_backend.Arm(watch.anchor, false);
        watch.armedByUs = false;
      }
      w += 1;
    }
    this.Stop();
    let i: Int32 = 0;
    while i < ArraySize(this.m_interests) {
      let entry = this.m_interests[i];
      entry.active = false;
      entry.listener = null;
      i += 1;
    }
    ArrayClear(this.m_interests);
    ArrayClear(this.m_watches);
    this.m_activeInterests = 0;
    this.m_backend = null;
    this.m_dirty = null;
    this.m_scheduler = null;
  }
}
