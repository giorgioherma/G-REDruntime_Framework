module GRedRuntime

public class Runtime extends ScriptableSystem {
  private let m_state: ref<StateCache>;
  private let m_dirty: ref<DirtyFlags>;
  private let m_events: ref<EventBus>;
  private let m_input: ref<InputHub>;
  private let m_scheduler: ref<Scheduler>;
  private let m_context: ref<ContextService>;
  private let m_hooks: ref<HookBus>;
  private let m_diagnostics: ref<Diagnostics>;
  private let m_ready: Bool;

  private func OnAttach() -> Void {
    this.m_diagnostics = new Diagnostics();
    this.m_diagnostics.Reset();

    this.m_state = new StateCache();
    this.m_state.Initialize(this.GetGameInstance(), this.m_diagnostics);

    this.m_dirty = new DirtyFlags();

    this.m_context = new ContextService();
    this.m_context.Initialize(this.m_state, this.m_dirty);

    this.m_events = new EventBus();
    this.m_events.Initialize(this.m_diagnostics);

    // Scheduler is initialized before InputHub so low-frequency input-device
    // observation can use the shared deadline scheduler instead of a global
    // engine input callback.
    this.m_scheduler = new Scheduler();
    this.m_scheduler.Initialize(this, this.m_state, this.m_diagnostics);

    this.m_input = new InputHub();
    this.m_input.Initialize(this.m_state, this.m_diagnostics, this.m_scheduler);

    this.m_hooks = new HookBus();
    this.m_hooks.Initialize(this.m_diagnostics);

    this.m_ready = true;
  }

  private func OnDetach() -> Void {
    this.m_ready = false;

    // InputHub owns a scheduler-backed device observer in Pass 6; release it
    // before shutting the scheduler down.
    if IsDefined(this.m_input) {
      this.m_input.Shutdown();
    }
    if IsDefined(this.m_scheduler) {
      this.m_scheduler.Shutdown();
    }
    if IsDefined(this.m_context) {
      this.m_context.Shutdown();
    }
    if IsDefined(this.m_events) {
      this.m_events.Shutdown();
    }
    if IsDefined(this.m_hooks) {
      this.m_hooks.Shutdown();
    }
    if IsDefined(this.m_state) {
      this.m_state.Shutdown();
    }
  }

  private final func OnPlayerAttach(request: ref<PlayerAttachRequest>) -> Void {
    if !this.m_ready || !IsDefined(this.m_state) {
      return;
    }

    let playerSystem = this.m_state.GetPlayerSystem();
    if !IsDefined(playerSystem) {
      return;
    }

    let player = playerSystem.GetLocalPlayerMainGameObject() as PlayerPuppet;
    this.m_state.SetPlayer(player);
    if IsDefined(this.m_context) {
      this.m_context.Invalidate();
    }
    this.m_input.OnPlayerAvailable(player);
    this.m_dirty.Mark(n"PLAYER");

    if this.m_events.HasSubscribersFor(n"PLAYER") {
      let evt = RuntimeEvent.Create(n"PLAYER", n"ATTACHED");
      if IsDefined(player) {
        evt.entityID = player.GetEntityID();
      }
      this.m_events.Publish(evt);
    }
  }

  // PlayerAttachRequest/PlayerDetachRequest are native ScriptableSystem
  // lifecycle notifications. Only this producer changes shared player state.
  // Never poll the engine to infer a transition or cache changing combat/
  // vehicle/UI values from the player handle.
  private func OnPlayerDetach(request: ref<PlayerDetachRequest>) -> Void {
    if !this.m_ready || !IsDefined(this.m_state) {
      return;
    }

    let leaving = request.owner as PlayerPuppet;
    let attached = this.m_state.GetAttachedPlayer();
    if IsDefined(leaving) && IsDefined(attached) &&
       NotEquals(leaving.GetEntityID(), attached.GetEntityID()) {
      // A delayed detach from a replaced player must not invalidate the
      // newly attached player's epoch or listeners.
      return;
    }

    this.m_state.InvalidatePlayer();
    if IsDefined(this.m_context) {
      this.m_context.Invalidate();
    }
    if IsDefined(this.m_input) {
      // Preserve registered subscribers, but remove their engine listeners
      // from the departing player and stop device polling until next attach.
      this.m_input.OnPlayerAvailable(null);
    }
    if IsDefined(this.m_dirty) {
      this.m_dirty.Mark(n"PLAYER");
    }

    if IsDefined(this.m_events) && this.m_events.HasSubscribersFor(n"PLAYER") {
      this.m_events.Publish(RuntimeEvent.Create(n"PLAYER", n"DETACHED"));
    }
  }

  public static func Get(game: GameInstance) -> ref<Runtime> {
    return GameInstance.GetScriptableSystemsContainer(game).Get(n"GRedRuntime.Runtime") as Runtime;
  }

  public func IsReady() -> Bool {
    return this.m_ready;
  }

  public func GetVersion() -> String {
    return "0.6.0-pass6";
  }

  public func GetStateCache() -> ref<StateCache> { return this.m_state; }
  public func GetDirtyFlags() -> ref<DirtyFlags> { return this.m_dirty; }
  public func GetEventBus() -> ref<EventBus> { return this.m_events; }
  public func GetInputHub() -> ref<InputHub> { return this.m_input; }
  public func GetScheduler() -> ref<Scheduler> { return this.m_scheduler; }
  public func GetContextService() -> ref<ContextService> { return this.m_context; }
  public func GetHookBus() -> ref<HookBus> { return this.m_hooks; }
  public func GetDiagnostics() -> ref<Diagnostics> { return this.m_diagnostics; }

  public func RouteInput(action: ListenerAction) -> Void {
    if !this.m_ready || !IsDefined(this.m_input) || !this.m_input.HasSubscribers() {
      return;
    }
    this.m_input.Publish(action);
  }

  public func DumpDiagnostics() -> Void {
    let snap = this.m_diagnostics.Snapshot();
    LogChannel(n"G-RedRuntime", s"G-RedRuntime \(this.GetVersion()) ready=\(this.m_ready)");
    LogChannel(n"G-RedRuntime", s"scheduler wakeups=\(snap.schedulerWakeups) jobRuns=\(snap.schedulerJobRuns) activeJobs=\(this.m_scheduler.GetActiveJobCount())");
    LogChannel(n"G-RedRuntime", s"events publishes=\(snap.eventPublishes) deliveries=\(snap.eventDeliveries)");
    LogChannel(n"G-RedRuntime", s"input seen=\(snap.inputEventsSeen) deliveries=\(snap.inputDeliveries)");
    LogChannel(n"G-RedRuntime", s"hooks dispatches=\(snap.hookDispatches) deliveries=\(snap.hookDeliveries)");
    LogChannel(n"G-RedRuntime", s"state cache hits=\(snap.stateCacheHits) misses=\(snap.stateCacheMisses)");
  }
}
