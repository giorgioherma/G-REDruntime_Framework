module GRedRuntime

public class InputEvent extends IScriptable {
  public let actionName: CName;
  public let actionType: gameinputActionType;
  public let consumed: Bool;
}

public class InputListener extends IScriptable {
  public func OnGRedInput(evt: ref<InputEvent>) -> Void {}
}

public class InputDeviceListener extends IScriptable {
  public func OnGRedInputDeviceChanged(lastUsedKBM: Bool) -> Void {}
}

public class InputDeviceSubscription extends IScriptable {
  public let id: Int32;
  public let listener: ref<InputDeviceListener>;
  public let active: Bool;
}

public class InputSubscription extends IScriptable {
  public let id: Int32;
  public let actionName: CName;
  public let listener: ref<InputListener>;
  public let active: Bool;
}

public class InputRoute extends IScriptable {
  public let actionName: CName;
  public let subscriptions: array<ref<InputSubscription>>;
}

public class InputBridge extends IScriptable {
  private let m_hub: wref<InputHub>;
  private let m_specific: Bool;

  public func Initialize(hub: ref<InputHub>, specific: Bool) -> Void {
    this.m_hub = hub;
    this.m_specific = specific;
  }

  protected cb func OnAction(action: ListenerAction, consumer: ListenerActionConsumer) -> Bool {
    if !IsDefined(this.m_hub) {
      return false;
    }

    if this.m_specific {
      return this.m_hub.PublishSpecific(action);
    }
    return this.m_hub.PublishWildcard(action);
  }
}

public class InputDevicePollJob extends ScheduledJob {
  public let hub: wref<InputHub>;

  public func Execute(runtime: ref<Runtime>) -> Void {
    if IsDefined(this.hub) {
      this.hub.PublishDeviceState();
    }
  }
}

public class InputHub extends IScriptable {
  // Master list is lifecycle-only. Hot dispatch does not walk it.
  private let m_subscriptions: array<ref<InputSubscription>>;
  private let m_wildcardSubscriptions: array<ref<InputSubscription>>;
  private let m_routes: array<ref<InputRoute>>;
  private let m_deviceSubscriptions: array<ref<InputDeviceSubscription>>;

  private let m_nextID: Int32;
  private let m_activeCount: Int32;
  private let m_wildcardCount: Int32;
  private let m_specificCount: Int32;
  private let m_deviceCount: Int32;

  private let m_diagnostics: wref<Diagnostics>;
  private let m_state: wref<StateCache>;

  // Wildcard traffic and action-specific traffic use separate engine bridges.
  // A wildcard consumer therefore no longer forces every input event through
  // the specific-route dispatcher.
  private let m_wildcardBridge: ref<InputBridge>;
  private let m_specificBridge: ref<InputBridge>;
  private let m_event: ref<InputEvent>;
  private let m_scheduler: wref<Scheduler>;
  private let m_devicePollJob: ref<InputDevicePollJob>;
  private let m_devicePollJobID: Int32;

  private let m_registeredPlayer: wref<PlayerPuppet>;
  private let m_wildcardRegistered: Bool;
  private let m_deviceKnown: Bool;
  private let m_lastUsedKBM: Bool;
  private let m_registeredActions: array<CName>;

  public func Initialize(state: ref<StateCache>, diagnostics: ref<Diagnostics>, scheduler: ref<Scheduler>) -> Void {
    this.m_state = state;
    this.m_diagnostics = diagnostics;
    this.m_scheduler = scheduler;
    this.m_nextID = 1;

    this.m_wildcardBridge = new InputBridge();
    this.m_wildcardBridge.Initialize(this, false);

    this.m_specificBridge = new InputBridge();
    this.m_specificBridge.Initialize(this, true);


    // Dispatch is synchronous. InputEvent is callback-scoped and reused to
    // avoid allocating an IScriptable object for every engine input callback.
    this.m_event = new InputEvent();
  }

  public func Shutdown() -> Void {
    this.UnregisterAllBridges();
    this.StopDevicePolling();

    let i: Int32 = 0;
    let count = ArraySize(this.m_subscriptions);
    while i < count {
      this.m_subscriptions[i].active = false;
      this.m_subscriptions[i].listener = null;
      i += 1;
    }

    let deviceIndex: Int32 = 0;
    let deviceCount = ArraySize(this.m_deviceSubscriptions);
    while deviceIndex < deviceCount {
      this.m_deviceSubscriptions[deviceIndex].active = false;
      this.m_deviceSubscriptions[deviceIndex].listener = null;
      deviceIndex += 1;
    }

    ArrayClear(this.m_wildcardSubscriptions);
    ArrayClear(this.m_routes);
    ArrayClear(this.m_deviceSubscriptions);
    this.m_activeCount = 0;
    this.m_wildcardCount = 0;
    this.m_specificCount = 0;
    this.m_deviceCount = 0;
    this.m_deviceKnown = false;
    this.m_event = null;
    this.m_scheduler = null;
  }

