//
//  JavascriptAPIPreferences.swift
//  iina
//
//  Created by Collider LI on 26/3/2019.
//  Copyright © 2019 lhc. All rights reserved.
//

import Foundation
import JavaScriptCore

@objc protocol JavascriptAPIPreferencesExportable: JSExport {
  func get(_ key: String) -> JSValue
  func set(_ key: String, _ value: Any) -> JSValue
  func sync()
}

class JavascriptAPIPreferences: JavascriptAPI, JavascriptAPIPreferencesExportable {
  @objc func get(_ key: String) -> JSValue {
    let plugin = pluginInstance.plugin!
    let subsystem = pluginInstance.subsystem
    return createPromise { resolve, _ in
      // The preferences file is read on the plugins' preferences queue, so that the script's thread does not wait for the file
      // system. The promise is settled on the main thread.
      plugin.loadPreferences {
        if let value = plugin.preferences[key] ?? plugin.defaultPreferences[key] {
          resolve.call(withArguments: [value])
          return
        }
        Logger.log("Trying to get preference value for undefined key \(key)", level: .warning, subsystem: subsystem)
        resolve.call(withArguments: [])
      }
    }
  }

  @objc func set(_ key: String, _ value: Any) -> JSValue {
    let plugin = pluginInstance.plugin!
    return createPromise { resolve, _ in
      // The value is set once the preferences file has been read, so that the value read does not replace it.
      plugin.loadPreferences {
        plugin.preferences[key] = value
        resolve.call(withArguments: [])
      }
    }
  }

  @objc func sync() {
    pluginInstance.plugin.syncPreferences()
  }
}
