//
//  ALTDeviceManager+Installation.swift
//  AltServer
//
//  Created by Riley Testut on 7/1/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import Cocoa
import UserNotifications
import ObjectiveC
import CryptoKit
import OSLog

struct ManagedApplication
{
    let name: String
    let bundleIdentifier: String
    let version: String
    let expirationDate: Date?
    let teamIdentifier: String?
}

struct ManagedIPA
{
    let name: String
    let bundleIdentifier: String
    let version: String
    let url: URL
}

struct ManagedApplicationRefreshResult
{
    let bundleIdentifier: String
    let expirationDate: Date
}

private struct ManagedApplicationSnapshot
{
    let applications: [[String: Any]]
    let profiles: [ALTProvisioningProfile]

    func application(_ identifier: String) -> [String: Any]?
    {
        return applications.first { ($0[kCFBundleIdentifierKey as String] as? String) == identifier }
    }

    func profile(_ identifier: String) -> ALTProvisioningProfile?
    {
        return profiles.filter { $0.bundleIdentifier == identifier }.max { $0.expirationDate < $1.expirationDate }
    }

    func relatedProfiles(_ identifier: String) -> [ALTProvisioningProfile]
    {
        guard let mainProfile = profile(identifier) else { return [] }
        let mainIdentifiers = Set(applications.compactMap { $0[kCFBundleIdentifierKey as String] as? String })
        let candidates = profiles.filter {
            $0.teamIdentifier == mainProfile.teamIdentifier &&
            ($0.bundleIdentifier == identifier || ($0.bundleIdentifier.hasPrefix(identifier + ".") && !mainIdentifiers.contains($0.bundleIdentifier)))
        }
        return Dictionary(grouping: candidates, by: \.bundleIdentifier).values.compactMap {
            $0.max { $0.expirationDate < $1.expirationDate }
        }.sorted { $0.bundleIdentifier < $1.bundleIdentifier }
    }
}

private let managedApplicationLock = NSLock()
private var managedApplicationDevices = Set<String>()

private func beginManagedApplicationOperation(on device: ALTDevice) -> Bool
{
    managedApplicationLock.lock()
    defer { managedApplicationLock.unlock() }
    return managedApplicationDevices.insert(device.identifier).inserted
}

private func endManagedApplicationOperation(on device: ALTDevice)
{
    managedApplicationLock.lock()
    defer { managedApplicationLock.unlock() }
    managedApplicationDevices.remove(device.identifier)
}

private func managedApplicationError(_ description: String) -> NSError
{
    return NSError(domain: "com.rileytestut.AltServer.ManagedApplications", code: 1,
                   userInfo: [NSLocalizedDescriptionKey: description])
}

private func completeManagedApplication<T>(_ result: Result<T, Error>, _ completion: @escaping (Result<T, Error>) -> Void)
{
    DispatchQueue.main.async { completion(result) }
}

private func managedApplicationValue<T>(_ operation: (@escaping (T?, Error?) -> Void) -> Void) async throws -> T
{
    return try await withCheckedThrowingContinuation { continuation in
        operation { value, error in
            if let value { continuation.resume(returning: value) }
            else { continuation.resume(throwing: error ?? ALTAppleAPIError.unknown()) }
        }
    }
}

private func managedApplicationResult<T>(_ operation: (@escaping (Result<T, Error>) -> Void) -> Void) async throws -> T
{
    return try await withCheckedThrowingContinuation { continuation in
        operation { continuation.resume(with: $0) }
    }
}

#if STAGING
let altstoreSourceURL = URL(string: "https://f000.backblazeb2.com/file/altstore-staging/apps-staging.json")!
#else
let altstoreSourceURL = URL(string: "https://apps.altstore.io")!
#endif

#if BETA
let altstoreBundleID = "com.rileytestut.AltStore.Beta"
#else
let altstoreBundleID = "com.rileytestut.AltStore"
#endif

private let appGroupsSemaphore = DispatchSemaphore(value: 1)
private let developerDiskManager = DeveloperDiskManager()

private let session: URLSession = {
    let configuration = URLSessionConfiguration.default
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    
    let session = URLSession(configuration: configuration)
    return session
}()

extension OperationError
{
    enum Code: Int, ALTErrorCode
    {
        typealias Error = OperationError
        
        case cancelled
        case noTeam
        case missingPrivateKey
        case missingCertificate
    }
    
    static let cancelled = OperationError(code: .cancelled)
    static let noTeam = OperationError(code: .noTeam)
    static let missingPrivateKey = OperationError(code: .missingPrivateKey)
    static let missingCertificate = OperationError(code: .missingCertificate)
}

struct OperationError: ALTLocalizedError
{
    var code: Code
    var errorTitle: String?
    var errorFailure: String?
    
    var errorFailureReason: String {
        switch self.code
        {
        case .cancelled: return NSLocalizedString("The operation was cancelled.", comment: "")
        case .noTeam: return NSLocalizedString("You are not a member of any developer teams.", comment: "")
        case .missingPrivateKey: return NSLocalizedString("The developer certificate's private key could not be found.", comment: "")
        case .missingCertificate: return NSLocalizedString("The developer certificate could not be found.", comment: "")
        }
    }
}

private extension ALTDeviceManager
{
    struct Source: Decodable
    {
        struct App: Decodable
        {
            struct Version: Decodable
            {
                var version: String
                var downloadURL: URL
                
                var minimumOSVersion: OperatingSystemVersion? {
                    return self.minOSVersion.map { OperatingSystemVersion(string: $0) }
                }
                private var minOSVersion: String?
            }
            
            var name: String
            var bundleIdentifier: String
            
            var versions: [Version]?
        }
        
        var name: String
        var identifier: String
        
        var apps: [App]
    }
}

extension ALTDeviceManager
{
    func fetchInstalledAppProfiles(_ bundleIdentifiers: Set<String>, on device: ALTDevice,
                                   completion: @escaping (Result<[InstalledAppProfile], Error>) -> Void)
    {
        Task<Void, Never> {
            do
            {
                let snapshot = try await self.managedApplicationSnapshot(on: device)
                let applications = try bundleIdentifiers.sorted().map { identifier -> InstalledAppProfile in
                    guard let application = snapshot.application(identifier) else {
                        throw managedApplicationError(NSLocalizedString("A requested app is no longer installed on this iPhone. Reload the app list and try again.", comment: ""))
                    }
                    guard let profile = snapshot.profile(identifier), !profile.data.isEmpty,
                          profile.deviceIDs.contains(where: { $0.caseInsensitiveCompare(device.identifier) == .orderedSame }) else {
                        throw managedApplicationError(NSLocalizedString("A requested app has no readable provisioning profile for this iPhone. Its expiration date could not be synced.", comment: ""))
                    }
                    guard let buildVersion = application[kCFBundleVersionKey as String] as? String, !buildVersion.isEmpty,
                          let version = (application["CFBundleShortVersionString"] as? String) ?? (application[kCFBundleVersionKey as String] as? String), !version.isEmpty else {
                        throw managedApplicationError(NSLocalizedString("The iPhone did not report a requested app's installed version. Its expiration date could not be synced.", comment: ""))
                    }
                    return InstalledAppProfile(bundleIdentifier: identifier, version: version, buildVersion: buildVersion,
                                               provisioningProfile: profile.data)
                }
                completeManagedApplication(.success(applications), completion)
            }
            catch { completeManagedApplication(.failure(error), completion) }
        }
    }

    func fetchManagedApplications(on device: ALTDevice, completion: @escaping (Result<[ManagedApplication], Error>) -> Void)
    {
        Task<Void, Never> {
            do
            {
                let snapshot = try await self.managedApplicationSnapshot(on: device)
                let applications = snapshot.applications.compactMap { dictionary -> ManagedApplication? in
                    guard let identifier = dictionary[kCFBundleIdentifierKey as String] as? String else { return nil }
                    let profile = snapshot.profile(identifier)
                    guard profile != nil || dictionary[Bundle.Info.altBundleID] != nil else { return nil }
                    return self.managedApplication(dictionary, profile: profile)
                }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                completeManagedApplication(.success(applications), completion)
            }
            catch { completeManagedApplication(.failure(error), completion) }
        }
    }