  public func OnPlayerAvailable(player: wref<PlayerPuppet>) -> Void {
    if IsDefined(this.m_registeredPlayer) && NotEquals(this.m_registeredPlayer, player) {
      this.UnregisterAllBridges();
    }
    this.m_registeredPlayer = player;
    this.RefreshRegistration();
  }

  public func Subscribe(actionName: CName, listener: ref<InputListener>) -> Int32 {
    if !IsDefined(listener) {
      return 0;
    }

    let sub = new InputSubscription();
    sub.id = this.m_nextID;
    sub.actionName = actionName;
    sub.listener = listener;
    sub.active = true;

    this.m_nextID += 1;
    this.m_activeCount += 1;
    ArrayPush(this.m_subscriptions, sub);

    if this.IsWildcard(actionName) {
      ArrayPush(this.m_wildcardSubscriptions, sub);
      this.m_wildcardCount += 1;
    } else {
      let route = this.GetOrCreateRoute(actionName);
      ArrayPush(route.subscriptions, sub);
      this.m_specificCount += 1;
    }

    this.RefreshRegistration();
    return sub.id;
  }

  public func SubscribeAll(listener: ref<InputListener>) -> Int32 {
    return this.Subscribe(n"*", listener);
  }

  public func SubscribeDevice(listener: ref<InputDeviceListener>) -> Int32 {
    if !IsDefined(listener) {
      return 0;
    }

    let sub = new InputDeviceSubscription();
    sub.id = this.m_nextID;
    sub.listener = listener;
    sub.active = true;

    this.m_nextID += 1;
    this.m_deviceCount += 1;
    ArrayPush(this.m_deviceSubscriptions, sub);
    this.RefreshRegistration();
    return sub.id;
  }

  public func UnsubscribeDevice(id: Int32) -> Bool {
    let i: Int32 = 0;
    let count = ArraySize(this.m_deviceSubscriptions);
    while i < count {
      let sub = this.m_deviceSubscriptions[i];
      if sub.id == id && sub.active {
        sub.active = false;
        sub.listener = null;
        this.m_deviceCount -= 1;
        ArrayErase(this.m_deviceSubscriptions, i);
        this.RefreshRegistration();
        return true;
      }
      i += 1;
    }
    return false;
  }

  public func Unsubscribe(id: Int32) -> Bool {
    let i: Int32 = 0;
    let count = ArraySize(this.m_subscriptions);
    while i < count {
      let sub = this.m_subscriptions[i];
      if sub.id == id && sub.active {
        if this.IsWildcard(sub.actionName) {
          this.RemoveSubscription(this.m_wildcardSubscriptions, sub);
          this.m_wildcardCount -= 1;
        } else {
          let route = this.FindRoute(sub.actionName);
          if IsDefined(route) {
            this.RemoveSubscription(route.subscriptions, sub);
          }
          this.m_specificCount -= 1;
        }

        sub.active = false;
        sub.listener = null;
        this.m_activeCount -= 1;
        this.RefreshRegistration();
        return true;
      }
      i += 1;
    }
    return false;
  }

  public func HasSubscribers() -> Bool {
    return this.m_activeCount > 0;
  }

  public func HasSubscribersFor(actionName: CName) -> Bool {
    if this.m_activeCount <= 0 {
      return false;
    }
    if this.m_wildcardCount > 0 {
      return true;
    }

    let route = this.FindRoute(actionName);
    return IsDefined(route) && ArraySize(route.subscriptions) > 0;
  }

  public func HasDeviceSubscribers() -> Bool {
    return this.m_deviceCount > 0;
  }

