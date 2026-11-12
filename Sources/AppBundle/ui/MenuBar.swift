import Common
import Foundation
import SwiftUI

@MainActor
public func menuBar(viewModel: TrayMenuModel) -> some Scene { // todo should it be converted to "SwiftUI struct"?
    MenuBarExtra {
        MenuPanel(viewModel: viewModel)
    } label: {
        switch (viewModel.axPermissionStatus, viewModel.isEnabled) {
            case (.granted, true):
                Image(nsImage: menuBarIcon)
            case (.granted, false):
                Image(systemName: "pause.circle.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            case (_, _):
                Image(systemName: "exclamationmark.triangle.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
        }
    }
    .menuBarExtraStyle(.window)
}

/// The app icon's three tiles with space between them, the moving one filled. A template image, so the menu bar
/// tints it
@MainActor private let menuBarIcon: NSImage = {
    let image = NSImage(size: NSSize(width: 18, height: 14), flipped: true) { _ in
        NSColor.black.set()
        let lineWidth: CGFloat = 1.5
        for rect in [NSRect(x: 0.75, y: 0.75, width: 6.5, height: 12.5), NSRect(x: 10.75, y: 0.75, width: 6.5, height: 4.5)] {
            let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            path.lineWidth = lineWidth
            path.stroke()
        }
        NSBezierPath(roundedRect: NSRect(x: 10, y: 8, width: 8, height: 6), xRadius: 2.5, yRadius: 2.5).fill()
        return true
    }
    image.isTemplate = true
    return image
}()