    func inspectManagedIPA(at url: URL, completion: @escaping (Result<ManagedIPA, Error>) -> Void)
    {
        Task<Void, Never> {
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            do
            {
                let application = try self.unpackManagedIPA(at: url, to: directory)
                let ipa = ManagedIPA(name: application.name, bundleIdentifier: application.bundleIdentifier,
                                     version: application.version, url: url)
                completeManagedApplication(.success(ipa), completion)
            }
            catch { completeManagedApplication(.failure(error), completion) }
        }
    }

    func refreshManagedApplications(_ identifiers: [String], on device: ALTDevice, appleID: String, password: String,
                                    completion: @escaping (Result<[ManagedApplicationRefreshResult], Error>) -> Void)
    {
        guard beginManagedApplicationOperation(on: device) else {
            return completeManagedApplication(.failure(managedApplicationError(NSLocalizedString("An app operation is already running for this device.", comment: ""))), completion)
        }
        Task<Void, Never> {
            defer { endManagedApplicationOperation(on: device) }
            do
            {
                let identifiers = Array(Set(identifiers)).sorted()
                guard !identifiers.isEmpty else { return completeManagedApplication(.success([]), completion) }
                let snapshot = try await self.managedApplicationSnapshot(on: device)
                var previousProfiles = [ALTProvisioningProfile]()
                for identifier in identifiers
                {
                    guard snapshot.application(identifier) != nil, snapshot.profile(identifier) != nil else {
                        throw managedApplicationError(NSLocalizedString("The selected app has no readable device provisioning profile. Use its original IPA to re-sign it.", comment: ""))
                    }
                    previousProfiles.append(contentsOf: snapshot.relatedProfiles(identifier))
                }

                // Sign in once for the entire selection. Select each team by the
                // device's profile, never by the account's preferred/default team.
                let (account, session) = try await self.managedAuthentication(appleID: appleID, password: password)
                let teams: [ALTTeam] = try await managedApplicationValue { ALTAppleAPI.shared.fetchTeams(for: account, session: session, completionHandler: $0) }
                let groups = Dictionary(grouping: previousProfiles, by: \.teamIdentifier)
                var refreshedProfiles = [ALTProvisioningProfile]()
                for teamIdentifier in groups.keys.sorted()
                {
                    guard let team = teams.first(where: { $0.identifier == teamIdentifier }) else {
                        throw managedApplicationError(NSLocalizedString("This Apple account does not belong to the selected app's signing team. Sign in with the account that installed it.", comment: ""))
                    }
                    let registeredDevice: ALTDevice = try await managedApplicationResult { self.register(device, team: team, session: session, completionHandler: $0) }
                    registeredDevice.osVersion = device.osVersion
                    let appIDs: [ALTAppID] = try await managedApplicationValue { ALTAppleAPI.shared.fetchAppIDs(for: team, session: session, completionHandler: $0) }
                    for previousProfile in groups[teamIdentifier] ?? []
                    {
                        guard let appID = appIDs.first(where: { $0.bundleIdentifier == previousProfile.bundleIdentifier }) else {
                            throw managedApplicationError(NSLocalizedString("The selected app's exact App ID is missing from this team. Use its original IPA to re-sign it; refreshing will not create another App ID.", comment: ""))
                        }
                        let profile: ALTProvisioningProfile = try await managedApplicationResult {
                            self.fetchProvisioningProfile(for: appID, device: registeredDevice, team: team, session: session, completionHandler: $0)
                        }
                        try self.validateManagedRefresh(profile, replacing: previousProfile, device: device)
                        refreshedProfiles.append(profile)
                    }
                }

                // nil removes only the selected apps' older profiles. The native
                // installer restores them if any replacement fails.
                try await self.installManagedProfiles(refreshedProfiles, on: device)
                do
                {
                    let installedProfiles: [ALTProvisioningProfile] = try await managedApplicationValue { self.fetchProvisioningProfiles(on: device, completionHandler: $0) }
                    for profile in refreshedProfiles
                    {
                        guard installedProfiles.contains(where: { $0.uuid == profile.uuid && $0.expirationDate == profile.expirationDate }) else {
                            throw managedApplicationError(NSLocalizedString("The device did not report the renewed profile after installation. The previous profiles will be restored.", comment: ""))
                        }
                    }
                }
                catch
                {
                    do { try await self.installManagedProfiles(previousProfiles, on: device) }
                    catch {
                        throw managedApplicationError(NSLocalizedString("Renewal could not be verified and the previous profiles could not all be restored. Reconnect the device and re-sign the selected apps with their original IPA files.", comment: ""))
                    }
                    throw error
                }
                let results = identifiers.compactMap { identifier -> ManagedApplicationRefreshResult? in
                    guard let date = refreshedProfiles.first(where: { $0.bundleIdentifier == identifier })?.expirationDate else { return nil }
                    return ManagedApplicationRefreshResult(bundleIdentifier: identifier, expirationDate: date)
                }
                completeManagedApplication(.success(results), completion)
            }
            catch { completeManagedApplication(.failure(error), completion) }
        }
    }