  public func PublishDeviceState() -> Void {
    if this.m_deviceCount <= 0 {
      return;
    }

    let player = this.m_registeredPlayer;
    if !IsDefined(player) && IsDefined(this.m_state) {
      player = this.m_state.GetPlayer();
    }
    if !IsDefined(player) {
      return;
    }

    let currentLastUsedKBM = player.PlayerLastUsedKBM();
    if !this.m_deviceKnown {
      this.m_lastUsedKBM = currentLastUsedKBM;
      this.m_deviceKnown = true;
      return;
    }

    if Equals(currentLastUsedKBM, this.m_lastUsedKBM) {
      return;
    }

    this.m_lastUsedKBM = currentLastUsedKBM;

    let i: Int32 = 0;
    let count = ArraySize(this.m_deviceSubscriptions);
    while i < count {
      let sub = this.m_deviceSubscriptions[i];
      if IsDefined(sub) && sub.active && IsDefined(sub.listener) {
        sub.listener.OnGRedInputDeviceChanged(currentLastUsedKBM);
      }
      i += 1;
    }
  }

  // Compatibility path for callers that explicitly route one ListenerAction
  // through the hub. Engine bridges use the split hot paths below.
  public func Publish(action: ListenerAction) -> Bool {
    if this.m_activeCount <= 0 || !IsDefined(this.m_event) {
      return false;
    }

    if IsDefined(this.m_diagnostics) {
      this.m_diagnostics.InputSeen();
    }

    let evt = this.PrepareEvent(action);
    this.DispatchWildcards(evt);
    this.DispatchSpecific(evt);
    return evt.consumed;
  }

  public func PublishWildcard(action: ListenerAction) -> Bool {
    if this.m_wildcardCount <= 0 || !IsDefined(this.m_event) {
      return false;
    }

    if IsDefined(this.m_diagnostics) {
      this.m_diagnostics.InputSeen();
    }

    let evt = this.PrepareEvent(action);
    this.DispatchWildcards(evt);
    return evt.consumed;
  }

  public func PublishSpecific(action: ListenerAction) -> Bool {
    if this.m_specificCount <= 0 || !IsDefined(this.m_event) {
      return false;
    }

    // When a wildcard bridge exists it already counted this engine input.
    if this.m_wildcardCount <= 0 && IsDefined(this.m_diagnostics) {
      this.m_diagnostics.InputSeen();
    }

    let evt = this.PrepareEvent(action);
    this.DispatchSpecific(evt);
    return evt.consumed;
  }

  private func PrepareEvent(action: ListenerAction) -> ref<InputEvent> {
    this.m_event.actionName = ListenerAction.GetName(action);
    this.m_event.actionType = ListenerAction.GetType(action);
    this.m_event.consumed = false;
    return this.m_event;
  }

  private func DispatchWildcards(evt: ref<InputEvent>) -> Void {
    let i: Int32 = 0;
    let count = ArraySize(this.m_wildcardSubscriptions);
    while i < count {
      this.m_wildcardSubscriptions[i].listener.OnGRedInput(evt);
      if IsDefined(this.m_diagnostics) {
        this.m_diagnostics.InputDelivery();
      }
      i += 1;
    }
  }

  private func DispatchSpecific(evt: ref<InputEvent>) -> Void {
    let routeIndex: Int32 = 0;
    let routeCount = ArraySize(this.m_routes);
    while routeIndex < routeCount {
      let route = this.m_routes[routeIndex];
      if Equals(route.actionName, evt.actionName) {
        let subIndex: Int32 = 0;
        let subCount = ArraySize(route.subscriptions);
        while subIndex < subCount {
          route.subscriptions[subIndex].listener.OnGRedInput(evt);
          if IsDefined(this.m_diagnostics) {
            this.m_diagnostics.InputDelivery();
          }
          subIndex += 1;
        }
        return;
      }
      routeIndex += 1;
    }
  }

  private func GetOrCreateRoute(actionName: CName) -> ref<InputRoute> {
    let route = this.FindRoute(actionName);
    if IsDefined(route) {
      return route;
    }

    let newRoute = new InputRoute();
    newRoute.actionName = actionName;
    ArrayPush(this.m_routes, newRoute);
    return newRoute;
  }

  private func FindRoute(actionName: CName) -> ref<InputRoute> {
    let i: Int32 = 0;
    let count = ArraySize(this.m_routes);
    while i < count {
      if Equals(this.m_routes[i].actionName, actionName) {
        return this.m_routes[i];
      }
      i += 1;
    }
    return null;
  }

  private func RemoveSubscription(list: script_ref<array<ref<InputSubscription>>>, sub: ref<InputSubscription>) -> Void {
    let i: Int32 = 0;
    let count = ArraySize(Deref(list));
    while i < count {
      if Equals(Deref(list)[i], sub) {
        ArrayErase(Deref(list), i);
        return;
      }
      i += 1;
    }
  }

