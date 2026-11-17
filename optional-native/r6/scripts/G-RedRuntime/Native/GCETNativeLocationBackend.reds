module GRedRuntime

// OPTIONAL source. Distributed only when the CET Resolver's existing
// GCETStaticLocations.dll is included in the SAME GCO generated overlay.
// Core r6/scripts/G-RedRuntime compiles and operates without this file.
// The C++ plugin registers these native methods on ScriptGameInstance.
@addMethod(GameInstance)
public static native func GCETStaticReady() -> Bool

@addMethod(GameInstance)
public static native func GCETStaticCoordinatorState() -> Int32

@addMethod(GameInstance)
public static native func GCETStaticOwnerCount(owner: Int32) -> Int32

@addMethod(GameInstance)
public static native func GCETStaticOwnerAnchor(owner: Int32, index: Int32) -> Int32

@addMethod(GameInstance)
public static native func GCETStaticState(anchor: Int32) -> Int32

@addMethod(GameInstance)
public static native func GCETStaticArm(anchor: Int32, armed: Bool) -> Bool

@addMethod(GameInstance)
public static native func GCETStaticSubscribe(consumer: Int32, owner: Int32) -> Bool

@addMethod(GameInstance)
public static native func GCETStaticUnsubscribe(consumer: Int32) -> Bool

@addMethod(GameInstance)
public static native func GCETStaticNeedsSnapshot(consumer: Int32) -> Bool

@addMethod(GameInstance)
public static native func GCETStaticAckSnapshot(consumer: Int32) -> Bool

@addMethod(GameInstance)
public static native func GCETStaticPoll(consumer: Int32) -> Int32

@addMethod(GameInstance)
public static native func GCETStaticPolledOwner(consumer: Int32) -> Int32

@addMethod(GameInstance)
public static native func GCETStaticPolledState(consumer: Int32) -> Int32

// This is an adapter, not a second native observer. One G-REDruntime service
// consumes the existing C++ ring buffer and publishes only to subscribed mods.
public class GCETNativeLocationBackend extends NativeLocationBackend {
  public func IsReady() -> Bool {
    return GameInstance.GCETStaticReady();
  }
  public func CoordinatorState() -> Int32 {
    return GameInstance.GCETStaticCoordinatorState();
  }
  public func OwnerCount(owner: Int32) -> Int32 {
    return GameInstance.GCETStaticOwnerCount(owner);
  }
  public func OwnerAnchor(owner: Int32, index: Int32) -> Int32 {
    return GameInstance.GCETStaticOwnerAnchor(owner, index);
  }
  public func AnchorState(anchor: Int32) -> Int32 {
    return GameInstance.GCETStaticState(anchor);
  }
  public func Arm(anchor: Int32, armed: Bool) -> Bool {
    return GameInstance.GCETStaticArm(anchor, armed);
  }
  public func Subscribe(consumer: Int32) -> Bool {
    return GameInstance.GCETStaticSubscribe(consumer, 0);
  }
  public func Unsubscribe(consumer: Int32) -> Void {
    GameInstance.GCETStaticUnsubscribe(consumer);
  }
  public func NeedsSnapshot(consumer: Int32) -> Bool {
    return GameInstance.GCETStaticNeedsSnapshot(consumer);
  }
  public func AckSnapshot(consumer: Int32) -> Bool {
    return GameInstance.GCETStaticAckSnapshot(consumer);
  }
  public func Poll(consumer: Int32) -> Int32 {
    return GameInstance.GCETStaticPoll(consumer);
  }
  public func PolledOwner(consumer: Int32) -> Int32 {
    return GameInstance.GCETStaticPolledOwner(consumer);
  }
  public func PolledState(consumer: Int32) -> Int32 {
    return GameInstance.GCETStaticPolledState(consumer);
  }
}
