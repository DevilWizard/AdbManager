import Foundation

/// 设备上报的品牌标识。原始值用于稳定映射应用内置资源，不依赖本地化文案或设备型号。
/// 未支持的品牌及属性读取失败统一使用 Android 图标，避免凭型号猜错厂商。
public enum DeviceBrand: String, CaseIterable, Sendable {
    case android
    case samsung
    case google
    case xiaomi
    case huawei
    case honor
    case oppo
    case vivo
    case oneplus
    case realme
    case motorola
    case lenovo
    case sony
    case asus
    case nokia
    case nothing

    /// 品牌名称同时供无障碍说明使用；图片无法加载时，调用方仍可准确描述识别结果。
    public var displayName: String {
        switch self {
        case .android: return "Android"
        case .samsung: return "Samsung"
        case .google: return "Google"
        case .xiaomi: return "Xiaomi"
        case .huawei: return "HUAWEI"
        case .honor: return "HONOR"
        case .oppo: return "OPPO"
        case .vivo: return "vivo"
        case .oneplus: return "OnePlus"
        case .realme: return "realme"
        case .motorola: return "Motorola"
        case .lenovo: return "Lenovo"
        case .sony: return "Sony"
        case .asus: return "ASUS"
        case .nokia: return "Nokia"
        case .nothing: return "Nothing"
        }
    }

    /// 优先使用产品品牌，再使用制造商；例如 HONOR 品牌不能被历史 HUAWEI 制造商覆盖。
    /// 只比较明确别名，不使用 contains 或型号前缀，避免 ROM 名称、OEM 字段造成误识别。
    public static func resolve(productBrand: String?, manufacturer: String?) -> DeviceBrand {
        recognizedBrand(productBrand) ?? recognizedBrand(manufacturer) ?? .android
    }

    /// 去掉空白并忽略大小写，以兼容 One Plus、SAMSUNG 等属性写法；其余符号保留用于精确匹配。
    private static func recognizedBrand(_ value: String?) -> DeviceBrand? {
        guard let value else { return nil }
        let normalized = value.lowercased().filter { !$0.isWhitespace }
        switch normalized {
        case "samsung", "samsungelectronics", "samsungelectronicsco.,ltd.": return .samsung
        case "google": return .google
        case "xiaomi", "redmi", "poco": return .xiaomi
        case "huawei": return .huawei
        case "honor": return .honor
        case "oppo": return .oppo
        case "vivo": return .vivo
        case "oneplus", "one-plus": return .oneplus
        case "realme": return .realme
        case "motorola": return .motorola
        case "lenovo", "联想": return .lenovo
        case "sony", "sonyericsson": return .sony
        case "asus", "asustek", "asustekcomputerinc.": return .asus
        // HMD 也生产自有品牌手机，因此不能把所有 HMD 制造商一概标记为 Nokia。
        case "nokia": return .nokia
        case "nothing", "nothingtechnologylimited": return .nothing
        default: return nil
        }
    }
}
