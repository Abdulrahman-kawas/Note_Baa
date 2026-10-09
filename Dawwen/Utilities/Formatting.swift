import SwiftUI
import UIKit

enum TimeFormat {
    /// "1:02:03" or "02:03", for the UI.
    static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }

    /// "[01:02:03]", the form used in prompts and exports.
    static func stamp(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0))
        return String(format: "[%02d:%02d:%02d]", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// "01:02:03,450", for SRT subtitles.
    static func srt(_ seconds: Double) -> String {
        let safe = max(0, seconds.isFinite ? seconds : 0)
        let total = Int(safe)
        let millis = Int((safe - Double(total)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", total / 3600, (total % 3600) / 60, total % 60, millis)
    }

    /// "3 س 25 د".
    static func duration(_ seconds: Double) -> String {
        let minutes = Int(max(0, seconds) / 60)
        if minutes < 1 { return "أقل من دقيقة" }
        return minutes >= 60 ? "\(minutes / 60) س \(minutes % 60) د" : "\(minutes) د"
    }

    static func englishDuration(_ seconds: Double) -> String {
        let minutes = Int(max(0, seconds) / 60)
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }
}

extension String {
    /// True when right-to-left letters (Arabic, Hebrew…) outnumber left-to-right ones.
    var isMostlyRTL: Bool {
        var rtl = 0, ltr = 0
        for scalar in unicodeScalars.prefix(400) {
            switch scalar.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF: rtl += 1
            case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F: ltr += 1
            default: break
            }
        }
        return rtl > ltr
    }
}

extension View {
    /// Lays text out in its own direction inside the Arabic UI: English lines start on the left.
    func textDirection(rightToLeft: Bool) -> some View {
        multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight)
    }
}

/// Presents the system share sheet from the top view controller (works as a popover on iPad).
@MainActor
enum SharePresenter {
    static func share(_ items: [Any]) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.keyWindow?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.safeAreaInsets.top + 44, width: 1, height: 1)
            popover.permittedArrowDirections = [.up]
        }
        top.present(controller, animated: true)
    }
}
