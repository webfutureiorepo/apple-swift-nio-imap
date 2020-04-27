//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import struct NIO.ByteBuffer

extension NIOIMAP {
    /// IMAPv4 `resp-text-code`
    public enum ResponseTextCode: Equatable {
        case alert
        case badCharset([String])
        case capability([Capability])
        case parse
        case permanentFlags([PermanentFlag])
        case readOnly
        case readWrite
        case tryCreate
        case uidNext(Int)
        case uidValidity(Int)
        case unseen(Int)
        case namespace(NamespaceResponse)
        case other(String, String?)
    }
}

// MARK: - Encoding

extension ByteBuffer {
    @discardableResult mutating func writeResponseTextCode(_ code: NIOIMAP.ResponseTextCode) -> Int {
        switch code {
        case .alert:
            return self.writeString("ALERT")
        case .badCharset(let charsets):
            return self.writeResponseTextCode_badCharsets(charsets)
        case .capability(let data):
            return self.writeCapabilityData(data)
        case .parse:
            return self.writeString("PARSE")
        case .permanentFlags(let flags):
            return
                self.writeString("PERMANENTFLAGS ") +
                self.writePermanentFlags(flags)
        case .readOnly:
            return self.writeString("READ-ONLY")
        case .readWrite:
            return self.writeString("READ-WRITE")
        case .tryCreate:
            return self.writeString("TRYCREATE")
        case .uidNext(let number):
            return self.writeString("UIDNEXT \(number)")
        case .uidValidity(let number):
            return self.writeString("UIDVALIDITY \(number)")
        case .unseen(let number):
            return self.writeString("UNSEEN \(number)")
        case .other(let atom, let string):
            return self.writeResponseTextCode_other(atom: atom, string: string)
        case .namespace(let namesapce):
            return self.writeNamespaceResponse(namesapce)
        }
    }

    private mutating func writeResponseTextCode_badCharsets(_ charsets: [String]) -> Int {
        self.writeString("BADCHARSET") +
            self.writeIfArrayHasMinimumSize(array: charsets) { (charsets, self) -> Int in
                self.writeSpace() +
                    self.writeArray(charsets) { (charset, self) in
                        self.writeString(charset)
                    }
            }
    }

    private mutating func writeResponseTextCode_other(atom: String, string: String?) -> Int {
        self.writeString(atom) +
            self.writeIfExists(string) { (string) -> Int in
                self.writeString(" \(string)")
            }
    }
}