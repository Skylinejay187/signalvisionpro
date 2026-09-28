import SwiftUI
import Foundation

/// v787 architecture migration: centralizes Settings category focus math/routing helpers.
/// This is intentionally stateless and behavior-preserving so Settings UI, focus order,
/// Membership access, player toggles, trailer toggles, and existing AppStorage keys remain unchanged.
enum SettingsStateFocusManager {
    static let categoryCardWidth: CGFloat = 238
    static let categorySpacing: CGFloat = 14
    static let categoryViewportWidth: CGFloat = 1690
    static let categoryMoveDebounceSeconds: TimeInterval = 0.14

    static func rowOffset<Category: CaseIterable & Equatable>(
        selected: Category,
        allCategories: Category.AllCases,
        cardWidth: CGFloat = categoryCardWidth,
        spacing: CGFloat = categorySpacing,
        viewportWidth: CGFloat = categoryViewportWidth
    ) -> CGFloat where Category.AllCases: Collection {
        let categories = Array(allCategories)
        let index = CGFloat(categories.firstIndex(of: selected) ?? categories.startIndex)
        let totalWidth = CGFloat(categories.count) * cardWidth + CGFloat(max(0, categories.count - 1)) * spacing
        let targetCenter = index * (cardWidth + spacing) + (cardWidth / 2)
        let rawOffset = (viewportWidth / 2) - targetCenter
        let minOffset = min(0, viewportWidth - totalWidth)
        return min(0, max(minOffset, rawOffset))
    }

    static func shouldAcceptCategoryMove(lastMoveAt: inout Date, now: Date = Date()) -> Bool {
        guard now.timeIntervalSince(lastMoveAt) > categoryMoveDebounceSeconds else { return false }
        lastMoveAt = now
        return true
    }

    static func adjacentCategory<Category: CaseIterable & Equatable>(
        from category: Category,
        direction: SignalMoveDirection,
        allCategories: Category.AllCases
    ) -> Category? where Category.AllCases: Collection {
        let categories = Array(allCategories)
        guard let index = categories.firstIndex(of: category) else { return nil }
        switch direction {
        case .left:
            return categories[max(0, index - 1)]
        case .right:
            return categories[min(categories.count - 1, index + 1)]
        default:
            return nil
        }
    }

    static func normalizedSourceLinkLimit(_ value: Any?, fallback: Int = 25) -> Int {
        if let intValue = value as? Int { return intValue == 50 ? 50 : 25 }
        if let stringValue = value as? String, Int(stringValue) == 50 { return 50 }
        return fallback == 50 ? 50 : 25
    }

}