  private func RefreshRegistration() -> Void {
    let player = this.m_registeredPlayer;
    if !IsDefined(player) && IsDefined(this.m_state) {
      player = this.m_state.GetPlayer();
    }

    if !IsDefined(player) {
      this.UnregisterAllBridges();
      this.StopDevicePolling();
      return;
    }

    if IsDefined(this.m_registeredPlayer) && NotEquals(this.m_registeredPlayer, player) {
      this.UnregisterAllBridges();
    }
    this.m_registeredPlayer = player;

    if this.m_wildcardCount > 0 {
      if !this.m_wildcardRegistered {
        player.RegisterInputListener(this.m_wildcardBridge);
        this.m_wildcardRegistered = true;
      }
    } else {
      this.UnregisterWildcardBridge();
    }

    if this.m_deviceCount > 0 {
      this.StartDevicePolling();
    } else {
      this.StopDevicePolling();
    }

    this.RefreshSpecificRegistration();
  }

  private func RefreshSpecificRegistration() -> Void {
    if !IsDefined(this.m_registeredPlayer) || !IsDefined(this.m_specificBridge) {
      return;
    }

    // Remove engine registrations whose route no longer has subscribers.
    let registeredIndex: Int32 = ArraySize(this.m_registeredActions) - 1;
    while registeredIndex >= 0 {
      let actionName = this.m_registeredActions[registeredIndex];
      let route = this.FindRoute(actionName);
      if !IsDefined(route) || ArraySize(route.subscriptions) <= 0 {
        this.m_registeredPlayer.UnregisterInputListener(this.m_specificBridge, actionName);
        ArrayErase(this.m_registeredActions, registeredIndex);
      }
      registeredIndex -= 1;
    }

    // Register newly active routes. Existing routes stay registered.
    let routeIndex: Int32 = 0;
    let routeCount = ArraySize(this.m_routes);
    while routeIndex < routeCount {
      let route = this.m_routes[routeIndex];
      if ArraySize(route.subscriptions) > 0 && !this.IsRegisteredAction(route.actionName) {
        this.m_registeredPlayer.RegisterInputListener(this.m_specificBridge, route.actionName);
        ArrayPush(this.m_registeredActions, route.actionName);
      }
      routeIndex += 1;
    }
  }

  private func IsRegisteredAction(actionName: CName) -> Bool {
    let i: Int32 = 0;
    let count = ArraySize(this.m_registeredActions);
    while i < count {
      if Equals(this.m_registeredActions[i], actionName) {
        return true;
      }
      i += 1;
    }
    return false;
  }

  private func IsWildcard(actionName: CName) -> Bool {
    return Equals(actionName, n"") || Equals(actionName, n"*");
  }

  private func UnregisterWildcardBridge() -> Void {
    if this.m_wildcardRegistered && IsDefined(this.m_registeredPlayer) && IsDefined(this.m_wildcardBridge) {
      this.m_registeredPlayer.UnregisterInputListener(this.m_wildcardBridge);
    }
    this.m_wildcardRegistered = false;
  }

  private func UnregisterSpecificBridge() -> Void {
    if IsDefined(this.m_registeredPlayer) && IsDefined(this.m_specificBridge) {
      let i: Int32 = 0;
      let count = ArraySize(this.m_registeredActions);
      while i < count {
        this.m_registeredPlayer.UnregisterInputListener(this.m_specificBridge, this.m_registeredActions[i]);
        i += 1;
      }
    }
    ArrayClear(this.m_registeredActions);
  }

  private func StartDevicePolling() -> Void {
    if this.m_deviceCount <= 0 || this.m_devicePollJobID > 0 || !IsDefined(this.m_scheduler) {
      return;
    }

    this.m_deviceKnown = false;
    this.m_devicePollJob = new InputDevicePollJob();
    this.m_devicePollJob.hub = this;
    this.m_devicePollJob.Configure(n"INPUT_DEVICE_STATE", 0.10, true);
    this.m_devicePollJobID = this.m_scheduler.Register(this.m_devicePollJob);
  }

  private func StopDevicePolling() -> Void {
    if IsDefined(this.m_scheduler) && this.m_devicePollJobID > 0 {
      this.m_scheduler.Unregister(this.m_devicePollJobID);
    }
    this.m_devicePollJobID = 0;
    this.m_devicePollJob = null;
    this.m_deviceKnown = false;
  }

  private func UnregisterAllBridges() -> Void {
    this.UnregisterWildcardBridge();
    this.UnregisterSpecificBridge();
    this.m_registeredPlayer = null;
    this.m_deviceKnown = false;
  }
}
