import SwiftUI

enum AppTheme {
    static let brandColor = Color(red: 91/255, green: 141/255, blue: 239/255) // #5B8DEF
    static let background = Color(red: 18/255, green: 18/255, blue: 18/255) // #121212
    static let surfaceColor = Color(red: 30/255, green: 30/255, blue: 30/255) // #1E1E1E
    static let cardColor = Color(red: 40/255, green: 40/255, blue: 40/255)
    static let textPrimary = Color.white
    static let textSecondary = Color(white: 0.6)
    static let textTertiary = Color(white: 0.4)
    static let divider = Color(white: 0.15)

    static let focusBorderWidth: CGFloat = 4
    static let focusGlowRadius: CGFloat = 20
    static let focusScale: CGFloat = 1.08

    static let cornerRadius: CGFloat = 12
    static let cardCornerRadius: CGFloat = 16
    static let posterCornerRadius: CGFloat = 12

    // 侧边栏（对齐安卓 TV 端：内容获焦时折叠为图标，侧栏获焦时展开）
    static let sidebarWidth: CGFloat = 320
    static let sidebarCollapsedWidth: CGFloat = 140

    static let animationDuration: Double = 0.25

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
        static let xxxl: CGFloat = 64
    }

    enum FontSize {
        static let caption: CGFloat = 24
        static let body: CGFloat = 29
        static let title3: CGFloat = 34
        static let title2: CGFloat = 40
        static let title1: CGFloat = 48
        static let largeTitle: CGFloat = 58
    }
}
