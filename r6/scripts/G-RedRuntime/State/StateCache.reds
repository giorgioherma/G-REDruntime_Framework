module GRedRuntime

public class StateCache extends IScriptable {
  private let m_game: GameInstance;
  private let m_player: wref<PlayerPuppet>;
  // Event-backed player lifetime: only OnPlayerAttach authorizes this handle
  // across callbacks. An explicit detach blocks re-adoption into the
  // shared cache; a live uncached original getter remains available.
  // The generation changes at every lifecycle boundary.
  private let m_playerSignalKnown: Bool;
  private let m_playerDiscoveryBlocked: Bool;
  private let m_playerSignalGeneration: Uint32;
  private let m_playerSystem: wref<PlayerSystem>;
  private let m_questsSystem: wref<QuestsSystem>;
  private let m_statsSystem: wref<StatsSystem>;
  private let m_delaySystem: wref<DelaySystem>;
  private let m_transactionSystem: wref<TransactionSystem>;
  private let m_blackboardSystem: wref<BlackboardSystem>;
  private let m_scriptableSystems: wref<ScriptableSystemsContainer>;
  private let m_timeSystem: wref<TimeSystem>;
  private let m_uiSystem: wref<UISystem>;
  private let m_statPoolsSystem: wref<StatPoolsSystem>;
  private let m_targetingSystem: wref<TargetingSystem>;
  private let m_marketSystem: wref<MarketSystem>;
  private let m_systemRequestsHandler: wref<inkISystemRequestsHandler>;
  private let m_preventionSystem: wref<PreventionSystem>;
  private let m_diagnostics: wref<Diagnostics>;

  public func Initialize(game: GameInstance, diagnostics: ref<Diagnostics>) -> Void {
    this.m_game = game;
    this.m_diagnostics = diagnostics;
    this.m_playerSignalKnown = false;
    this.m_playerDiscoveryBlocked = false;
    this.m_playerSignalGeneration = 0u;
  }

  public func Shutdown() -> Void {
    this.m_playerSignalGeneration += 1u;
    this.m_playerSignalKnown = false;
    this.m_playerDiscoveryBlocked = true;
    this.m_player = null;
    this.m_playerSystem = null;
    this.m_questsSystem = null;
    this.m_statsSystem = null;
    this.m_delaySystem = null;
    this.m_transactionSystem = null;
    this.m_blackboardSystem = null;
    this.m_scriptableSystems = null;
    this.m_timeSystem = null;
    this.m_uiSystem = null;
    this.m_statPoolsSystem = null;
    this.m_targetingSystem = null;
    this.m_marketSystem = null;
    this.m_systemRequestsHandler = null;
    this.m_preventionSystem = null;
  }

  public func GetGame() -> GameInstance {
    return this.m_game;
  }

  public func SetPlayer(player: wref<PlayerPuppet>) -> Void {
    this.m_player = player;
    this.m_playerSignalKnown = IsDefined(player);
    this.m_playerDiscoveryBlocked = false;
    this.m_playerSignalGeneration += 1u;
  }

  // Called only by authoritative lifecycle producer Runtime.OnPlayerDetach.
  // Unknown means consumers must use their own original live getter.
  public func InvalidatePlayer() -> Void {
    this.m_player = null;
    this.m_playerSignalKnown = false;
    this.m_playerDiscoveryBlocked = true;
    this.m_playerSignalGeneration += 1u;
  }

  public func HasAuthoritativePlayer() -> Bool {
    return this.m_playerSignalKnown && IsDefined(this.m_player);
  }

  public func GetPlayerSignalGeneration() -> Uint32 {
    return this.m_playerSignalGeneration;
  }

  // Unlike GetPlayer(), this never queries PlayerSystem. It is only suitable
  // for lifecycle identity checks and source-proven shared-state consumers.
  public func GetAttachedPlayer() -> wref<PlayerPuppet> {
    if this.HasAuthoritativePlayer() {
      return this.m_player;
    }
    return null;
  }

  public func GetPlayer() -> wref<PlayerPuppet> {
    // A detached/expired player can never be re-adopted into the SHARED
    // cached signal before the next authoritative attach. Preserve the
    // original live getter as an uncached fallback for existing callers.
    if this.m_playerDiscoveryBlocked ||
       (this.m_playerSignalKnown && !IsDefined(this.m_player)) {
      this.CacheMiss();
      let originalPlayerSystem = this.GetPlayerSystem();
      if IsDefined(originalPlayerSystem) {
        return originalPlayerSystem.GetLocalPlayerMainGameObject() as PlayerPuppet;
      }
      return null;
    }
    if IsDefined(this.m_player) {
      this.CacheHit();
      return this.m_player;
    }

    // Preserve the existing pre-first-attach fallback. This does NOT
    // establish a known event-backed signal; callers requiring source proof
    // must consult HasAuthoritativePlayer() separately.
    this.CacheMiss();
    let playerSystem = this.GetPlayerSystem();
    if IsDefined(playerSystem) {
      this.m_player = playerSystem.GetLocalPlayerMainGameObject() as PlayerPuppet;
    }
    return this.m_player;
  }

