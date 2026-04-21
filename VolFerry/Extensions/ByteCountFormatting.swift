import Foundation

/// 容量展示：**小数最多保留两位**（整数不补零）。
/// 使用 **十进制 SI（1000 为步进）**，与 macOS「磁盘工具」及硬盘厂商标称（如 2 TB）一致；不再使用 1024（二进制）以免出现约 1.82 TB。
enum ByteCountFormatting {
    
    /// 常规展示：`2 TB`、`500.12 GB`（数字与单位间有空格）
    static func fileString(fromByteCount bytes: Int64) -> String {
        formatted(bytes: bytes, style: .file)
    }
    
    /// 折叠区摘要行：`209.25M`、`2T`、`1.12M`（无空格，单字母后缀）
    static func compactLetter(fromByteCount bytes: Int64) -> String {
        formatted(bytes: bytes, style: .compact)
    }
    
    private enum Style {
        case file
        case compact
    }
    
    private static func formatted(bytes: Int64, style: Style) -> String {
        /// SI：1 KB = 1000 B，与系统磁盘工具一致
        let k: Double = 1000
        let mb = k * k
        let gb = mb * k
        let tb = gb * k
        let pb = tb * k
        
        let x = abs(Double(bytes))
        let sign = bytes < 0 ? "-" : ""
        
        if x < k {
            return "\(sign)\(bytes) B"
        }
        
        let (value, fileUnit, compactSuffix): (Double, String, String)
        if x >= pb {
            (value, fileUnit, compactSuffix) = (x / pb, "PB", "P")
        } else if x >= tb {
            (value, fileUnit, compactSuffix) = (x / tb, "TB", "T")
        } else if x >= gb {
            (value, fileUnit, compactSuffix) = (x / gb, "GB", "G")
        } else if x >= mb {
            (value, fileUnit, compactSuffix) = (x / mb, "MB", "M")
        } else {
            (value, fileUnit, compactSuffix) = (x / k, "KB", "K")
        }
        
        let num = decimalString(value, maxFractionDigits: 2)
        switch style {
        case .file:
            return "\(sign)\(num) \(fileUnit)"
        case .compact:
            return "\(sign)\(num)\(compactSuffix)"
        }
    }
    
    private static func decimalString(_ value: Double, maxFractionDigits: Int) -> String {
        let nf = NumberFormatter()
        nf.locale = .autoupdatingCurrent
        nf.numberStyle = .decimal
        nf.minimumFractionDigits = 0
        nf.maximumFractionDigits = maxFractionDigits
        nf.roundingMode = .halfEven
        return nf.string(from: NSNumber(value: value)) ?? String(format: "%.\(maxFractionDigits)f", value)
    }
}
