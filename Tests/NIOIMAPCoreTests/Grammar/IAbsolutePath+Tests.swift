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

import NIO
@testable import NIOIMAPCore
import XCTest

class IAbsolutePath_Tests: EncodeTestClass {}

// MARK: - IMAP

extension IAbsolutePath_Tests {
    func testEncode() {
        let inputs: [(IAbsolutePath, String, UInt)] = [
            (.init(command: .messageList(.init(mailboxReference: .init(encodeMailbox: .init(mailbox: "test"))))), "/test", #line),
        ]
        self.iterateInputs(inputs: inputs, encoder: { self.testBuffer.writeIAbsolutePath($0) })
    }
}