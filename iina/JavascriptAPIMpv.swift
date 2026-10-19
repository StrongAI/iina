//
//  JavascriptAPIMpv.swift
//  iina
//
//  Created by Collider LI on 11/9/2018.
//  Copyright © 2018 lhc. All rights reserved.
//

import Foundation
import JavaScriptCore

@objc protocol JavascriptAPIMpvExportable: JSExport {
  func getFlag(_ property: String) -> JSValue
  func getNumber(_ property: String) -> JSValue
  func getString(_ property: String) -> JSValue
  func getNative(_ property: String) -> JSValue
  func set(_ property: String, _ value: JSValue)
  func command(_ commandName: String, _ args: [String])
  func addHook(_ name: String, _ priority: Int, _ callback: JSValue)
}

class JavascriptAPIMpv: JavascriptAPI, JavascriptAPIMpvExportable {
  private var identifier: String!

  override func extraSetup() {
    identifier = pluginInstance.plugin.identifier
  }

  override func cleanUp(_ instance: JavascriptPluginInstance) {
    player!.mpv.removeHooks(withIdentifier: identifier)
  }

  // The getters read the property without the calling thread waiting for mpv, and return a promise settled on the main thread with
  // the value mpv answers: false, 0 or null for a property mpv could not read.
  @objc func getFlag(_ property: String) -> JSValue {
    let mpv: MPVController = player!.mpv
    return createPromise { resolve, _ in
      mpv.getFlagAsync(property) { value in
        DispatchQueue.main.async { resolve.call(withArguments: [value ?? false]) }
      }
    }
  }

  @objc func getNumber(_ property: String) -> JSValue {
    let mpv: MPVController = player!.mpv
    return createPromise { resolve, _ in
      mpv.getDoublesAsync([property]) { values in
        DispatchQueue.main.async { resolve.call(withArguments: [values[0] ?? 0]) }
      }
    }
  }

  @objc func getString(_ property: String) -> JSValue {
    let mpv: MPVController = player!.mpv
    return createPromise { resolve, _ in
      mpv.getStringsAsync([property]) { values in
        DispatchQueue.main.async { resolve.call(withArguments: [values[0] ?? NSNull()]) }
      }
    }
  }

  @objc func getNative(_ property: String) -> JSValue {
    let mpv: MPVController = player!.mpv
    return createPromise { resolve, _ in
      mpv.getNodeAsync(property) { value in
        DispatchQueue.main.async { resolve.call(withArguments: [value ?? NSNull()]) }
      }
    }
  }

  @objc func set(_ property: String, _ value: JSValue) {
    guard permitted(to: .accessFileSystem) || AppData.safeMPVOptions.contains(property) else {
      throwError(withMessage: "mpv.set: \(property) needs the file system permission.")
      return
    }

    // The value is set without waiting for mpv, which handles a later read of it after the set.
    if value.isNumber {
      player!.mpv.setDoubleAsync(property, value.toDouble())
    } else if value.isString {
      player!.mpv.setStringAsync(property, value.toString())
    } else if value.isBoolean {
      player!.mpv.setFlagAsync(property, value.toBool())
    } else if value.isObject {
      if let object = value.toObject() {
        player!.mpv.setNodeAsync(property, object)
      }
    } else {
      throwError(withMessage: "mpv.set only supports numbers, strings, booleans and objects.")
    }
  }

  @objc func command(_ commandName: String, _ args: [String]) {
    guard permitted(to: .accessFileSystem) || AppData.safeMPVCommands.contains(commandName) else {
      throwError(withMessage: "mpv.command: \(commandName) needs the file system permission.")
      return
    }
    player!.mpv.asyncCommand(MPVCommand(commandName), args: args, checkError: false, replyUserdata: 0)
  }

  @objc func addHook(_ name: String, _ priority: Int, _ callback: JSValue) {
    let hook = MPVHookValue(withIdentifier: identifier, jsContext: context, jsBlock: callback, owner: self)
    player!.mpv.addHook(MPVHook(name), priority: Int32(priority), hook: hook)
  }
}
