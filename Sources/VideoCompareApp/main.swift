import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let controller = MainWindowController()
        controller.showWindow(nil)
        windowController = controller
        NSApp.activate(ignoringOtherApps: true)
        if let pair = LaunchArguments.videoPair() {
            Diagnostics.log("launch arguments received: \(pair.a.path) / \(pair.b.path)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                Diagnostics.log("loading initial pair")
                controller.loadInitial(a: pair.a, b: pair.b)
                if LaunchArguments.autoplay {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        controller.startSynchronizedPlayback()
                    }
                }
                if LaunchArguments.seekStress {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        controller.runSeekStress()
                    }
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

private enum LaunchArguments {
    static func videoPair() -> (a: URL, b: URL)? {
        let args = CommandLine.arguments
        guard let aIndex = args.firstIndex(of: "--load-a"),
              let bIndex = args.firstIndex(of: "--load-b"),
              args.indices.contains(aIndex + 1),
              args.indices.contains(bIndex + 1) else {
            return nil
        }
        return (
            URL(fileURLWithPath: args[aIndex + 1]),
            URL(fileURLWithPath: args[bIndex + 1])
        )
    }

    static var autoplay: Bool {
        CommandLine.arguments.contains("--autoplay")
    }

    static var seekStress: Bool {
        CommandLine.arguments.contains("--seek-stress")
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
