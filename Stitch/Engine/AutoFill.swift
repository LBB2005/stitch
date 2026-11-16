import CoreGraphics
import Foundation

/// Matches a form field's name (or its tooltip) to an item of your profile: "First Name", "fname",
/// "Applicant Email", "Phone #", "DOB", "USC ID", "Zip"… Fields about someone else (emergency contact,
/// parent, employer, reference) are never matched.
enum AutoFill {
    static func match(_ fieldName: String) -> ProfileItem? {
        let words = tokens(fieldName)
        guard !words.isEmpty else { return nil }
        let joined = words.joined()
        let set = Set(words)
        func has(_ w: String) -> Bool { set.contains(w) }
        func hasAny(_ ws: [String]) -> Bool { ws.contains(where: has) }
        func contains(_ s: String) -> Bool { joined.contains(s) }

        let someoneElse = ["emergency", "parent", "guardian", "mother", "father", "spouse", "employer", "company",
                           "reference", "supervisor", "contact2", "beneficiary", "physician", "doctor", "insurance",
                           "witness", "landlord", "manager", "agent", "recipient"]
        if someoneElse.contains(where: { joined.contains($0) }) { return nil }

        if contains("email") || (has("e") && has("mail")) { return .email }
        if hasAny(["phone", "tel", "telephone", "mobile", "cell", "cellphone"]) || contains("phone") { return .phone }
        if has("dob") || contains("birth") { return .dateOfBirth }
        if contains("studentid") || contains("studentnumber") || contains("studentno") || joined == "uscid"
            || contains("uscid") || (has("student") && hasAny(["id", "number", "no"])) || joined == "sid" {
            return .studentID
        }

        if hasAny(["zip", "zipcode", "postcode", "postal"]) || contains("zipcode") || contains("postalcode") { return .zip }
        if has("city") || has("town") { return .city }
        if (has("state") || has("province")) && !contains("statement") { return .state }
        if has("country") { return .country }
        if contains("address2") || contains("addressline2") || hasAny(["apt", "apartment", "suite", "unit"]) { return .street2 }
        if contains("street") || contains("address1") || contains("addressline1") || has("addr") || has("address") {
            return .street
        }

        if contains("firstname") || contains("givenname") || has("fname") || joined == "first" || (has("first") && has("name")) {
            return .firstName
        }
        if contains("lastname") || contains("surname") || contains("familyname") || has("lname") || joined == "last"
            || (has("last") && has("name")) {
            return .lastName
        }
        let notAPersonName = ["school", "college", "university", "course", "class", "file", "user", "program",
                              "business", "organization", "org", "event", "project", "product", "middle", "nick"]
        if has("name") || contains("fullname") || contains("yourname") || contains("printname") {
            if notAPersonName.contains(where: { joined.contains($0) }) { return nil }
            return .fullName
        }
        return nil
    }

    /// "Applicant_Email[0]" → ["applicant", "email"]; "fName" → ["f", "name"]… camel case is split too,
    /// but common short forms ("fname", "dob") stay whole.
    static func tokens(_ s: String) -> [String] {
        var spaced = ""
        var prev: Character?
        for ch in s {
            if let p = prev, p.isLowercase, ch.isUppercase { spaced.append(" ") }
            spaced.append(ch)
            prev = ch
        }
        let parts = spaced.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        // Drop array indices and form-generator noise ("topmostSubform", "[0]", "txt").
        let noise: Set<String> = ["0", "1", "txt", "text", "field", "fld", "tf", "topmostsubform", "page1", "form1", "subform"]
        var cleaned = parts.filter { !noise.contains($0) }
        // Rejoin "f name" / "l name" that camel-case splitting broke apart.
        if cleaned.count >= 2, cleaned[0].count == 1, cleaned[1] == "name" {
            cleaned = [cleaned[0] + "name"] + cleaned.dropFirst(2)
        }
        return cleaned
    }
}

extension AutoFill {
    /// A text form field, as the My Info panel and Fill My Info see it.
    struct Field: Equatable, Sendable {
        var name: String
        var toolTip: String?
        var value: String
        var page: Int
        /// PDF user space of the page.
        var rect: CGRect
    }

    /// A field that one of your details fits.
    struct FieldMatch: Equatable, Sendable, Identifiable {
        var field: Field
        var item: ProfileItem
        var value: String
        var alreadyFilled: Bool
        var id: String { "\(field.page)-\(field.name)-\(Int(field.rect.minX))-\(Int(field.rect.minY))" }
    }

    /// What Fill My Info will do: each field one of your details matches (and that detail isn't empty),
    /// and whether the field already has something in it (those are left alone).
    static func plan(fields: [Field], profile: Profile, address: Profile.Address?) -> [FieldMatch] {
        fields.compactMap { field in
            guard let item = match(field.name) ?? field.toolTip.flatMap(match) else { return nil }
            let value = profile.value(item, address: address)
            guard !value.isEmpty else { return nil }
            let filled = !field.value.trimmingCharacters(in: .whitespaces).isEmpty
            return FieldMatch(field: field, item: item, value: value, alreadyFilled: filled)
        }
    }
}
