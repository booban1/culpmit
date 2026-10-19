import Foundation

// Number formats shared by the menu and the Touch Bar

let grouped: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    return f
}()

func px(_ v: Double) -> String { (grouped.string(from: NSNumber(value: v)) ?? "\(Int(v))") + " px" }

func megapixels(_ limit: Double) -> String { String(format: "%.1f MP", 0.667 * limit * limit / 1_000_000) }

func percent(_ v: Double) -> String { "\(Int(v.rounded()))%" }

// bytes in GB as Activity Monitor counts them (1,024³), one decimal
let gib = 1_073_741_824.0
func gigabytes(_ bytes: Double) -> String { String(format: "%.1f GB", max(0.1, bytes / gib)) }

func loadingDots(_ n: Int) -> String { String(repeating: ".", count: n) + String(repeating: " ", count: max(0, 3 - n)) }

// the faster fan, the figure the menu bar shows
func fansText(_ fans: [Double]) -> String { fans.max().map { "\(Int($0.rounded())) rpm" } ?? "–" }
