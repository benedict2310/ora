//
//  ContactsSearchTool.swift
//  Ora
//
//  Search contacts by name
//

import Foundation
import Contacts

struct ContactsSearchTool: Tool {
    let name = "contacts.search"
    let kind: ToolKind = .read
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Search contacts by name",
            parameters: [
                "query": ParameterSchema(type: "string", description: "Name to search for", format: nil),
                "limit": ParameterSchema(type: "number", description: "Maximum results (default 10)", format: nil)
            ],
            requiredParameters: ["query"],
            requiresConfirmation: false
        )
    }
    
    func validate(args: [String: JSONValue]) throws {
        guard let query = args["query"]?.stringValue, !query.isEmpty else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: query")
        }
    }
    
    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        // Check permissions
        let status = await PermissionsManager.shared.request(.contacts)
        guard status == .authorized else {
            throw ContactsToolError.permissionDenied
        }
        
        let store = CNContactStore()
        
        guard let query = args["query"]?.stringValue else {
            throw ContactsToolError.invalidArgument("Query required")
        }
        
        let limit = Int(args["limit"]?.numberValue ?? 10)
        
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as NSString,
            CNContactFamilyNameKey as NSString,
            CNContactEmailAddressesKey as NSString,
            CNContactPhoneNumbersKey as NSString,
            CNContactOrganizationNameKey as NSString
        ]
        
        let predicate = CNContact.predicateForContacts(matchingName: query)
        
        // Execute synchronously (CNContactStore is thread-safe)
        let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)
        
        let contactData: [JSONValue] = contacts.prefix(limit).map { contact in
            let name = [contact.givenName, contact.familyName]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            
            let emails = contact.emailAddresses.map { $0.value as String }
            let phones = contact.phoneNumbers.map { $0.value.stringValue }
            
            return .object([
                "name": .string(name),
                "organization": .string(contact.organizationName),
                "emails": .array(emails.map { .string($0) }),
                "phones": .array(phones.map { .string($0) })
            ])
        }
        
        let summary: String
        if contacts.isEmpty {
            summary = "No contacts found matching '\(query)'."
        } else if contacts.count == 1 {
            let contact = contacts[0]
            let name = [contact.givenName, contact.familyName].joined(separator: " ")
            
            // Try to find a phone or email for the summary
            if let phone = contact.phoneNumbers.first?.value.stringValue {
                summary = "\(name)'s phone number is \(phone)."
            } else if let email = contact.emailAddresses.first?.value as String? {
                summary = "\(name)'s email is \(email)."
            } else {
                summary = "Found \(name)."
            }
        } else {
            summary = "Found \(contacts.count) contacts matching '\(query)'."
        }
        
        return .success(.array(contactData), summary: summary)
    }
}
