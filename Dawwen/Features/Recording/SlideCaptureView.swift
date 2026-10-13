import SwiftUI
import VisionKit

/// Reads the text on a slide or whiteboard with the camera (on-device) and hands it to the recording.
struct SlideCaptureView: View {
    let onCapture: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var bridge = SlideScanBridge()

    private var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        NavigationStack {
            Group {
                if isAvailable {
                    SlideScannerRepresentable(bridge: bridge)
                        .ignoresSafeArea(edges: .bottom)
                        .overlay(alignment: .top) {
                            Text("وجّه الكاميرا إلى الشريحة ثم اضغط «التقط»")
                                .font(.footnote)
                                .padding(8)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(.top, 8)
                        }
                } else {
                    ContentUnavailableView(
                        "الماسح غير متاح",
                        systemImage: "camera.metering.unknown",
                        description: Text("يحتاج الماسح كاميرا تعمل وإذناً للوصول إليها.")
                    )
                }
            }
            .navigationTitle("التقاط شريحة")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("التقط") {
                        onCapture(bridge.currentText())
                        dismiss()
                    }
                    .disabled(!isAvailable)
                }
            }
        }
    }
}

/// Lets SwiftUI read the text the scanner currently sees.
@MainActor
final class SlideScanBridge: NSObject, DataScannerViewControllerDelegate {
    private var items: [RecognizedItem] = []

    func currentText() -> [String] {
        items.compactMap { item in
            if case .text(let text) = item { return text.transcript }
            return nil
        }
    }

    func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
        items = allItems
    }

    func dataScanner(_ dataScanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem], allItems: [RecognizedItem]) {
        items = allItems
    }

    func dataScanner(_ dataScanner: DataScannerViewController, didRemove removedItems: [RecognizedItem], allItems: [RecognizedItem]) {
        items = allItems
    }
}

private struct SlideScannerRepresentable: UIViewControllerRepresentable {
    let bridge: SlideScanBridge

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.text(languages: ["en-US"])],
            qualityLevel: .accurate,
            recognizesMultipleItems: true,
            isHighFrameRateTrackingEnabled: false,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = bridge
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: ()) {
        uiViewController.stopScanning()
    }
}
