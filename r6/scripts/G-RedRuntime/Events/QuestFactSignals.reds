module GRedRuntime

// Opt-in change observation for exact quest fact names. Each active CName has
// ONE additional engine listener regardless of the number of participating
// consumers. The core stays dormant when there are no AcquireFact callers.
// This does not replace other mods' existing quest callbacks.
public class QuestFactWatch extends IScriptable {
  public let fact: CName;
  public let bridge: ref<QuestFactBridge>;
  public let engineListenerID: Uint32;
  public let interestCount: Int32;
  public let version: Uint32;
  public let hasObservedValue: Bool;
  public let lastObservedValue: Int32;
}

// Each consumer receives a unique interest token; one consumer cannot
// accidentally unregister another consumer's engine subscription.
public class QuestFactInterest extends IScriptable {
  public let id: Int32;
  public let fact: CName;
  public let active: Bool;
}

public class QuestFactBridge extends IScriptable {
  private let m_owner: wref<QuestFactSignals>;
  private let m_fact: CName;

  public func Initialize(owner: ref<QuestFactSignals>, fact: CName) -> Void {
    this.m_owner = owner;
    this.m_fact = fact;
  }

  // Real QuestsSystem callback signature verified in the live REDscript
  // sources. We are an additional observation-only listener; original
  // per-mod callbacks and their return/ordering semantics are unchanged.
  protected cb func OnFactChanged(value: Int32) -> Bool {
    if IsDefined(this.m_owner) {
      this.m_owner.OnFactChanged(this.m_fact, value);
    }
    return false;
  }
}

public class QuestFactSignals extends IScriptable {
  private let m_game: GameInstance;
  private let m_dirty: wref<DirtyFlags>;
  private let m_events: wref<EventBus>;
  private let m_watches: array<ref<QuestFactWatch>>;
  private let m_interests: array<ref<QuestFactInterest>>;
  private let m_nextInterestID: Int32;
  private let m_ready: Bool;

  public func Initialize(game: GameInstance, dirty: ref<DirtyFlags>,
                         events: ref<EventBus>) -> Void {
    this.m_game = game;
    this.m_nextInterestID = 1;
    this.m_dirty = dirty;
    this.m_events = events;
    this.m_ready = true;
  }

  public func Shutdown() -> Void {
    this.m_ready = false;
    let qs = GameInstance.GetQuestsSystem(this.m_game);
    let i: Int32 = 0;
    while i < ArraySize(this.m_watches) {
      let watch = this.m_watches[i];
      if watch.engineListenerID != 0u && IsDefined(qs) {
        qs.UnregisterListener(watch.fact, watch.engineListenerID);
      }
      watch.engineListenerID = 0u;
      watch.interestCount = 0;
      watch.hasObservedValue = false;
      watch.bridge = null;
      i += 1;
    }
    let j: Int32 = 0;
    while j < ArraySize(this.m_interests) {
      this.m_interests[j].active = false;
      j += 1;
    }
    this.m_dirty = null;
    this.m_events = null;
  }

  public func AcquireFact(fact: CName) -> Int32 {
    if !this.m_ready {
      return 0;
    }
    let qs = GameInstance.GetQuestsSystem(this.m_game);
    if !IsDefined(qs) {
      return 0;
    }

    let i: Int32 = 0;
    while i < ArraySize(this.m_watches) {
      let watch = this.m_watches[i];
      if Equals(watch.fact, fact) {
        if watch.interestCount > 0 && watch.engineListenerID != 0u {
          watch.interestCount += 1;
          return this.AddInterest(fact);
        }
        let bridge = new QuestFactBridge();
        bridge.Initialize(this, fact);
        let registration = qs.RegisterListener(fact, bridge, n"OnFactChanged");
        if registration == 0u {
          return 0;
        }
        watch.bridge = bridge;
        watch.engineListenerID = registration;
        watch.interestCount = 1;
        watch.hasObservedValue = false;
        watch.version += 1u;
        return this.AddInterest(fact);
      }
      i += 1;
    }

    let bridge = new QuestFactBridge();
    bridge.Initialize(this, fact);
    let registration = qs.RegisterListener(fact, bridge, n"OnFactChanged");
    if registration == 0u {
      return 0;
    }
    let watch = new QuestFactWatch();
    watch.fact = fact;
    watch.bridge = bridge;
    watch.engineListenerID = registration;
    watch.interestCount = 1;
    watch.version = 1u;
    watch.hasObservedValue = false;
    ArrayPush(this.m_watches, watch);
    return this.AddInterest(fact);
  }

