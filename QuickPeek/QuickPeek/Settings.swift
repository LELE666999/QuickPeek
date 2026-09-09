import SwiftUI
import ServiceManagement
import Carbon.HIToolbox

@MainActor
class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("showFileSize") var showFileSize = true
    @AppStorage("showCreateDate") var showCreateDate = true
    @AppStorage("showModifyDate") var showModifyDate = true
    @AppStorage("showFormat") var showFormat = true
    @AppStorage("showDimensions") var showDimensions = true
    @AppStorage("showColorSpace") var showColorSpace = true
    @AppStorage("showDPI") var showDPI = true
    @AppStorage("showEXIF") var showEXIF = true
    @AppStorage("showPDFPages") var showPDFPages = true
    @AppStorage("showMediaDuration") var showMediaDuration = true
    @AppStorage("showCodeLines") var showCodeLines = true
    @AppStorage("showEncoding") var showEncoding = true

    // Per-category "Open With" app paths (empty = system default)
    @AppStorage("openWithApp_spreadsheet") var openWithSpreadsheet = ""
    @AppStorage("openWithApp_document") var openWithDocument = ""
    @AppStorage("openWithApp_code") var openWithCode = ""
    @AppStorage("openWithApp_music") var openWithMusic = ""
    @AppStorage("openWithApp_other") var openWithOther = ""

    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet {
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    var preferredColorScheme: ColorScheme? {
        .dark
    }
}
