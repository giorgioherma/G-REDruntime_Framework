module GRedRuntime

public class ScheduledJob extends IScriptable {
  private let m_id: Int32;
  private let m_name: CName;
  private let m_interval: Float;
  private let m_repeat: Bool;
  private let m_enabled: Bool;
  private let m_nextDue: Float;

  public func Configure(name: CName, interval: Float, repeat: Bool) -> ref<ScheduledJob> {
    this.m_name = name;
    this.m_interval = interval;
    if this.m_interval < 0.05 {
      this.m_interval = 0.05;
    }
    this.m_repeat = repeat;
    this.m_enabled = true;
    this.m_nextDue = 0.00;
    return this;
  }

  public func Execute(runtime: ref<Runtime>) -> Void {}

  public func GetID() -> Int32 { return this.m_id; }
  public func GetName() -> CName { return this.m_name; }
  public func GetInterval() -> Float { return this.m_interval; }

  public func SetInterval(interval: Float) -> Void {
    this.m_interval = interval;
    if this.m_interval < 0.05 {
      this.m_interval = 0.05;
    }
  }
  public func GetNextDue() -> Float { return this.m_nextDue; }
  public func IsEnabled() -> Bool { return this.m_enabled; }
  public func IsRepeating() -> Bool { return this.m_repeat; }

  public func Disable() -> Void {
    this.m_enabled = false;
  }

  public func Enable() -> Void {
    this.m_enabled = true;
  }

  public func ResetTimer() -> Void {
    this.m_nextDue = 0.00;
  }

  public func InternalSetID(id: Int32) -> Void {
    this.m_id = id;
  }

  public func InternalScheduleFrom(now: Float) -> Void {
    this.m_nextDue = now + this.m_interval;
  }

  public func InternalScheduleAfter(now: Float, delay: Float) -> Void {
    this.m_nextDue = now + delay;
  }

  public func InternalIsDue(now: Float) -> Bool {
    return this.m_enabled && this.m_nextDue > 0.00 && now >= this.m_nextDue;
  }

  public func InternalAdvanceDue(now: Float) -> Void {
    if !this.m_repeat {
      return;
    }

    if this.m_nextDue <= 0.00 {
      this.m_nextDue = now + this.m_interval;
      return;
    }

    // Preserve cadence, but never replay a backlog after a hitch or load.
    this.m_nextDue += this.m_interval;
    if this.m_nextDue <= now {
      this.m_nextDue = now + this.m_interval;
    }
  }
}

public class SchedulerTickCallback extends DelayCallback {
  private let m_scheduler: wref<Scheduler>;
  private let m_generation: Uint32;

  public static func Create(scheduler: ref<Scheduler>, generation: Uint32) -> ref<SchedulerTickCallback> {
    let self = new SchedulerTickCallback();
    self.m_scheduler = scheduler;
    self.m_generation = generation;
    return self;
  }

  public func Call() -> Void {
    if IsDefined(this.m_scheduler) {
      this.m_scheduler.OnTick(this.m_generation);
    }
  }
}

public class Scheduler extends IScriptable {
  private let m_runtime: wref<Runtime>;
  private let m_state: wref<StateCache>;
  private let m_diagnostics: wref<Diagnostics>;
  private let m_jobs: array<ref<ScheduledJob>>;
  private let m_nextID: Int32;
  private let m_activeJobs: Int32;
  private let m_running: Bool;
  private let m_inTick: Bool;
  private let m_needsCompact: Bool;
  private let m_generation: Uint32;
  private let m_minDelay: Float;
  private let m_delayID: DelayID;

  public func Initialize(runtime: ref<Runtime>, state: ref<StateCache>, diagnostics: ref<Diagnostics>) -> Void {
    this.m_runtime = runtime;
    this.m_state = state;
    this.m_diagnostics = diagnostics;
    this.m_nextID = 1;
    this.m_minDelay = 0.05;
    this.m_generation = 1u;
  }

  public func Shutdown() -> Void {
    this.m_running = false;
    this.m_inTick = false;
    this.m_needsCompact = false;
    this.m_generation += 1u;
    this.CancelCurrentDelay();

    let i: Int32 = 0;
    let count = ArraySize(this.m_jobs);
    while i < count {
      if IsDefined(this.m_jobs[i]) {
        this.m_jobs[i].Disable();
      }
      i += 1;
    }
    ArrayClear(this.m_jobs);
    this.m_activeJobs = 0;
  }

  public func Register(job: ref<ScheduledJob>) -> Int32 {
    if !IsDefined(job) {
      return 0;
    }

    let id = this.m_nextID;
    this.m_nextID += 1;
    job.InternalSetID(id);
    job.Enable();
    job.InternalScheduleFrom(this.Now());
    ArrayPush(this.m_jobs, job);
    this.m_activeJobs += 1;

    // A registration that happens inside a running job is picked up by the
    // single ScheduleNext() at the end of that scheduler tick.
    if !this.m_inTick {
      this.Reschedule();
    }
    return id;
  }

