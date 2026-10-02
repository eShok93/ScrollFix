/// A value-only view of feature state, shared by the menu and status window.
struct ScrollFixStatusSnapshot {
    let directionEnabled: Bool
    let directionRunning: Bool
    let directionStarting: Bool
    let directionPausedByUserInput: Bool
    let directionIssue: String?
    let permissionGranted: Bool
    let autoScrollEnabled: Bool
    let autoScrollRunning: Bool
    var wheelRequiresPosting = false
    var wheelCanPost = false
    var autoScrollCanPost = false
    var autoScrollHasIssue = false

    var anyFeatureEnabled: Bool { directionEnabled || autoScrollEnabled }
    var wheelNeedsAccess: Bool { directionEnabled && wheelRequiresPosting && !wheelCanPost }
    var needsFeatureRecovery: Bool {
        (directionEnabled && !directionRunning && !directionStarting)
            || wheelNeedsAccess || (autoScrollEnabled && autoScrollHasIssue)
    }
    var featureRecoveryTitle: String {
        let needsInterception = !permissionGranted && !directionRunning
        let needsPosting = wheelNeedsAccess || (autoScrollEnabled && !autoScrollCanPost)
        return needsInterception || needsPosting ? "Zugriff erlauben" : "Erneut starten"
    }

    var allEnabledFeaturesActive: Bool {
        anyFeatureEnabled && (!directionEnabled || directionRunning)
            && (!autoScrollEnabled || autoScrollRunning) && !wheelNeedsAccess
    }

    var overallAccessibilityState: String {
        if !anyFeatureEnabled { return "nicht aktiv" }
        return allEnabledFeaturesActive ? "aktiv" : "prüfen"
    }

    var directionHeadline: String {
        if !directionEnabled { return "Richtungsfix aus" }
        if directionRunning { return "Bereit" }
        if directionStarting { return "Filter startet" }
        if directionPausedByUserInput { return "Filter pausiert" }
        if !permissionGranted { return "macOS-Zugriff nötig" }
        return "Filter prüfen"
    }

    var directionDetail: String {
        if !directionEnabled { return "Beide Geräte folgen macOS." }
        if directionRunning { return "Vertikal: erkannte Quellen korrigiert; unklare bleiben unverändert." }
        if directionStarting { return "macOS startet den Scrollfilter." }
        if directionPausedByUserInput {
            return "macOS hat den Scrollfilter deaktiviert. Mit „Erneut prüfen“ neu starten."
        }
        if let directionIssue { return directionIssue }
        if !permissionGranted { return "Erlaube ScrollFix in den macOS-Systemeinstellungen." }
        return "Der Scrollfilter konnte nicht starten."
    }
}