    func updateManagedApplication(_ identifier: String, withIPAAt url: URL, on device: ALTDevice, appleID: String, password: String,
                                  completion: @escaping (Result<ManagedApplication, Error>) -> Void)
    {
        guard beginManagedApplicationOperation(on: device) else {
            return completeManagedApplication(.failure(managedApplicationError(NSLocalizedString("An app operation is already running for this device.", comment: ""))), completion)
        }
        Task<Void, Never> {
            let hasAccess = url.startAccessingSecurityScopedResource()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer {
                if hasAccess { url.stopAccessingSecurityScopedResource() }
                try? FileManager.default.removeItem(at: directory)
                endManagedApplicationOperation(on: device)
            }
            do
            {
                guard url.isFileURL, url.pathExtension.lowercased() == "ipa" else {
                    throw managedApplicationError(NSLocalizedString("Choose a local .ipa file.", comment: ""))
                }
                // Pin the original input until verification completes so a changed
                // source file cannot later replace the known-good cached IPA.
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let originalURL = directory.appendingPathComponent("Original.ipa")
                try FileManager.default.copyItem(at: url, to: originalURL)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: originalURL.path)
                let application = try self.unpackManagedIPA(at: originalURL, to: directory)
                guard application.minimumiOSVersion <= device.osVersion else {
                    throw managedApplicationError(NSLocalizedString("This IPA requires a newer iOS version than the selected device. Choose a compatible version; no sign-in or device changes were performed.", comment: ""))
                }
                let originalIPA = ManagedIPA(name: application.name, bundleIdentifier: application.bundleIdentifier,
                                             version: application.version, url: originalURL)
                let originalBuildVersion = application.buildVersion
                let snapshot = try await self.managedApplicationSnapshot(on: device)
                guard let installedDictionary = snapshot.application(identifier) else {
                    throw managedApplicationError(NSLocalizedString("The selected app is no longer installed on this device.", comment: ""))
                }
                guard let teamIdentifier = snapshot.profile(identifier)?.teamIdentifier ?? self.managedTeamIdentifierHint(installedDictionary) else {
                    throw managedApplicationError(NSLocalizedString("The selected app's signing team could not be determined from a device profile or its exact AltStore bundle identifiers. Reconnect and reload the app list.", comment: ""))
                }
                let signedIdentifier = self.managedSignedIdentifier(for: application, teamIdentifier: teamIdentifier)
                guard signedIdentifier == identifier else {
                    throw managedApplicationError(NSLocalizedString("This IPA would install as a different app. Choose the original, unsigned IPA matching the selected app's bundle identifier; already re-signed IPAs can contain a duplicate team suffix.", comment: ""))
                }

                let syncAltStore = application.isAltStoreApp && (application.bundle.object(forInfoDictionaryKey: "ALTManagedProfileSyncVersion") as? Int) == 1
                if syncAltStore
                {
                    // Ad hoc signatures preserve the build's requested entitlements.
                    // A completely unsigned binary loses them when AltSign reads it.
                    // Reject that input before changing the existing App ID's groups.
                    for component in [application] + Array(application.appExtensions)
                    {
                        guard let groups = component.entitlements[.appGroups] as? [String],
                              groups.contains("group.com.rileytestut.AltStore") else {
                            throw managedApplicationError(NSLocalizedString("Use AltStore-adhoc.ipa from this release to preserve AltStore's shared database and widget access. The fully unsigned IPA has no embedded entitlement signature and cannot be used for this update.", comment: ""))
                        }
                    }
                    guard let previous = snapshot.profile(identifier),
                          let groups = previous.entitlements[.appGroups] as? [String],
                          groups.contains("group.com.rileytestut.AltStore." + teamIdentifier) else {
                        throw managedApplicationError(NSLocalizedString("The installed AltStore's shared database group could not be verified. Reload the connected device before updating AltStore.", comment: ""))
                    }
                    for previous in snapshot.relatedProfiles(identifier)
                    {
                        let components = [application] + Array(application.appExtensions)
                        guard let component = components.first(where: {
                            self.managedSignedIdentifier(for: $0, teamIdentifier: teamIdentifier) == previous.bundleIdentifier
                        }), let requestedGroups = component.entitlements[.appGroups] as? [String],
                              Set(previous.entitlements[.appGroups] as? [String] ?? []).isSubset(of: Set(requestedGroups.map { $0 + "." + teamIdentifier })) else {
                            throw managedApplicationError(NSLocalizedString("This AltStore package would remove an existing shared database group. No Apple App ID or installed app was changed.", comment: ""))
                        }
                    }
                }

                let (account, session) = try await self.managedAuthentication(appleID: appleID, password: password)
                let teams: [ALTTeam] = try await managedApplicationValue { ALTAppleAPI.shared.fetchTeams(for: account, session: session, completionHandler: $0) }
                guard let team = teams.first(where: { $0.identifier == teamIdentifier }) else {
                    throw managedApplicationError(NSLocalizedString("This Apple account does not belong to the selected app's signing team. Updating it with another team would create a separate app.", comment: ""))
                }
                let registeredDevice: ALTDevice = try await managedApplicationResult { self.register(device, team: team, session: session, completionHandler: $0) }
                registeredDevice.osVersion = device.osVersion
                let certificate = try await self.managedExistingCertificate(for: team, session: session)
                try self.preserveManagedApplicationUTIs(in: application, installedDictionary: installedDictionary, signedIdentifier: identifier)
                let profiles: [String: ALTProvisioningProfile] = try await managedApplicationResult {
                    self.prepareAllProvisioningProfiles(for: application, device: registeredDevice, team: team, session: session, completion: $0)
                }
                if syncAltStore
                {
                    for previous in snapshot.relatedProfiles(identifier)
                    {
                        let oldGroups = Set(previous.entitlements[.appGroups] as? [String] ?? [])
                        guard let replacement = profiles.values.first(where: { $0.bundleIdentifier == previous.bundleIdentifier }),
                              oldGroups.isSubset(of: Set(replacement.entitlements[.appGroups] as? [String] ?? [])) else {
                            throw managedApplicationError(NSLocalizedString("The new AltStore profiles would change an existing shared database group. The installed app was not replaced.", comment: ""))
                        }
                    }
                }
                guard let profile = profiles[application.bundleIdentifier], profile.bundleIdentifier == identifier,
                      profile.teamIdentifier == teamIdentifier,
                      profile.deviceIDs.contains(where: { $0.caseInsensitiveCompare(device.identifier) == .orderedSame }),
                      profile.expirationDate > Date(), profile.certificates.contains(where: { $0.serialNumber == certificate.serialNumber }) else {
                    throw managedApplicationError(NSLocalizedString("The new signing profile does not match the selected app, device, team, or signing certificate. The installed app was not changed.", comment: ""))
                }

                let pairingFile: Data? = await withCheckedContinuation { continuation in
                    self.encryptedPairingData(for: application, device: registeredDevice, certificate: certificate) { continuation.resume(returning: $0) }
                }
                _ = try await managedApplicationResult { (callback: @escaping (Result<Void, Error>) -> Void) in
                    self.install(application, to: registeredDevice, team: team, certificate: certificate, profiles: profiles, pairingFile: pairingFile, completionHandler: callback)
                }
                let updatedSnapshot = try await self.managedApplicationSnapshot(on: device)
                guard let updatedDictionary = updatedSnapshot.application(identifier), let updatedProfile = updatedSnapshot.profile(identifier),
                      updatedProfile.uuid == profile.uuid, updatedProfile.teamIdentifier == team.identifier,
                      updatedProfile.expirationDate == profile.expirationDate,
                      (updatedDictionary["CFBundleShortVersionString"] as? String) == originalIPA.version,
                      (updatedDictionary[kCFBundleVersionKey as String] as? String) == originalBuildVersion else {
                    throw managedApplicationError(NSLocalizedString("Installation completed, but the updated app could not be verified on the device. Reconnect and reload the app list before retrying.", comment: ""))
                }
                // Cache only verified updates. Capture metadata before re-signing;
                // a cache failure must not misreport the successful installation.
                do { try self.cacheManagedIPA(originalIPA, signedIdentifier: identifier) }
                catch { Logger.main.error("The app update was verified, but its original IPA could not be cached.") }
                completeManagedApplication(.success(self.managedApplication(updatedDictionary, profile: updatedProfile)), completion)
            }
            catch { completeManagedApplication(.failure(error), completion) }
        }
    }

    func cachedManagedIPAURL(for identifier: String) -> URL?
    {
        let url = self.managedIPADirectory(for: identifier).appendingPathComponent("Original.ipa")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func installApplication(at ipaFileURL: URL?, to altDevice: ALTDevice, appleID: String, password: String, completion: @escaping (Result<ALTApplication, Error>) -> Void)
    {
        let destinationDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        
        var appName = ipaFileURL?.deletingPathExtension().lastPathComponent ?? NSLocalizedString("AltStore", comment: "")
        
        func finish(_ result: Result<ALTApplication, Error>, failure: String? = nil)
        {
            DispatchQueue.main.async {
                switch result
                {
                case .success(let app): completion(.success(app))
                case .failure(var error as NSError):
                    error = error.withLocalizedTitle(String(format: NSLocalizedString("%@ could not be installed onto %@.", comment: ""), appName, altDevice.name))
                    
                    if let failure, error.localizedFailure == nil
                    {
                        error = error.withLocalizedFailure(failure)
                    }
                    
                    completion(.failure(error))
                }
            }
            
            try? FileManager.default.removeItem(at: destinationDirectoryURL)
        }
        
        AnisetteDataManager.shared.requestAnisetteData { (result) in
            do
            {
                let anisetteData = try result.get()
                
                self.authenticate(appleID: appleID, password: password, anisetteData: anisetteData) { (result) in
                    do
                    {
                        let (account, session) = try result.get()
                        
                        self.fetchTeam(for: account, session: session) { (result) in
                            do
                            {
                                let team = try result.get()
                                
                                self.register(altDevice, team: team, session: session) { (result) in
                                    do
                                    {
                                        let device = try result.get()
                                        device.osVersion = altDevice.osVersion
                                        
                                        self.fetchCertificate(for: team, session: session) { (result) in
                                            do
                                            {
                                                let certificate = try result.get()
                                                
                                                if ipaFileURL == nil
                                                {
                                                    // Show alert before downloading remote .ipa.
                                                    self.showInstallationAlert(appName: NSLocalizedString("AltStore", comment: ""), deviceName: altDevice.name)
                                                }
                                                
                                                self.prepare(device) { (result) in
                                                    switch result
                                                    {
                                                    case .failure(let error):
                                                        print("Failed to install DeveloperDiskImage.dmg to \(device).", error)
                                                        fallthrough // Continue installing app even if we couldn't install Developer disk image.
                                                    
                                                    case .success:
                                                        self.downloadApp(from: ipaFileURL, for: altDevice) { (result) in
                                                            do
                                                            {
                                                                let fileURL = try result.get()
                                                                
                                                                try FileManager.default.createDirectory(at: destinationDirectoryURL, withIntermediateDirectories: true, attributes: nil)
                                                                
                                                                let appBundleURL = try FileManager.default.unzipAppBundle(at: fileURL, toDirectory: destinationDirectoryURL)
                                                                guard let application = ALTApplication(fileURL: appBundleURL) else { throw ALTError(.invalidApp) }
                                                                
                                                                if ipaFileURL != nil
                                                                {
                                                                    // Show alert after "downloading" local .ipa.
                                                                    self.showInstallationAlert(appName: application.name, deviceName: altDevice.name)
                                                                }
                                                                
                                                                appName = application.name
                                                                
                                                                // Refresh anisette data to prevent session timeouts.
                                                                AnisetteDataManager.shared.requestAnisetteData { (result) in
                                                                    do
                                                                    {
                                                                        let anisetteData = try result.get()
                                                                        session.anisetteData = anisetteData
                                                                        
                                                                        self.prepareAllProvisioningProfiles(for: application, device: device, team: team, session: session) { (result) in
                                                                            do
                                                                            {
                                                                                let profiles = try result.get()
                                                                                
                                                                                self.encryptedPairingData(for: application, device: device, certificate: certificate) { pairingFile in
                                                                                    self.install(application, to: device, team: team, certificate: certificate, profiles: profiles, pairingFile: pairingFile) { (result) in
                                                                                        finish(result.map { application })
                                                                                    }
                                                                                }
                                                                            }
                                                                            catch
                                                                            {
                                                                                finish(.failure(error), failure: NSLocalizedString("AltServer could not fetch new provisioning profiles.", comment: ""))
                                                                            }
                                                                        }
                                                                    }
                                                                    catch
                                                                    {
                                                                        finish(.failure(error))
                                                                    }
                                                                }
                                                            }
                                                            catch
                                                            {
                                                                let failure = String(format: NSLocalizedString("%@ could not be downloaded.", comment: ""), appName)
                                                                finish(.failure(error), failure: failure)
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                            catch
                                            {
                                                finish(.failure(error), failure: NSLocalizedString("A valid signing certificate could not be created.", comment: ""))
                                            }
                                        }
                                    }
                                    catch
                                    {
                                        finish(.failure(error), failure: NSLocalizedString("Your device could not be registered with your development team.", comment: ""))
                                    }
                                }
                            }
                            catch
                            {
                                finish(.failure(error))
                            }
                        }
                    }
                    catch
                    {
                        finish(.failure(error), failure: NSLocalizedString("AltServer could not sign in with your Apple ID.", comment: ""))
                    }
                }
            }
            catch
            {
                finish(.failure(error))
            }
        }
    }
}

private extension ALTDeviceManager
{
    func managedApplicationSnapshot(on device: ALTDevice) async throws -> ManagedApplicationSnapshot
    {
        let applications: [[String: Any]] = try await managedApplicationValue { self.fetchInstalledApplicationDictionaries(on: device, completionHandler: $0) }
        let profiles: [ALTProvisioningProfile] = try await managedApplicationValue { self.fetchProvisioningProfiles(on: device, completionHandler: $0) }
        return ManagedApplicationSnapshot(applications: applications, profiles: profiles)
    }

    func managedApplication(_ dictionary: [String: Any], profile: ALTProvisioningProfile?) -> ManagedApplication
    {
        let identifier = dictionary[kCFBundleIdentifierKey as String] as? String ?? profile?.bundleIdentifier ?? ""
        let name = dictionary["CFBundleDisplayName"] as? String ?? dictionary[kCFBundleNameKey as String] as? String ?? identifier
        let version = dictionary["CFBundleShortVersionString"] as? String ?? dictionary[kCFBundleVersionKey as String] as? String ?? ""
        return ManagedApplication(name: name, bundleIdentifier: identifier, version: version,
                                  expirationDate: profile?.expirationDate, teamIdentifier: profile?.teamIdentifier ?? self.managedTeamIdentifierHint(dictionary))
    }

    func managedTeamIdentifierHint(_ dictionary: [String: Any]) -> String?
    {
        guard let identifier = dictionary[kCFBundleIdentifierKey as String] as? String,
              let original = dictionary[Bundle.Info.altBundleID] as? String, !original.isEmpty else { return nil }
        let candidate: String
        if identifier.hasPrefix(original + ".")
        {
            candidate = String(identifier.dropFirst(original.count + 1))
        }
        else if identifier.hasPrefix("com."), identifier.hasSuffix("." + original)
        {
            candidate = String(identifier.dropFirst(4).dropLast(original.count + 1))
        }
        else { return nil }
        // This is only a hint for recovering an expired app whose profile was
        // removed. Account membership and the generated App ID are still checked.
        guard candidate.utf8.count == 10, candidate.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }) else { return nil }
        return candidate
    }

    func managedAuthentication(appleID: String, password: String) async throws -> (ALTAccount, ALTAppleAPISession)
    {
        let anisetteData: ALTAnisetteData = try await managedApplicationResult { AnisetteDataManager.shared.requestAnisetteData($0) }
        return try await managedApplicationResult { self.authenticate(appleID: appleID, password: password, anisetteData: anisetteData, completionHandler: $0) }
    }

    func installManagedProfiles(_ profiles: [ALTProvisioningProfile], on device: ALTDevice) async throws
    {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.installProvisioningProfiles(Set(profiles), toDeviceWithUDID: device.identifier, activeProvisioningProfiles: nil) { success, error in
                if success { continuation.resume() }
                else { continuation.resume(throwing: error ?? ALTAppleAPIError.unknown()) }
            }
        }
    }

    func validateManagedRefresh(_ profile: ALTProvisioningProfile, replacing previous: ALTProvisioningProfile, device: ALTDevice) throws
    {
        guard profile.bundleIdentifier == previous.bundleIdentifier, profile.teamIdentifier == previous.teamIdentifier,
              profile.deviceIDs.contains(where: { $0.caseInsensitiveCompare(device.identifier) == .orderedSame }) else {
            throw managedApplicationError(NSLocalizedString("Apple returned a profile for a different app, team, or device. No device profiles were changed.", comment: ""))
        }
        guard profile.expirationDate > Date(), profile.expirationDate > previous.expirationDate else {
            throw managedApplicationError(NSLocalizedString("Apple did not extend this app's expiration date. No device profiles were changed; try again later.", comment: ""))
        }
        let previousCertificates = Set(previous.certificates.compactMap(\.data))
        let newCertificates = Set(profile.certificates.compactMap(\.data))
        guard !previousCertificates.isEmpty, previousCertificates.count == previous.certificates.count,
              previousCertificates.isSubset(of: newCertificates) else {
            throw managedApplicationError(NSLocalizedString("The app's existing signing certificate is missing from the renewed profile. Profile-only renewal cannot re-sign an app; update it with its original IPA instead.", comment: ""))
        }
        for key: ALTEntitlement in [.applicationIdentifier, .teamIdentifier, .appGroups, .keychainAccessGroups, .getTaskAllow]
        {
            guard let oldValue = previous.entitlements[key] else { continue }
            guard let newValue = profile.entitlements[key] else {
                throw managedApplicationError(NSLocalizedString("The renewed profile no longer permits this app's existing entitlements. Update it with its original IPA instead.", comment: ""))
            }
            if let oldStrings = oldValue as? [String], let newStrings = newValue as? [String]
            {
                guard Set(oldStrings).isSubset(of: Set(newStrings)) else {
                    throw managedApplicationError(NSLocalizedString("The app's existing app-group or keychain access is incompatible with the renewed profile. Update it with its original IPA instead.", comment: ""))
                }
            }
            else if !NSDictionary(dictionary: ["value": oldValue]).isEqual(to: ["value": newValue])
            {
                throw managedApplicationError(NSLocalizedString("The app's signing entitlements changed. Update it with its original IPA instead of performing profile-only renewal.", comment: ""))
            }
        }
    }

    func unpackManagedIPA(at url: URL, to directory: URL) throws -> ALTApplication
    {
        guard url.isFileURL, url.pathExtension.lowercased() == "ipa" else {
            throw managedApplicationError(NSLocalizedString("Choose a local .ipa file.", comment: ""))
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let bundleURL = try FileManager.default.unzipAppBundle(at: url, toDirectory: directory)
        guard let application = ALTApplication(fileURL: bundleURL) else { throw ALTError(.invalidApp) }
        return application
    }

    func managedSignedIdentifier(for application: ALTApplication, teamIdentifier: String) -> String
    {
        return application.isAltStoreApp ? "com.\(teamIdentifier).\(application.bundleIdentifier)" : application.bundleIdentifier + "." + teamIdentifier
    }

    func managedExistingCertificate(for team: ALTTeam, session: ALTAppleAPISession) async throws -> ALTCertificate
    {
        let certificates: [ALTCertificate] = try await managedApplicationValue { ALTAppleAPI.shared.fetchCertificates(for: team, session: session, completionHandler: $0) }
        let url = FileManager.default.certificatesDirectory.appendingPathComponent(team.identifier + ".p12")
        guard let data = try? Data(contentsOf: url) else {
            throw managedApplicationError(NSLocalizedString("This Mac has no cached signing certificate for the app's team. Install AltStore with this AltServer first, then retry the IPA update.", comment: ""))
        }
        for liveCertificate in certificates
        {
            if let certificate = ALTCertificate(p12Data: data, password: liveCertificate.machineIdentifier),
               certificate.serialNumber == liveCertificate.serialNumber, certificate.privateKey != nil
            {
                certificate.machineIdentifier = liveCertificate.machineIdentifier
                return certificate
            }
        }
        throw managedApplicationError(NSLocalizedString("This Mac's cached certificate is no longer valid for this team. Re-establish signing with the Install AltStore menu before retrying; no certificates were revoked by this operation.", comment: ""))
    }

    func preserveManagedApplicationUTIs(in application: ALTApplication, installedDictionary: [String: Any], signedIdentifier: String) throws
    {
        func update(_ bundleURL: URL, signedBundleIdentifier: String, previousDeclarations: [[String: Any]]) throws
        {
            guard let bundle = Bundle(url: bundleURL), var dictionary = bundle.completeInfoDictionary else { throw ALTError(.missingInfoPlist) }
            var declarations = dictionary[Bundle.Info.exportedUTIs] as? [[String: Any]] ?? []
            let knownIdentifiers = Set(declarations.compactMap { $0["UTTypeIdentifier"] as? String })
            declarations.append(contentsOf: previousDeclarations.filter {
                guard let identifier = $0["UTTypeIdentifier"] as? String else { return false }
                return !knownIdentifiers.contains(identifier)
            })
            let trackingIdentifier = "io.altstore.Installed." + signedBundleIdentifier
            if !declarations.contains(where: { ($0["UTTypeIdentifier"] as? String) == trackingIdentifier })
            {
                declarations.append(["UTTypeIdentifier": trackingIdentifier, "UTTypeDescription": "AltStore Installed App",
                                     "UTTypeConformsTo": [String](), "UTTypeTagSpecification": [String: String]()])
            }
            dictionary[Bundle.Info.exportedUTIs] = declarations
            try (dictionary as NSDictionary).write(to: bundle.infoPlistURL)
        }
        let previous = installedDictionary[Bundle.Info.exportedUTIs] as? [[String: Any]] ?? []
        try update(application.fileURL, signedBundleIdentifier: signedIdentifier, previousDeclarations: previous)
        for appExtension in application.appExtensions
        {
            let identifier = appExtension.bundleIdentifier.replacingOccurrences(of: application.bundleIdentifier, with: signedIdentifier)
            try update(appExtension.fileURL, signedBundleIdentifier: identifier, previousDeclarations: [])
        }
    }

    func managedIPADirectory(for identifier: String) -> URL
    {
        let key = SHA256.hash(data: Data(identifier.utf8)).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.altserverDirectory.appendingPathComponent("AppLibrary", isDirectory: true).appendingPathComponent(key, isDirectory: true)
    }

    func cacheManagedIPA(_ ipa: ManagedIPA, signedIdentifier: String) throws
    {
        let directory = self.managedIPADirectory(for: signedIdentifier)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.deletingLastPathComponent().path)
        let temporaryURL = directory.appendingPathComponent(UUID().uuidString + ".ipa")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try fileManager.copyItem(at: ipa.url, to: temporaryURL)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
        let destinationURL = directory.appendingPathComponent("Original.ipa")
        if fileManager.fileExists(atPath: destinationURL.path)
        {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        }
        else { try fileManager.moveItem(at: temporaryURL, to: destinationURL) }
        let metadata: [String: Any] = ["name": ipa.name, "version": ipa.version,
                                       "originalBundleIdentifier": ipa.bundleIdentifier,
                                       "installedBundleIdentifier": signedIdentifier, "cachedAt": Date()]
        let metadataURL = directory.appendingPathComponent("Metadata.plist")
        let data = try PropertyListSerialization.data(fromPropertyList: metadata, format: .binary, options: 0)
        try data.write(to: metadataURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataURL.path)
    }

    func prepare(_ device: ALTDevice, completionHandler: @escaping (Result<Void, Error>) -> Void)
    {        
        Task<Void, Never> {
            do
            {
                try await JITManager.shared.prepare(device)
                completionHandler(.success(()))
            }
            catch
            {
                completionHandler(.failure(error))
            }
        }
    }
    
    // Generates and encrypts a device pairing file to bundle into AltStore.app.
    func encryptedPairingData(for application: ALTApplication, device: ALTDevice, certificate: ALTCertificate, completionHandler: @escaping (Data?) -> Void)
    {
        // Only applies to AltStore installs with a machineIdentifier.
        guard application.isAltStoreApp, let machineIdentifier = certificate.machineIdentifier else
        {
            completionHandler(nil)
            return
        }

        let hostName = "AltServer on \(Host.current().localizedName ?? "Mac")"

        Task<Void, Never> {
            do
            {
                let pairingFile = try await DevicePairingManager.shared.generatePairingFile(forDeviceWithUDID: device.identifier, hostName: hostName)

                // Encrypt with a key derived from the certificate's machineIdentifier.
                let key = SymmetricKey(data: SHA256.hash(data: machineIdentifier.data(using: .utf8)!))
                let sealedBox = try AES.GCM.seal(pairingFile, using: key)

                guard let sealedData = sealedBox.combined else
                {
                    throw RemotePairingError.unknown(failureReason: NSLocalizedString("Failed to encrypt the generated pairing file.", comment: ""))
                }

                completionHandler(sealedData)
            }
            catch
            {
                Logger.main.notice("Skipped bundling pairing file: \(error.localizedDescription, privacy: .public)")
                completionHandler(nil)
            }
        }
    }
}

private extension ALTDeviceManager
{
    func downloadApp(from url: URL?, for device: ALTDevice, completionHandler: @escaping (Result<URL, Error>) -> Void)
    {
        if let url, url.isFileURL
        {
            return completionHandler(.success(url))
        }
        
        self.fetchAltStoreDownloadURL(for: device) { result in
            switch result
            {
            case .failure(let error): completionHandler(.failure(error))
            case .success(let url):
                let downloadTask = URLSession.shared.downloadTask(with: url) { (fileURL, response, error) in
                    do
                    {
                        if let response = response as? HTTPURLResponse
                        {
                            guard response.statusCode != 404 else { throw CocoaError(.fileNoSuchFile, userInfo: [NSURLErrorKey: url]) }
                        }
                        
                        let (fileURL, _) = try Result((fileURL, response), error).get()
                        completionHandler(.success(fileURL))
                        
                        do { try FileManager.default.removeItem(at: fileURL) }
                        catch { print("Failed to remove downloaded .ipa.", error) }
                    }
                    catch
                    {
                        completionHandler(.failure(error))
                    }
                }
                
                downloadTask.resume()
            }
        }
    }
    
    func fetchAltStoreDownloadURL(for device: ALTDevice, completion: @escaping (Result<URL, Error>) -> Void)
    {
        let dataTask = session.dataTask(with: altstoreSourceURL) { (data, response, error) in
            
            do
            {
                if let response = response as? HTTPURLResponse
                {
                    guard response.statusCode != 404 else { throw CocoaError(.fileNoSuchFile, userInfo: [NSURLErrorKey: altstoreSourceURL]) }
                }
                
                let (data, _) = try Result((data, response), error).get()
                let source = try Foundation.JSONDecoder().decode(Source.self, from: data)
                
                guard let altstore = source.apps.first(where: { $0.bundleIdentifier == altstoreBundleID }) else {
                    let debugDescription = String(format: NSLocalizedString("App with bundle ID '%@' does not exist in source JSON.", comment: ""), altstoreBundleID)
                    throw CocoaError(.coderValueNotFound, userInfo: [NSDebugDescriptionErrorKey: debugDescription])
                }
                guard let versions = altstore.versions else {
                    let debugDescription = String(format: NSLocalizedString("There is no 'versions' key for %@.", comment: ""), altstore.bundleIdentifier)
                    throw CocoaError(.coderReadCorrupt, userInfo: [NSDebugDescriptionErrorKey: debugDescription])
                }
                guard let latestVersion = versions.first else {
                    let debugDescription = String(format: NSLocalizedString("The 'versions' array is empty for %@.", comment: ""), altstore.bundleIdentifier)
                    throw CocoaError(.coderValueNotFound, userInfo: [NSDebugDescriptionErrorKey: debugDescription])
                }
                
                let osName = device.type.osName ?? "iOS"
                let minOSVersionString = latestVersion.minimumOSVersion?.stringValue ?? "12.2"
                
                guard let latestSupportedVersion = altstore.versions?.first(where: { appVersion in
                    if let minOSVersion = appVersion.minimumOSVersion, device.osVersion < minOSVersion
                    {
                        return false
                    }
                    
                    return true
                }) else { throw ALTServerError(.unsupportediOSVersion, userInfo: [ALTAppNameErrorKey: "AltStore",
                                                                      ALTOperatingSystemNameErrorKey: osName,
                                                                   ALTOperatingSystemVersionErrorKey: minOSVersionString]) }
                
                guard latestSupportedVersion.version != latestVersion.version else {
                    // The newest version is also the newest compatible version, so return its downloadURL.
                    return completion(.success(latestVersion.downloadURL))
                }
                
                DispatchQueue.main.async {
                    var message = String(format: NSLocalizedString("%@ is running %@ %@, but AltStore requires %@ %@ or later.", comment: ""), device.name, osName, device.osVersion.stringValue, osName, minOSVersionString)
                    message += "\n\n"
                    message += NSLocalizedString("Would you like to download the last version compatible with your device instead?", comment: "")
                    
                    let alert = NSAlert()
                    alert.messageText = String(format: NSLocalizedString("Unsupported %@ Version", comment: ""), osName)
                    alert.informativeText = message
                    
                    let buttonTitle = String(format: NSLocalizedString("Download %@ %@", comment: ""), altstore.name, latestSupportedVersion.version)
                    alert.addButton(withTitle: buttonTitle)
                    alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
                    
                    let index = alert.runModal()
                    if index == .alertFirstButtonReturn
                    {
                        completion(.success(latestSupportedVersion.downloadURL))
                    }
                    else
                    {
                        completion(.failure(OperationError.cancelled))
                    }
                }
                
            }
            catch let serverError as ALTServerError where serverError.code == .unsupportediOSVersion
            {
                // Don't add localized failure for unsupported iOS version errors.
                completion(.failure(serverError))
            }
            catch let error as NSError
            {
                completion(.failure(error.withLocalizedFailure("The download URL could not be determined.")))
            }
        }
        
        dataTask.resume()
    }
    
    func authenticate(appleID: String, password: String, anisetteData: ALTAnisetteData, completionHandler: @escaping (Result<(ALTAccount, ALTAppleAPISession), Error>) -> Void)
    {
        func handleVerificationCode(_ completionHandler: @escaping (String?) -> Void)
        {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = NSLocalizedString("Two-Factor Authentication Enabled", comment: "")
                alert.informativeText = NSLocalizedString("Please enter the 6-digit verification code that was sent to your Apple devices.", comment: "")
                
                let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
                textField.delegate = self
                textField.translatesAutoresizingMaskIntoConstraints = false
                textField.placeholderString = NSLocalizedString("123456", comment: "")
                alert.accessoryView = textField
                alert.window.initialFirstResponder = textField
                
                alert.addButton(withTitle: NSLocalizedString("Continue", comment: ""))
                alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
                
                self.securityCodeAlert = alert
                self.securityCodeTextField = textField
                self.validate()
                
                NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)
                
                let response = alert.runModal()
                if response == .alertFirstButtonReturn
                {
                    let code = textField.stringValue
                    completionHandler(code)
                }
                else
                {
                    completionHandler(nil)
                }
            }
        }
        
        ALTAppleAPI.shared.authenticate(appleID: appleID, password: password, anisetteData: anisetteData, verificationHandler: handleVerificationCode) { (account, session, error) in
            if let account = account, let session = session
            {
                completionHandler(.success((account, session)))
            }
            else
            {
                completionHandler(.failure(error ?? ALTAppleAPIError.unknown()))
            }
        }
    }
    
    func fetchTeam(for account: ALTAccount, session: ALTAppleAPISession, completionHandler: @escaping (Result<ALTTeam, Error>) -> Void)
    {
        ALTAppleAPI.shared.fetchTeams(for: account, session: session) { (teams, error) in
            do
            {
                let teams = try Result(teams, error).get()
                
                if let team = teams.first(where: { $0.type == .individual })
                {
                    return completionHandler(.success(team))
                }
                else if let team = teams.first(where: { $0.type == .free })
                {
                    return completionHandler(.success(team))
                }
                else if let team = teams.first
                {
                    return completionHandler(.success(team))
                }
                else
                {
                    throw OperationError(.noTeam)
                }
            }
            catch
            {
                completionHandler(.failure(error))
            }
        }
    }
    
    func fetchCertificate(for team: ALTTeam, session: ALTAppleAPISession, completionHandler: @escaping (Result<ALTCertificate, Error>) -> Void)
    {
        ALTAppleAPI.shared.fetchCertificates(for: team, session: session) { (certificates, error) in
            do
            {
                let certificates = try Result(certificates, error).get()
                
                let certificateFileURL = FileManager.default.certificatesDirectory.appendingPathComponent(team.identifier + ".p12")
                try FileManager.default.createDirectory(at: FileManager.default.certificatesDirectory, withIntermediateDirectories: true, attributes: nil)
                
                var isCancelled = false
                
                // Check if there is another AltStore certificate, which means AltStore has been installed with this Apple ID before.
                let altstoreCertificate = certificates.first { $0.machineName?.starts(with: "AltStore") == true }
                if let previousCertificate = altstoreCertificate
                {
                    if FileManager.default.fileExists(atPath: certificateFileURL.path),
                       let data = try? Data(contentsOf: certificateFileURL),
                       let certificate = ALTCertificate(p12Data: data, password: previousCertificate.machineIdentifier)
                    {
                        // Manually set machineIdentifier so we can encrypt + embed certificate if needed.
                        certificate.machineIdentifier = previousCertificate.machineIdentifier
                        return completionHandler(.success(certificate))
                    }
                                        
                    DispatchQueue.main.sync {
                        let alert = NSAlert()
                        alert.messageText = NSLocalizedString("Multiple AltServers Not Supported", comment: "")
                        alert.informativeText = NSLocalizedString("Please use the same AltServer you previously used with this Apple ID, or else apps installed with other AltServers will stop working.\n\nAre you sure you want to continue?", comment: "")
                        
                        alert.addButton(withTitle: NSLocalizedString("Continue", comment: ""))
                        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
                        
                        NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)
                        
                        let buttonIndex = alert.runModal()
                        if buttonIndex == NSApplication.ModalResponse.alertSecondButtonReturn
                        {
                            isCancelled = true
                        }
                    }
                    
                    guard !isCancelled else { return completionHandler(.failure(OperationError(.cancelled))) }
                }
                
                func addCertificate()
                {
                    ALTAppleAPI.shared.addCertificate(machineName: "AltStore", to: team, session: session) { (certificate, error) in
                        do
                        {
                            let certificate = try Result(certificate, error).get()
                            guard let privateKey = certificate.privateKey else { throw OperationError(.missingPrivateKey) }
                            
                            ALTAppleAPI.shared.fetchCertificates(for: team, session: session) { (certificates, error) in
                                do
                                {
                                    let certificates = try Result(certificates, error).get()
                                    
                                    guard let certificate = certificates.first(where: { $0.serialNumber == certificate.serialNumber }) else {
                                        throw OperationError(.missingCertificate)
                                    }
                                    
                                    certificate.privateKey = privateKey
                                    
                                    completionHandler(.success(certificate))
                                    
                                    if let machineIdentifier = certificate.machineIdentifier,
                                       let encryptedData = certificate.encryptedP12Data(withPassword: machineIdentifier)
                                    {
                                        // Cache certificate.
                                        do { try encryptedData.write(to: certificateFileURL, options: .atomic) }
                                        catch { print("Failed to cache certificate:", error) }
                                    }
                                }
                                catch
                                {
                                    completionHandler(.failure(error))
                                }
                            }
                        }
                        catch
                        {
                            completionHandler(.failure(error))
                        }
                    }
                }
                
                if let certificate = altstoreCertificate ?? certificates.first
                {
                    if team.type != .free
                    {
                        DispatchQueue.main.sync {
                            let alert = NSAlert()
                            alert.messageText = NSLocalizedString("Installing this app will revoke your iOS development certificate.", comment: "")
                            alert.informativeText = NSLocalizedString("""
    This will not affect apps you've submitted to the App Store, but may cause apps you've installed to your devices with Xcode to stop working until you reinstall them.

    To prevent this from happening, feel free to try again with another Apple ID.
    """, comment: "")
                            
                            alert.addButton(withTitle: NSLocalizedString("Continue", comment: ""))
                            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
                            
                            NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)
                            
                            let buttonIndex = alert.runModal()
                            if buttonIndex == NSApplication.ModalResponse.alertSecondButtonReturn
                            {
                                isCancelled = true
                            }
                        }
                        
                        guard !isCancelled else { return completionHandler(.failure(OperationError(.cancelled))) }
                    }
                    
                    ALTAppleAPI.shared.revoke(certificate, for: team, session: session) { (success, error) in
                        do
                        {
                            try Result(success, error).get()
                            addCertificate()
                        }
                        catch
                        {
                            completionHandler(.failure(error))
                        }
                    }
                }
                else
                {
                    addCertificate()
                }
            }
            catch
            {
                completionHandler(.failure(error))
            }
        }
    }
    
    func prepareAllProvisioningProfiles(for application: ALTApplication, device: ALTDevice, team: ALTTeam, session: ALTAppleAPISession,
                                        completion: @escaping (Result<[String: ALTProvisioningProfile], Error>) -> Void)
    {
        self.prepareProvisioningProfile(for: application, parentApp: nil, device: device, team: team, session: session) { (result) in
            do
            {
                let profile = try result.get()
                
                var profiles = [application.bundleIdentifier: profile]
                var error: Error?
                
                let dispatchGroup = DispatchGroup()
                
                for appExtension in application.appExtensions
                {
                    dispatchGroup.enter()
                    
                    self.prepareProvisioningProfile(for: appExtension, parentApp: application, device: device, team: team, session: session) { (result) in
                        switch result
                        {
                        case .failure(let e): error = e
                        case .success(let profile): profiles[appExtension.bundleIdentifier] = profile
                        }
                        
                        dispatchGroup.leave()
                    }
                }
                
                dispatchGroup.notify(queue: .global()) {
                    if let error = error
                    {
                        completion(.failure(error))
                    }
                    else
                    {
                        completion(.success(profiles))
                    }
                }
            }
            catch
            {
                completion(.failure(error))
            }
        }
    }
    
    func prepareProvisioningProfile(for application: ALTApplication, parentApp: ALTApplication?, device: ALTDevice, team: ALTTeam, session: ALTAppleAPISession, completionHandler: @escaping (Result<ALTProvisioningProfile, Error>) -> Void)
    {
        let parentBundleID = parentApp?.bundleIdentifier ?? application.bundleIdentifier
        let updatedParentBundleID: String
        
        if application.isAltStoreApp
        {
            // Use legacy bundle ID format for AltStore (and its extensions).
            updatedParentBundleID = "com.\(team.identifier).\(parentBundleID)"
        }
        else
        {
            updatedParentBundleID = parentBundleID + "." + team.identifier // Append just team identifier to make it harder to track.
        }
        
        let bundleID = application.bundleIdentifier.replacingOccurrences(of: parentBundleID, with: updatedParentBundleID)
        
        let preferredName: String
        
        if let parentApp = parentApp
        {
            preferredName = parentApp.name + " " + application.name
        }
        else
        {
            preferredName = application.name
        }
        
        self.registerAppID(name: preferredName, bundleID: bundleID, team: team, session: session) { (result) in
            do
            {
                let appID = try result.get()
                
                self.updateFeatures(for: appID, app: application, team: team, session: session) { (result) in
                    do
                    {
                        let appID = try result.get()
                        
                        self.updateAppGroups(for: appID, app: application, team: team, session: session) { (result) in
                            do
                            {
                                let appID = try result.get()
                                
                                self.fetchProvisioningProfile(for: appID, device: device, team: team, session: session) { (result) in
                                    completionHandler(result)
                                }
                            }
                            catch
                            {
                                completionHandler(.failure(error))
                            }
                        }
                    }
                    catch
                    {
                        completionHandler(.failure(error))
                    }
                }
            }
            catch
            {
                completionHandler(.failure(error))
            }
        }
    }
    
    func registerAppID(name appName: String, bundleID: String, team: ALTTeam, session: ALTAppleAPISession, completionHandler: @escaping (Result<ALTAppID, Error>) -> Void)
    {
        ALTAppleAPI.shared.fetchAppIDs(for: team, session: session) { (appIDs, error) in
            do
            {
                let appIDs = try Result(appIDs, error).get()
                
                if let appID = appIDs.first(where: { $0.bundleIdentifier == bundleID })
                {
                    completionHandler(.success(appID))
                }
                else
                {
                    ALTAppleAPI.shared.addAppID(withName: appName, bundleIdentifier: bundleID, team: team, session: session) { (appID, error) in
                        completionHandler(Result(appID, error))
                    }
                }
            }
            catch
            {
                completionHandler(.failure(error))
            }
        }
    }
    
    func updateFeatures(for appID: ALTAppID, app: ALTApplication, team: ALTTeam, session: ALTAppleAPISession, completionHandler: @escaping (Result<ALTAppID, Error>) -> Void)
    {
        let requiredFeatures = app.entitlements.compactMap { (entitlement, value) -> (ALTFeature, Any)? in
            guard let feature = ALTFeature(entitlement: entitlement) else { return nil }
            return (feature, value)
        }
        
        var features = requiredFeatures.reduce(into: [ALTFeature: Any]()) { $0[$1.0] = $1.1 }
        
        if let applicationGroups = app.entitlements[.appGroups] as? [String], !applicationGroups.isEmpty
        {
            // App uses app groups, so assign `true` to enable the feature.
            features[.appGroups] = true
        }
        else
        {
            // App has no app groups, so assign `false` to disable the feature.
            features[.appGroups] = false
        }
        
        var updateFeatures = false
        
        // Determine whether the required features are already enabled for the AppID.
        for (feature, value) in features
        {
            if let appIDValue = appID.features[feature] as AnyObject?, (value as AnyObject).isEqual(appIDValue)
            {
                // AppID already has this feature enabled and the values are the same.
                continue
            }
            else if appID.features[feature] == nil, let shouldEnableFeature = value as? Bool, !shouldEnableFeature
            {
                // AppID doesn't already have this feature enabled, but we want it disabled anyway.
                continue
            }
            else
            {
                // AppID either doesn't have this feature enabled or the value has changed,
                // so we need to update it to reflect new values.
                updateFeatures = true
                break
            }
        }
        
        if updateFeatures
        {
            let appID = appID.copy() as! ALTAppID
            appID.features = features
            
            ALTAppleAPI.shared.update(appID, team: team, session: session) { (appID, error) in
                completionHandler(Result(appID, error))
            }
        }
        else
        {
            completionHandler(.success(appID))
        }
    }
    
    func updateAppGroups(for appID: ALTAppID, app: ALTApplication, team: ALTTeam, session: ALTAppleAPISession, completionHandler: @escaping (Result<ALTAppID, Error>) -> Void)
    {
        guard let applicationGroups = app.entitlements[.appGroups] as? [String], !applicationGroups.isEmpty else {
            // Assigning an App ID to an empty app group array fails,
            // so just do nothing if there are no app groups.
            return completionHandler(.success(appID))
        }
        
        // Dispatch onto global queue to prevent appGroupsSemaphore deadlock.
        DispatchQueue.global().async {
            
            // Ensure we're not concurrently fetching and updating app groups,
            // which can lead to race conditions such as adding an app group twice.
            appGroupsSemaphore.wait()
            
            func finish(_ result: Result<ALTAppID, Error>)
            {
                appGroupsSemaphore.signal()
                completionHandler(result)
            }
            
            ALTAppleAPI.shared.fetchAppGroups(for: team, session: session) { (groups, error) in
                switch Result(groups, error)
                {
                case .failure(let error): finish(.failure(error))
                case .success(let fetchedGroups):
                    let dispatchGroup = DispatchGroup()
                    
                    var groups = [ALTAppGroup]()
                    var errors = [Error]()
                    
                    for groupIdentifier in applicationGroups
                    {
                        let adjustedGroupIdentifier = groupIdentifier + "." + team.identifier
                        
                        if let group = fetchedGroups.first(where: { $0.groupIdentifier == adjustedGroupIdentifier })
                        {
                            groups.append(group)
                        }
                        else
                        {
                            dispatchGroup.enter()
                            
                            // Not all characters are allowed in group names, so we replace periods with spaces (like Apple does).
                            let name = "AltStore " + groupIdentifier.replacingOccurrences(of: ".", with: " ")
                            
                            ALTAppleAPI.shared.addAppGroup(withName: name, groupIdentifier: adjustedGroupIdentifier, team: team, session: session) { (group, error) in
                                switch Result(group, error)
                                {
                                case .success(let group): groups.append(group)
                                case .failure(let error): errors.append(error)
                                }
                                
                                dispatchGroup.leave()
                            }
                        }
                    }
                    
                    dispatchGroup.notify(queue: .global()) {
                        if let error = errors.first
                        {
                            finish(.failure(error))
                        }
                        else
                        {
                            ALTAppleAPI.shared.assign(appID, to: Array(groups), team: team, session: session) { (success, error) in
                                let result = Result(success, error)
                                finish(result.map { _ in appID })
                            }
                        }
                    }
                }
            }
        }
    }
    
    func register(_ device: ALTDevice, team: ALTTeam, session: ALTAppleAPISession, completionHandler: @escaping (Result<ALTDevice, Error>) -> Void)
    {
        ALTAppleAPI.shared.fetchDevices(for: team, types: device.type, session: session) { (devices, error) in
            do
            {
                let devices = try Result(devices, error).get()
                
                if let device = devices.first(where: { $0.identifier == device.identifier })
                {
                    completionHandler(.success(device))
                }
                else
                {
                    ALTAppleAPI.shared.registerDevice(name: device.name, identifier: device.identifier, type: device.type, team: team, session: session) { (device, error) in
                        completionHandler(Result(device, error))
                    }
                }
            }
            catch
            {
                completionHandler(.failure(error))
            }
        }
    }
    
    func fetchProvisioningProfile(for appID: ALTAppID, device: ALTDevice, team: ALTTeam, session: ALTAppleAPISession, completionHandler: @escaping (Result<ALTProvisioningProfile, Error>) -> Void)
    {
        ALTAppleAPI.shared.fetchProvisioningProfile(for: appID, deviceType: device.type, team: team, session: session) { (profile, error) in
            completionHandler(Result(profile, error))
        }
    }
    
    func install(_ application: ALTApplication, to device: ALTDevice, team: ALTTeam, certificate: ALTCertificate, profiles: [String: ALTProvisioningProfile], pairingFile: Data?, completionHandler: @escaping (Result<Void, Error>) -> Void)
    {
        func prepare(_ bundle: Bundle, additionalInfoDictionaryValues: [String: Any] = [:]) throws
        {
            guard let identifier = bundle.bundleIdentifier else { throw ALTError(.missingAppBundle) }
            guard let profile = profiles[identifier] else { throw ALTError(.missingProvisioningProfile) }
            guard var infoDictionary = bundle.completeInfoDictionary else { throw ALTError(.missingInfoPlist) }
            
            infoDictionary[kCFBundleIdentifierKey as String] = profile.bundleIdentifier
            infoDictionary[Bundle.Info.altBundleID] = identifier
            
            if (infoDictionary.keys.contains(Bundle.Info.deviceID)) {
                infoDictionary[Bundle.Info.deviceID] = device.identifier
            }

            for (key, value) in additionalInfoDictionaryValues
            {
                infoDictionary[key] = value
            }
            
            if let appGroups = profile.entitlements[.appGroups] as? [String]
            {
                infoDictionary[Bundle.Info.appGroups] = appGroups
            }
            
            if let backgroundTaskIDs = infoDictionary[Bundle.Info.backgroundTaskIDs] as? [String]
            {
                // Background task IDs must be prefixed with the app's bundle ID, so we
                // replace all occurances of original bundle ID with resigned bundle ID.
                
                let updatedBackgroundTaskIDs = backgroundTaskIDs.map { $0.replacingOccurrences(of: identifier, with: profile.bundleIdentifier) }
                infoDictionary[Bundle.Info.backgroundTaskIDs] = updatedBackgroundTaskIDs
            }
            
            try (infoDictionary as NSDictionary).write(to: bundle.infoPlistURL)
        }
        
        DispatchQueue.global().async {
            do
            {
                guard let appBundle = Bundle(url: application.fileURL) else { throw ALTError(.missingAppBundle) }
                guard let infoDictionary = appBundle.completeInfoDictionary else { throw ALTError(.missingInfoPlist) }
                
                let openAppURL = URL(string: "altstore-" + application.bundleIdentifier + "://")!
                
                var allURLSchemes = infoDictionary[Bundle.Info.urlTypes] as? [[String: Any]] ?? []
                
                // Embed open URL so AltBackup can return to AltStore.
                let altstoreURLScheme = ["CFBundleTypeRole": "Editor",
                                         "CFBundleURLName": application.bundleIdentifier,
                                         "CFBundleURLSchemes": [openAppURL.scheme!]] as [String : Any]
                allURLSchemes.append(altstoreURLScheme)
                
                var additionalValues: [String: Any] = [Bundle.Info.urlTypes: allURLSchemes]
                
                if application.isAltStoreApp
                {
                    additionalValues[Bundle.Info.deviceID] = device.identifier
                    additionalValues[Bundle.Info.serverID] = UserDefaults.standard.serverID
                    
                    if
                        let machineIdentifier = certificate.machineIdentifier,
                        let encryptedData = certificate.encryptedP12Data(withPassword: machineIdentifier)
                    {
                        additionalValues[Bundle.Info.certificateID] = certificate.serialNumber
                        
                        let certificateURL = application.fileURL.appendingPathComponent("ALTCertificate.p12")
                        try encryptedData.write(to: certificateURL, options: .atomic)
                    }

                    if let pairingFile
                    {
                        let pairingFileURL = application.fileURL.appendingPathComponent("ALTPairingFile.dat")
                        try pairingFile.write(to: pairingFileURL, options: .atomic)
                    }
                }
                else if infoDictionary.keys.contains(Bundle.Info.deviceID)
                {
                    // There is an ALTDeviceID entry, so assume the app is using AltKit and replace it with the device's UDID.
                    additionalValues[Bundle.Info.deviceID] = device.identifier
                    additionalValues[Bundle.Info.serverID] = UserDefaults.standard.serverID
                }
                
                try prepare(appBundle, additionalInfoDictionaryValues: additionalValues)
                
                for appExtension in application.appExtensions
                {
                    guard let bundle = Bundle(url: appExtension.fileURL) else { throw ALTError(.missingAppBundle) }
                    try prepare(bundle)
                }
                
                let resigner = ALTSigner(team: team, certificate: certificate)
                resigner.signApp(at: application.fileURL, provisioningProfiles: Array(profiles.values)) { (success, error) in
                    do
                    {
                        try Result(success, error).get()
                        
                        let activeProfiles: Set<String>? = (team.type == .free && application.isAltStoreApp) ? Set(profiles.values.map(\.bundleIdentifier)) : nil
                        ALTDeviceManager.shared.installApp(at: application.fileURL, toDeviceWithUDID: device.identifier, activeProvisioningProfiles: activeProfiles) { (success, error) in
                            completionHandler(Result(success, error))
                        }
                    }
                    catch
                    {
                        print("Failed to install app", error)
                        completionHandler(.failure(error))
                    }
                }
            }
            catch
            {
                print("Failed to install AltStore", error)
                completionHandler(.failure(error))
            }
        }
    }
    
    func showInstallationAlert(appName: String, deviceName: String)
    {
        let content = UNMutableNotificationContent()
        content.title = String(format: NSLocalizedString("Installing %@ to %@...", comment: ""), appName, deviceName)
        content.body = NSLocalizedString("This may take a few seconds.", comment: "")
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

private var securityCodeAlertKey = 0
private var securityCodeTextFieldKey = 0

extension ALTDeviceManager: NSTextFieldDelegate
{
    var securityCodeAlert: NSAlert? {
        get { return objc_getAssociatedObject(self, &securityCodeAlertKey) as? NSAlert }
        set { objc_setAssociatedObject(self, &securityCodeAlertKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
    
    var securityCodeTextField: NSTextField? {
        get { return objc_getAssociatedObject(self, &securityCodeTextFieldKey) as? NSTextField }
        set { objc_setAssociatedObject(self, &securityCodeTextFieldKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
    
    public func controlTextDidChange(_ obj: Notification)
    {
        self.validate()
    }
    
    public func controlTextDidEndEditing(_ obj: Notification)
    {
        self.validate()
    }
    
    private func validate()
    {
        guard let code = self.securityCodeTextField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        
        if code.count == 6
        {
            self.securityCodeAlert?.buttons.first?.isEnabled = true
        }
        else
        {
            self.securityCodeAlert?.buttons.first?.isEnabled = false
        }
        
        self.securityCodeAlert?.layout()
    }
}