  public func GetPlayerSystem() -> wref<PlayerSystem> {
    if IsDefined(this.m_playerSystem) {
      this.CacheHit();
      return this.m_playerSystem;
    }

    this.CacheMiss();
    this.m_playerSystem = GameInstance.GetPlayerSystem(this.m_game);
    return this.m_playerSystem;
  }

  public func GetQuestsSystem() -> wref<QuestsSystem> {
    if IsDefined(this.m_questsSystem) {
      this.CacheHit();
      return this.m_questsSystem;
    }

    this.CacheMiss();
    this.m_questsSystem = GameInstance.GetQuestsSystem(this.m_game);
    return this.m_questsSystem;
  }

  public func GetStatsSystem() -> wref<StatsSystem> {
    if IsDefined(this.m_statsSystem) {
      this.CacheHit();
      return this.m_statsSystem;
    }

    this.CacheMiss();
    this.m_statsSystem = GameInstance.GetStatsSystem(this.m_game);
    return this.m_statsSystem;
  }

  public func GetDelaySystem() -> wref<DelaySystem> {
    if IsDefined(this.m_delaySystem) {
      this.CacheHit();
      return this.m_delaySystem;
    }

    this.CacheMiss();
    this.m_delaySystem = GameInstance.GetDelaySystem(this.m_game);
    return this.m_delaySystem;
  }

  public func GetTransactionSystem() -> wref<TransactionSystem> {
    if IsDefined(this.m_transactionSystem) {
      this.CacheHit();
      return this.m_transactionSystem;
    }

    this.CacheMiss();
    this.m_transactionSystem = GameInstance.GetTransactionSystem(this.m_game);
    return this.m_transactionSystem;
  }

  public func GetBlackboardSystem() -> wref<BlackboardSystem> {
    if IsDefined(this.m_blackboardSystem) {
      this.CacheHit();
      return this.m_blackboardSystem;
    }

    this.CacheMiss();
    this.m_blackboardSystem = GameInstance.GetBlackboardSystem(this.m_game);
    return this.m_blackboardSystem;
  }

  public func GetScriptableSystemsContainer() -> wref<ScriptableSystemsContainer> {
    if IsDefined(this.m_scriptableSystems) {
      this.CacheHit();
      return this.m_scriptableSystems;
    }

    this.CacheMiss();
    this.m_scriptableSystems = GameInstance.GetScriptableSystemsContainer(this.m_game);
    return this.m_scriptableSystems;
  }

  public func GetTimeSystem() -> wref<TimeSystem> {
    if IsDefined(this.m_timeSystem) {
      this.CacheHit();
      return this.m_timeSystem;
    }

    this.CacheMiss();
    this.m_timeSystem = GameInstance.GetTimeSystem(this.m_game);
    return this.m_timeSystem;
  }

  public func GetUISystem() -> wref<UISystem> {
    if IsDefined(this.m_uiSystem) {
      this.CacheHit();
      return this.m_uiSystem;
    }

    this.CacheMiss();
    this.m_uiSystem = GameInstance.GetUISystem(this.m_game);
    return this.m_uiSystem;
  }

  public func GetStatPoolsSystem() -> wref<StatPoolsSystem> {
    if IsDefined(this.m_statPoolsSystem) {
      this.CacheHit();
      return this.m_statPoolsSystem;
    }

    this.CacheMiss();
    this.m_statPoolsSystem = GameInstance.GetStatPoolsSystem(this.m_game);
    return this.m_statPoolsSystem;
  }

  public func GetTargetingSystem() -> wref<TargetingSystem> {
    if IsDefined(this.m_targetingSystem) {
      this.CacheHit();
      return this.m_targetingSystem;
    }

    this.CacheMiss();
    this.m_targetingSystem = GameInstance.GetTargetingSystem(this.m_game);
    return this.m_targetingSystem;
  }

  public func GetMarketSystem() -> wref<MarketSystem> {
    if IsDefined(this.m_marketSystem) {
      this.CacheHit();
      return this.m_marketSystem;
    }

    this.CacheMiss();
    this.m_marketSystem = MarketSystem.GetInstance(this.m_game);
    return this.m_marketSystem;
  }

  public func GetSystemRequestsHandler() -> wref<inkISystemRequestsHandler> {
    if IsDefined(this.m_systemRequestsHandler) {
      this.CacheHit();
      return this.m_systemRequestsHandler;
    }

    this.CacheMiss();
    this.m_systemRequestsHandler = GameInstance.GetSystemRequestsHandler();
    return this.m_systemRequestsHandler;
  }

  public func GetPreventionSystem() -> wref<PreventionSystem> {
    if IsDefined(this.m_preventionSystem) {
      this.CacheHit();
      return this.m_preventionSystem;
    }

    this.CacheMiss();
    let systems = this.GetScriptableSystemsContainer();
    if IsDefined(systems) {
      this.m_preventionSystem = systems.Get(n"PreventionSystem") as PreventionSystem;
    }
    return this.m_preventionSystem;
  }

  private func CacheHit() -> Void {
    if IsDefined(this.m_diagnostics) {
      this.m_diagnostics.StateCacheHit();
    }
  }

  private func CacheMiss() -> Void {
    if IsDefined(this.m_diagnostics) {
      this.m_diagnostics.StateCacheMiss();
    }
  }
}
