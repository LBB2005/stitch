import XCTest
@testable import Stitch

/// Saved data: older or newer formats still load, unreadable items are never written over, delete-all
/// clears everything, and each running copy of Stitch keeps its own scratch folder.
@MainActor
final class StorageTests: XCTestCase {
    private let keychain = KeychainStore(service: "com.liamblackshawbrown.Stitch.storagetests")

    override func tearDown() {
        for account in SignatureStore.accounts {
            keychain.delete(account: account)
            keychain.delete(account: KeychainStore.backupAccount(account))
        }
        super.tearDown()
    }

    func testProfileFromAnOlderFormatKeepsWhatItHas() throws {
        let json = #"{"firstName":"Liam","email":"a@b.c","addresses":[{"city":"Los Angeles"}]}"#
        let profile = try JSONDecoder().decode(Profile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.firstName, "Liam")
        XCTAssertEqual(profile.email, "a@b.c")
        XCTAssertEqual(profile.lastName, "")
        XCTAssertEqual(profile.addresses.first?.city, "Los Angeles")
        XCTAssertEqual(profile.addresses.first?.label, "Home")
    }

    func testProfileIgnoresFieldsItDoesntKnow() throws {
        let json = #"{"firstName":"Liam","favouriteColour":"blue"}"#
        XCTAssertEqual(try JSONDecoder().decode(Profile.self, from: Data(json.utf8)).firstName, "Liam")
    }

    func testProfileRoundTrips() throws {
        var profile = Profile(firstName: "A", lastName: "B", email: "c", phone: "d", studentID: "e", dateOfBirth: "f")
        profile.addresses = [Profile.Address(label: "School", street: "1 Main", city: "LA", zip: "90007")]
        XCTAssertEqual(try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(profile)), profile)
    }

    func testSignatureFromAnOlderFormat() throws {
        let typed = try JSONDecoder().decode(Signature.self, from: Data(#"{"text":"LBB","fontName":"SnellRoundhand","aspect":3}"#.utf8))
        XCTAssertEqual(typed.style, .typed)
        XCTAssertEqual(typed.text, "LBB")
        let drawn = try JSONDecoder().decode(Signature.self, from: Data(#"{"strokes":[[[0,0],[1,1]]],"aspect":2}"#.utf8))
        XCTAssertEqual(drawn.style, .drawn)
        XCTAssertEqual(drawn.inkWidth, 0.03)
    }

    func testReadTellsMissingFromDamaged() throws {
        guard case .missing = keychain.read(Profile.self, account: "profile") else { return XCTFail("expected missing") }
        try keychain.saveRaw(Data("not json".utf8), account: "profile")
        guard case .damaged = keychain.read(Profile.self, account: "profile") else { return XCTFail("expected damaged") }
        // The unreadable bytes are kept aside before anything can replace them.
        XCTAssertEqual(keychain.rawData(account: KeychainStore.backupAccount("profile")), Data("not json".utf8))
    }

    func testDamagedDetailsAreBackedUpThenCanBeReplaced() throws {
        try keychain.saveRaw(Data("[1,2".utf8), account: "profile")
        let store = SignatureStore(keychain: keychain)
        XCTAssertNotNil(store.problem)
        XCTAssertEqual(store.profile, Profile())
        try store.setProfile(Profile(firstName: "New"))
        XCTAssertEqual(keychain.load(Profile.self, account: "profile")?.firstName, "New")
        XCTAssertEqual(keychain.rawData(account: KeychainStore.backupAccount("profile")), Data("[1,2".utf8))
    }

    func testStoreLoadsAndSavesEachItemSeparately() throws {
        let store = SignatureStore(keychain: keychain)
        XCTAssertNil(store.problem)
        let sig = try XCTUnwrap(Signature.typed("Liam", fontName: "SnellRoundhand"))
        let ini = try XCTUnwrap(Signature.typed("LB", fontName: "SnellRoundhand"))
        try store.setSignature(sig, initials: false)
        try store.setSignature(ini, initials: true)
        try store.setProfile(Profile(firstName: "Liam"))

        let again = SignatureStore(keychain: keychain)
        XCTAssertEqual(again.signature, sig)
        XCTAssertEqual(again.initials, ini)
        XCTAssertEqual(again.profile.firstName, "Liam")

        try again.setSignature(nil, initials: true)
        XCTAssertNil(SignatureStore(keychain: keychain).initials)
        XCTAssertEqual(SignatureStore(keychain: keychain).signature, sig)
    }

    func testDeleteAllRemovesEverythingIncludingBackups() throws {
        let store = SignatureStore(keychain: keychain)
        try store.setSignature(try XCTUnwrap(Signature.typed("Liam", fontName: "SnellRoundhand")), initials: false)
        try store.setProfile(Profile(firstName: "Liam"))
        try keychain.saveRaw(Data("old".utf8), account: KeychainStore.backupAccount("initials"))

        store.deleteAll()
        XCTAssertNil(store.signature)
        XCTAssertEqual(store.profile, Profile())
        for account in SignatureStore.accounts {
            XCTAssertNil(keychain.rawData(account: account), account)
            XCTAssertNil(keychain.rawData(account: KeychainStore.backupAccount(account)), account)
        }
    }

    func testScratchFoldersArePerRunningCopy() throws {
        XCTAssertEqual(Workspace.root.lastPathComponent, String(ProcessInfo.processInfo.processIdentifier))
        XCTAssertTrue(Workspace.root.path.hasPrefix(FileManager.default.temporaryDirectory.path))

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("StitchLeftovers-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let names = ["111", "222", "old-uuid-folder", Workspace.root.lastPathComponent]
        for name in names {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        Workspace.clearLeftovers(in: folder) { $0 == 111 }
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        XCTAssertEqual(left, ["111", Workspace.root.lastPathComponent])
    }

    func testThisProcessCountsAsRunning() {
        XCTAssertTrue(Workspace.processIsRunning(ProcessInfo.processInfo.processIdentifier))
    }
}
