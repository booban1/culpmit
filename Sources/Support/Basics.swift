import Foundation

// Settings every part shares, their defaults, and the machine's thread count

let store = UserDefaults.standard

let threads = Double(ProcessInfo.processInfo.activeProcessorCount)

// the model identifier
let machineModel: String = {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var bytes = [CChar](repeating: 0, count: max(1, size))
    sysctlbyname("hw.model", &bytes, &size, nil, 0)
    return String(cString: bytes)
}()

func registerDefaults() {
    store.register(defaults: ["shrink": true, "radios": true, "shotLimit": 1500.0, "heatAlerts": true, "backToSleep": true,
                              "figmaSocket": false, "touchBar": true, "history": true, "testMinutes": 3.0, "heatLine": 85.0, "cpuAlerts": true, "cpuLine": 80.0, "memoryAlerts": true, "memoryAlertLine": 0.9])
}
