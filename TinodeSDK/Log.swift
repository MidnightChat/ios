//
//  Log.swift
//  MidnightSDK
//
//  Copyright © 2019 Midnight. All rights reserved.
//

import Foundation

enum LogType {
    case debug
    case info
    case error
    case fault
}

open class Log {
    let prefix: String
    public static let `default` = Log(subsystem: "default")

    public init(subsystem: String = Bundle.main.bundleIdentifier ?? "") {
        self.prefix = "[" + subsystem + "] "
    }
    func log(type: LogType, message: StaticString, _ args: [CVarArg]) {
        #if DEBUG
            let shouldLog = true
        #else
            let shouldLog = type != .debug
        #endif
        guard shouldLog else { return }
        let msg = self.prefix + message.description
        withVaList(args) {
            NSLogv(msg, $0)
        }
    }
    public func debug(_ message: StaticString, _ args: CVarArg...) {
        log(type: .debug, message: message, args)
    }
    public func info(_ message: StaticString, _ args: CVarArg...) {
        log(type: .info, message: message, args)
    }
    public func error(_ message: StaticString, _ args: CVarArg...) {
        log(type: .error, message: message, args)
    }
    public func fault(_ message: StaticString, _ args: CVarArg...) {
        log(type: .fault, message: message, args)
    }
}
