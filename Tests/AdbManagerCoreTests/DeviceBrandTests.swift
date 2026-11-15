import XCTest
@testable import AdbManagerCore

final class DeviceBrandTests: XCTestCase {
    /// 真实属性常见大小写和子品牌别名应映射到同一资源，同时覆盖全部内置品牌。
    func testRecognizesSupportedBrandsAndExplicitAliases() {
        let examples: [(String, DeviceBrand)] = [
            (" SAMSUNG\n", .samsung), ("Google", .google),
            ("Xiaomi", .xiaomi), ("Redmi", .xiaomi), ("POCO", .xiaomi),
            ("HUAWEI", .huawei), ("HONOR", .honor), ("OPPO", .oppo),
            ("vivo", .vivo), ("One Plus", .oneplus), ("one-plus", .oneplus),
            ("realme", .realme), ("motorola", .motorola), ("Lenovo", .lenovo),
            ("联想", .lenovo), ("Sony", .sony),
            ("ASUSTeK COMPUTER INC.", .asus), ("Nokia", .nokia),
            ("Nothing", .nothing)
        ]
        for (property, expected) in examples {
            XCTAssertEqual(DeviceBrand.resolve(productBrand: property, manufacturer: nil), expected, property)
        }
    }

    /// 品牌优先于制造商；代工关系与历史关系不能覆盖设备明确上报的品牌。
    func testProductBrandTakesPriorityOverManufacturer() {
        XCTAssertEqual(DeviceBrand.resolve(productBrand: "HONOR", manufacturer: "HUAWEI"), .honor)
        XCTAssertEqual(DeviceBrand.resolve(productBrand: "OnePlus", manufacturer: "OPPO"), .oneplus)
        XCTAssertEqual(DeviceBrand.resolve(productBrand: "motorola", manufacturer: "Lenovo"), .motorola)
        XCTAssertEqual(DeviceBrand.resolve(productBrand: "POCO", manufacturer: "Xiaomi"), .xiaomi)
        XCTAssertEqual(DeviceDetails(productBrand: "Google", manufacturer: "HTC").brand, .google)
    }

    /// 缺少品牌或 ROM 上报不支持的品牌时，明确的制造商仍可提供有用的 Logo。
    func testManufacturerFallbackDoesNotUseSubstringOrModelGuesses() {
        XCTAssertEqual(DeviceBrand.resolve(productBrand: nil, manufacturer: "Samsung"), .samsung)
        XCTAssertEqual(DeviceBrand.resolve(productBrand: "custom_rom", manufacturer: "motorola"), .motorola)
        XCTAssertEqual(DeviceBrand.resolve(productBrand: "Samsung-compatible", manufacturer: "HMD"), .android)
        XCTAssertEqual(DeviceBrand.resolve(productBrand: "unknown", manufacturer: "Nothing-like"), .android)
        XCTAssertEqual(DeviceBrand.resolve(productBrand: "", manufacturer: "  \n"), .android)
        XCTAssertEqual(DeviceBrand.resolve(productBrand: nil, manufacturer: nil), .android)
    }
}
