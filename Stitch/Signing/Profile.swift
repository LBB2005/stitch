import Foundation

/// Your details for filling forms. Stored only on this Mac, in the login Keychain.
struct Profile: Codable, Equatable, Sendable {
    struct Address: Codable, Equatable, Identifiable, Sendable {
        var id = UUID()
        var label = "Home"
        var street = ""
        var street2 = ""
        var city = ""
        var state = ""
        var zip = ""
        var country = ""

        var oneLine: String {
            [street, street2, city, [state, zip].filter { !$0.isEmpty }.joined(separator: " "), country]
                .filter { !$0.isEmpty }.joined(separator: ", ")
        }

        var isEmpty: Bool { [street, street2, city, state, zip, country].allSatisfy(\.isEmpty) }
    }

    var firstName = ""
    var lastName = ""
    var email = ""
    var phone = ""
    var studentID = ""
    var dateOfBirth = ""
    var addresses: [Address] = []

    var fullName: String { [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ") }

    var isEmpty: Bool {
        [firstName, lastName, email, phone, studentID, dateOfBirth].allSatisfy(\.isEmpty)
            && addresses.allSatisfy(\.isEmpty)
    }

    /// The text for a profile item (address items from `address`, or the first address).
    func value(_ item: ProfileItem, address: Address? = nil) -> String {
        let a = address ?? addresses.first ?? Address()
        switch item {
        case .fullName: return fullName
        case .firstName: return firstName
        case .lastName: return lastName
        case .email: return email
        case .phone: return phone
        case .studentID: return studentID
        case .dateOfBirth: return dateOfBirth
        case .street: return a.street
        case .street2: return a.street2
        case .city: return a.city
        case .state: return a.state
        case .zip: return a.zip
        case .country: return a.country
        case .fullAddress: return a.oneLine
        }
    }
}

enum ProfileItem: String, CaseIterable, Sendable {
    case fullName, firstName, lastName, email, phone, studentID, dateOfBirth
    case street, street2, city, state, zip, country, fullAddress

    var label: String {
        switch self {
        case .fullName: "Full Name"
        case .firstName: "First Name"
        case .lastName: "Last Name"
        case .email: "Email"
        case .phone: "Phone"
        case .studentID: "Student ID"
        case .dateOfBirth: "Date of Birth"
        case .street: "Street"
        case .street2: "Apt / Suite"
        case .city: "City"
        case .state: "State"
        case .zip: "ZIP"
        case .country: "Country"
        case .fullAddress: "Full Address"
        }
    }

    var isAddress: Bool {
        switch self {
        case .street, .street2, .city, .state, .zip, .country, .fullAddress: true
        default: false
        }
    }
}

// Fields missing from older saves (or added later) fall back to their defaults instead of failing the
// whole decode, so a Stitch update never makes your saved details unreadable.
extension Profile {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        firstName = try c.lenient(.firstName, "")
        lastName = try c.lenient(.lastName, "")
        email = try c.lenient(.email, "")
        phone = try c.lenient(.phone, "")
        studentID = try c.lenient(.studentID, "")
        dateOfBirth = try c.lenient(.dateOfBirth, "")
        addresses = try c.lenient(.addresses, [])
    }
}

extension Profile.Address {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.lenient(.id, UUID())
        label = try c.lenient(.label, "Home")
        street = try c.lenient(.street, "")
        street2 = try c.lenient(.street2, "")
        city = try c.lenient(.city, "")
        state = try c.lenient(.state, "")
        zip = try c.lenient(.zip, "")
        country = try c.lenient(.country, "")
    }
}

extension KeyedDecodingContainer {
    /// The value for `key`, or `fallback` when it's absent or null. A present value of the wrong type still throws.
    func lenient<T: Decodable>(_ key: Key, _ fallback: @autoclosure () -> T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback()
    }
}
