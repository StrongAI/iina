//
//  KeychainAccess.swift
//  iina
//
//  Created by Collider LI on 25/8/2018.
//  Copyright © 2018 lhc. All rights reserved.
//

import Foundation

class KeychainAccess {

  enum KeychainError: Error {
    case noResult
    case unhandledError(message: String)
    case unexpectedData
  }

  struct ServiceName: RawRepresentable, Equatable {
    typealias RawValue = String
    var rawValue: String

    init(rawValue: String) {
      self.rawValue = rawValue
    }

    init(_ rawValue: String) {
      self.init(rawValue: rawValue)
    }

    static let openSubAccount = ServiceName(rawValue: "IINA OpenSubtitles Account")
    static let httpAuth = ServiceName(rawValue: "IINA Saved HTTP Password")
  }

  /// A request of the Keychain.
  enum Request: Equatable {
    case read(username: String?, service: ServiceName, server: String?, port: Int?)
    case write(username: String, password: String, service: ServiceName, server: String?, port: Int?)

    /// Ask the Keychain, waiting for securityd to answer.
    /// - Returns: The account and password read, or `nil` for a write.
    func make() throws -> (username: String, password: String)? {
      switch self {
      case .read(let username, let service, let server, let port):
        return try readItem(username: username, forService: service, server: server, port: port)
      case .write(let username, let password, let service, let server, let port):
        try writeItem(username: username, password: password, forService: service, server: server, port: port)
        return nil
      }
    }
  }

  /// The serial queue the Keychain is asked on by the sites that must not wait for it on the main thread, since securityd answers
  /// each request and can first show a Keychain access prompt.
  static let queue = DispatchQueue(label: "IINAKeychain", qos: .userInitiated)

  /// Makes each Keychain request. It exists so that tests can answer the requests in its place, checking what is asked without
  /// reading or writing the user's Keychain.
  static var makeRequest: (Request) throws -> (username: String, password: String)? = { try $0.make() }

  static func write(username: String, password: String, forService serviceName: ServiceName, server: String? = nil, port: Int? = nil) throws {
    _ = try makeRequest(.write(username: username, password: password, service: serviceName, server: server, port: port))
  }

  static func read(username: String?, forService serviceName: ServiceName, server: String? = nil, port: Int? = nil) throws -> (username: String, password: String) {
    guard let item = try makeRequest(.read(username: username, service: serviceName, server: server, port: port)) else {
      throw KeychainError.unexpectedData
    }
    return item
  }

  private static func writeItem(username: String, password: String, forService serviceName: ServiceName, server: String?, port: Int?) throws {
    let status: OSStatus

    if let _ = try? read(username: username, forService: serviceName, server: nil, port: nil) {

      // if password exists, try to update the password
      var query: [String: Any] = [kSecAttrService as String: serviceName.rawValue]
      if let server { query[kSecAttrServer as String] = server }
      if let port { query[kSecAttrPort as String] = port }
      query[kSecClass as String] = server == nil && port == nil ? kSecClassGenericPassword : kSecClassInternetPassword

      // create attributes for updating
      let passwordData = password.data(using: String.Encoding.utf8)!
      let attributes: [String: Any] = [kSecAttrAccount as String: username,
                                       kSecValueData as String: passwordData]
      // update
      status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

    } else {

      // try to write the password
      var query: [String: Any] = [kSecAttrService as String: serviceName.rawValue,
                                  kSecAttrLabel as String: serviceName.rawValue,
                                  kSecAttrAccount as String: username,
                                  kSecValueData as String: password]
      if let server { query[kSecAttrServer as String] = server }
      if let port { query[kSecAttrPort as String] = port }
      query[kSecClass as String] = server == nil && port == nil ? kSecClassGenericPassword : kSecClassInternetPassword

      status = SecItemAdd(query as CFDictionary, nil)
    }

    // check result
    guard status != errSecItemNotFound else { throw KeychainError.noResult }
    guard status == errSecSuccess else {
      let message = (SecCopyErrorMessageString(status, nil) as String?) ?? ""
      throw KeychainError.unhandledError(message: message)
    }
  }

  private static func readItem(username: String?, forService serviceName: ServiceName, server: String?, port: Int?) throws -> (username: String, password: String) {
    var query: [String: Any] = [kSecAttrService as String: serviceName.rawValue,
                                kSecMatchLimit as String: kSecMatchLimitOne,
                                kSecReturnAttributes as String: true,
                                kSecReturnData as String: true]
    if let username { query[kSecAttrAccount as String] = username }
    if let server { query[kSecAttrServer as String] = server }
    if let port { query[kSecAttrPort as String] = port }

    query[kSecClass as String] = server == nil && port == nil ? kSecClassGenericPassword : kSecClassInternetPassword

    // initiate the search
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status != errSecItemNotFound else { throw KeychainError.noResult }
    guard status == errSecSuccess else {
      let message = (SecCopyErrorMessageString(status, nil) as String?) ?? ""
      throw KeychainError.unhandledError(message: message)
    }

    // get data
    guard let existingItem = item as? [String : Any],
      let passwordData = existingItem[kSecValueData as String] as? Data,
      let password = String(data: passwordData, encoding: String.Encoding.utf8),
      let account = existingItem[kSecAttrAccount as String] as? String
      else {
        throw KeychainError.unexpectedData
    }
    return (account, password)
  }

}

