module GRedRuntime

@addMethod(PlayerPuppet)
public func GRedRuntimeDump() -> String {
  let runtime = Runtime.Get(this.GetGame());
  if IsDefined(runtime) {
    return runtime.DumpDiagnostics();
  }
  return "G-RedRuntime is not available";
}
