import Foundation

/// 极简本地化：按系统首选语言在中英文字符串间二选一（无 .strings 文件，Sources 里一处引用一次）。
enum L {
    static let isZh: Bool = (Locale.preferredLanguages.first ?? "").lowercased().hasPrefix("zh")
    static func t(_ en: String, _ zh: String) -> String { isZh ? zh : en }
}
