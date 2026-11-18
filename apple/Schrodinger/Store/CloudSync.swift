import Foundation
import SwiftData
import CoreData
import CloudKit
import Observation

/// iCloud sync between the user's own devices (SwiftData mirrored to the CloudKit private database).
/// Records what happened so Settings can say whether sync is working, and why not when it isn't.
@MainActor @Observable
final class CloudSync {
    static let shared = CloudSync()
    nonisolated static let containerID = "iCloud.org.schrodinger.app"

    enum Mode: Equatable { case off, on, failed(String) }
    /// Off (the setting), on, or failed: the synced store could not be opened and the app is using a local one.
    private(set) var mode: Mode = .off
    private(set) var account: String = ""
    private(set) var lastImport: Date?
    private(set) var lastExport: Date?
    private(set) var lastError: String?
    private var watching = false

    /// Called once at launch with the outcome of opening the store.
    func opened(sync: Bool, error: Error?) {
        mode = !sync ? .off : error.map { .failed($0.localizedDescription) } ?? .on
        guard sync, !watching else { return }
        watching = true
        // SwiftData syncs through NSPersistentCloudKitContainer, which reports each setup / import / export.
        NotificationCenter.default.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: .main) { note in
            guard let e = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event,
                  let end = e.endDate else { return }
            let type = e.type, ok = e.succeeded, err = e.error.map(CloudSync.describe)
            MainActor.assumeIsolated {
                if ok {
                    if type == .import { CloudSync.shared.lastImport = end }
                    if type == .export { CloudSync.shared.lastExport = end }
                    CloudSync.shared.lastError = nil
                } else if let err { CloudSync.shared.lastError = err }
            }
        }
        Task { await refreshAccount() }
    }

    func refreshAccount() async {
        let status = try? await CKContainer(identifier: Self.containerID).accountStatus()
        account = switch status {
        case .available: "Signed in to iCloud"
        case .noAccount: "Not signed in to iCloud on this device"
        case .restricted: "iCloud is restricted on this device"
        case .temporarilyUnavailable: "iCloud is temporarily unavailable"
        default: "iCloud status unknown"
        }
    }

    /// CloudKit errors carry the useful part (e.g. a record type missing from the schema) in partial errors.
    nonisolated static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if let partial = ns.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error], let first = partial.values.first {
            return (first as NSError).localizedDescription
        }
        if let ck = error as? CKError, let underlying = ck.userInfo[NSUnderlyingErrorKey] as? Error {
            return "\(ck.localizedDescription) (\(underlying.localizedDescription))"
        }
        return ns.localizedDescription
    }

    /// Creates the app's record types in the CloudKit Development environment, from the SwiftData models. Run once from
    /// a development build on a device signed in to iCloud (launch argument `-initCloudKitSchema`), then deploy the
    /// schema to Production in the CloudKit Console; TestFlight and App Store builds can only use a deployed schema.
    /// Uses a scratch store, so no data is touched.
    nonisolated static func initializeSchema(types: [any PersistentModel.Type]) {
        guard let model = NSManagedObjectModel.makeManagedObjectModel(for: types) else { print("CloudSync: no model"); return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("schema-init-\(UUID().uuidString).store")
        let desc = NSPersistentStoreDescription(url: url)
        desc.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: containerID)
        desc.shouldAddStoreAsynchronously = false
        let container = NSPersistentCloudKitContainer(name: "SchemaInit", managedObjectModel: model)
        container.persistentStoreDescriptions = [desc]
        var loadError: Error?
        container.loadPersistentStores { _, e in loadError = e }
        if let loadError { print("CloudSync: schema store failed: \(loadError)"); return }
        do { try container.initializeCloudKitSchema(); print("CloudSync: schema initialized in Development") }
        catch { print("CloudSync: schema init failed: \(describe(error))") }
        if let store = container.persistentStoreCoordinator.persistentStores.first { try? container.persistentStoreCoordinator.remove(store) }
        try? FileManager.default.removeItem(at: url)
    }
}