  public func Unregister(id: Int32) -> Bool {
    let i: Int32 = 0;
    let count = ArraySize(this.m_jobs);
    while i < count {
      let job = this.m_jobs[i];
      if IsDefined(job) && job.GetID() == id && job.IsEnabled() {
        job.Disable();
        this.m_activeJobs -= 1;
        this.m_needsCompact = true;

        // Do not rebuild the DelaySystem callback while OnTick is iterating.
        // The disabled job is compacted and the next wakeup is chosen once.
        if !this.m_inTick {
          this.CompactJobs();
          this.Reschedule();
        }
        return true;
      }
      i += 1;
    }
    return false;
  }

  public func RescheduleJob(id: Int32, interval: Float, delay: Float) -> Bool {
    let actualDelay = delay;
    if actualDelay < this.m_minDelay {
      actualDelay = this.m_minDelay;
    }

    let i: Int32 = 0;
    let count = ArraySize(this.m_jobs);
    while i < count {
      let job = this.m_jobs[i];
      if IsDefined(job) && job.GetID() == id && job.IsEnabled() {
        job.SetInterval(interval);
        job.InternalScheduleAfter(this.Now(), actualDelay);
        if !this.m_inTick {
          this.Reschedule();
        }
        return true;
      }
      i += 1;
    }
    return false;
  }

  public func HasJobs() -> Bool {
    return this.m_activeJobs > 0;
  }

  public func GetActiveJobCount() -> Int32 {
    return this.m_activeJobs;
  }

  public func OnTick(generation: Uint32) -> Void {
    if !this.m_running || generation != this.m_generation {
      return;
    }

    this.m_running = false;
    let invalidID: DelayID;
    this.m_delayID = invalidID;
    this.m_inTick = true;

    if IsDefined(this.m_diagnostics) {
      this.m_diagnostics.SchedulerWakeup();
    }

    let now = this.Now();
    let i: Int32 = 0;
    let count = ArraySize(this.m_jobs);

    while i < count {
      let job = this.m_jobs[i];
      if IsDefined(job) && job.IsEnabled() && job.InternalIsDue(now) {
        if IsDefined(this.m_diagnostics) {
          this.m_diagnostics.SchedulerJobRun();
        }

        // Move a repeating deadline before user code. If the job unregisters
        // itself, the disabled state wins and it is compacted after iteration.
        job.InternalAdvanceDue(now);
        job.Execute(this.m_runtime);

        // Preserve Pass-1 one-shot semantics: the callback executes while the
        // job is enabled, then it is retired unless user code already did so.
        if !job.IsRepeating() && job.IsEnabled() {
          job.Disable();
          this.m_needsCompact = true;
        }
      }
      i += 1;
    }

    this.m_inTick = false;
    if this.m_needsCompact {
      this.CompactJobs();
    }
    this.ScheduleNext();
  }

  private func Now() -> Float {
    if !IsDefined(this.m_state) {
      return 0.00;
    }
    return EngineTime.ToFloat(GameInstance.GetEngineTime(this.m_state.GetGame()));
  }

  private func Reschedule() -> Void {
    this.m_generation += 1u;
    this.CancelCurrentDelay();
    this.m_running = false;
    this.ScheduleNext();
  }

  private func ScheduleNext() -> Void {
    if this.m_activeJobs <= 0 || !IsDefined(this.m_state) {
      this.m_running = false;
      return;
    }

    let now = this.Now();
    let nextDue: Float = -1.00;
    let i: Int32 = 0;
    let count = ArraySize(this.m_jobs);

    while i < count {
      let job = this.m_jobs[i];
      if IsDefined(job) && job.IsEnabled() {
        if job.GetNextDue() <= 0.00 {
          job.InternalScheduleFrom(now);
        }
        if nextDue < 0.00 || job.GetNextDue() < nextDue {
          nextDue = job.GetNextDue();
        }
      }
      i += 1;
    }

    if nextDue < 0.00 {
      this.m_running = false;
      this.m_activeJobs = 0;
      return;
    }

    let delay = nextDue - now;
    if delay < this.m_minDelay {
      delay = this.m_minDelay;
    }

    let delaySystem = this.m_state.GetDelaySystem();
    if !IsDefined(delaySystem) {
      this.m_running = false;
      return;
    }

    this.m_running = true;
    this.m_delayID = delaySystem.DelayCallback(
      SchedulerTickCallback.Create(this, this.m_generation),
      delay,
      false
    );
  }

  private func CompactJobs() -> Void {
    let i: Int32 = ArraySize(this.m_jobs) - 1;
    let active: Int32 = 0;

    while i >= 0 {
      let job = this.m_jobs[i];
      if !IsDefined(job) || !job.IsEnabled() {
        ArrayErase(this.m_jobs, i);
      } else {
        active += 1;
      }
      i -= 1;
    }

    this.m_activeJobs = active;
    this.m_needsCompact = false;
  }

  private func CancelCurrentDelay() -> Void {
    if !IsDefined(this.m_state) {
      return;
    }

    let delaySystem = this.m_state.GetDelaySystem();
    let invalidID: DelayID;
    if IsDefined(delaySystem) && NotEquals(this.m_delayID, invalidID) {
      delaySystem.CancelDelay(this.m_delayID);
    }
    this.m_delayID = invalidID;
  }
}