  private func AddInterest(fact: CName) -> Int32 {
    let entry = new QuestFactInterest();
    entry.id = this.m_nextInterestID;
    entry.fact = fact;
    entry.active = true;
    this.m_nextInterestID += 1;
    ArrayPush(this.m_interests, entry);
    return entry.id;
  }

  public func ReleaseFact(interestID: Int32) -> Bool {
    if interestID <= 0 {
      return false;
    }
    let k: Int32 = 0;
    while k < ArraySize(this.m_interests) {
      let entry = this.m_interests[k];
      if entry.id == interestID && entry.active {
        entry.active = false;
        let i: Int32 = 0;
        while i < ArraySize(this.m_watches) {
          let watch = this.m_watches[i];
          if Equals(watch.fact, entry.fact) && watch.interestCount > 0 {
            watch.interestCount -= 1;
            if watch.interestCount == 0 {
              let qs = GameInstance.GetQuestsSystem(this.m_game);
              if IsDefined(qs) && watch.engineListenerID != 0u {
                qs.UnregisterListener(watch.fact, watch.engineListenerID);
              }
              watch.engineListenerID = 0u;
              watch.bridge = null;
              watch.hasObservedValue = false;
              watch.version += 1u;
            }
            return true;
          }
          i += 1;
        }
        return false;
      }
      k += 1;
    }
    return false;
  }

  // Each engine callback advances the version, including repeated values.
  // Repeated event delivery can be semantically meaningful to consumers.
  public func OnFactChanged(fact: CName, value: Int32) -> Void {
    if !this.m_ready {
      return;
    }
    let i: Int32 = 0;
    while i < ArraySize(this.m_watches) {
      let watch = this.m_watches[i];
      if Equals(watch.fact, fact) && watch.interestCount > 0 &&
         watch.engineListenerID != 0u {
        watch.version += 1u;
        watch.lastObservedValue = value;
        watch.hasObservedValue = true;
        if IsDefined(this.m_dirty) {
          this.m_dirty.Mark(n"QUEST_FACT");
        }
        if IsDefined(this.m_events) &&
           this.m_events.HasSubscribersFor(n"QUEST_FACT") {
          let evt = RuntimeEvent.Create(n"QUEST_FACT", n"CHANGED");
          evt.nameValue = fact;
          evt.intValue = value;
          this.m_events.Publish(evt);
        }
        return;
      }
      i += 1;
    }
  }

  public func Version(fact: CName) -> Uint32 {
    let i: Int32 = 0;
    while i < ArraySize(this.m_watches) {
      let watch = this.m_watches[i];
      if Equals(watch.fact, fact) && watch.interestCount > 0 {
        return watch.version;
      }
      i += 1;
    }
    return 0u;
  }

  public func HasObservedValue(fact: CName) -> Bool {
    let i: Int32 = 0;
    while i < ArraySize(this.m_watches) {
      let watch = this.m_watches[i];
      if Equals(watch.fact, fact) && watch.interestCount > 0 {
        return watch.hasObservedValue;
      }
      i += 1;
    }
    return false;
  }

  // Read only if HasObservedValue is true; the framework makes NO initial
  // fact-value claim, and source consumers use the original GetFact fallback.
  public func LastObservedValue(fact: CName) -> Int32 {
    let i: Int32 = 0;
    while i < ArraySize(this.m_watches) {
      let watch = this.m_watches[i];
      if Equals(watch.fact, fact) && watch.interestCount > 0 &&
         watch.hasObservedValue {
        return watch.lastObservedValue;
      }
      i += 1;
    }
    return 0;
  }

  // Called only for authoritative player session attach/detach. An unknown
  // version forces all consumers to re-read their original source getter.
  // Listeners are not silently removed; only ReleaseFact owns cleanup.
  public func InvalidateSession() -> Void {
    let i: Int32 = 0;
    while i < ArraySize(this.m_watches) {
      let watch = this.m_watches[i];
      if watch.interestCount > 0 {
        watch.hasObservedValue = false;
        watch.version += 1u;
      }
      i += 1;
    }
  }
}
