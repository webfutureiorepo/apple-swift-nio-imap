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
    /// IMAPv4 `message-data`
    /// One message attribute is guaranteed
    public enum MessageData: Equatable {
        case expunge(Int)
    }
}

// MARK: - Encoding

extension ByteBuffer {
    @discardableResult mutating func writeMessageData(_ data: NIOIMAP.MessageData) -> Int {
        switch data {
        case .expunge(let number):
            return self.writeString("\(number) EXPUNGE")
        }
    }

    @discardableResult mutating func writeMessageDataEnd(_: NIOIMAP.MessageData) -> Int {
        self.writeString(")")
    }
}