//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO
@_spi(NIOIMAPInternal) import NIOIMAPCore

public struct InvalidClientState: Error {
    public init() {}
}

public struct UnexpectedAppendCommand: Error {
    public init() {}
}

public struct UnexpectedResponse: Error {
    public var kind: Kind
    public var activePromise: EventLoopPromise<Void>?

    public init(
        kind: Kind,
        activePromise: EventLoopPromise<Void>? = nil
    ) {
        self.kind = kind
        self.activePromise = activePromise
    }

    /// Used to give more context about where the unexpected response was encountered.
    public enum Kind: Equatable, Sendable {
        case commandCompletionWithUnknownTag(tag: String)
        case appendNotWaitingForTaggedResponse
        case appendWaitingForTaggedResponse
        case appendWithPendingContinuation
        case expectingLiteralContinuationRequest
        case taggedWhileExpectingContinuationRequest
        case errorState
        case authenticationChallenge
        case idleWaitingForConfirmation
        case idleStarted
        case idleRunning
        case authentication
        case authenticationFinished
        case authenticationWaitingForChallengeResponse
    }
}

public struct UnexpectedChunk: Error {
    public init() {}
}

public struct UnexpectedContinuationRequest: Error {
    public var kind: Kind

    public init(
        kind: Kind
    ) {
        self.kind = kind
    }

    /// Used to give more context about where the unexpected continuation request was encountered.
    public enum Kind: Equatable, Sendable {
        case append
        case append2
        case authentication
        case idle
        case normal
    }
}

public struct DuplicateCommandTag: Error {
    public var tag: String

    public init(tag: String) {
        self.tag = tag
    }
}

public struct InvalidCommandForState: Error, Equatable {
    public var command: CommandStreamPart

    public init(_ command: CommandStreamPart) {
        self.command = command
    }
}

struct OutgoingChunk: Equatable {
    var bytes: ByteBuffer
    var promise: EventLoopPromise<Void>?
    var shouldSucceedPromise: Bool

    static func == (lhs: OutgoingChunk, rhs: OutgoingChunk) -> Bool {
        lhs.shouldSucceedPromise == rhs.shouldSucceedPromise && lhs.bytes == rhs.bytes
            && lhs.promise?.futureResult === rhs.promise?.futureResult
    }
}

// TODO: See note below.
// This state machine could potentially be improved by
// splitting into 2. One that manages command logic
// (can this command be sent), and one that handles
// continuation logic once a command has been given the
// ok.
struct ClientStateMachine {
    struct ActiveEncodeContext: Equatable {
        private var buffer: CommandEncodeBuffer
        private var promise: EventLoopPromise<Void>?

        init(buffer: CommandEncodeBuffer, promise: EventLoopPromise<Void>?) {
            self.buffer = buffer
            self.promise = promise
        }

        mutating func drop() -> EventLoopPromise<Void>? {
            defer {
                self.promise = nil
                self.buffer = .init(buffer: ByteBuffer(), capabilities: .init(), loggingMode: false)
            }
            return self.promise
        }

        mutating func nextChunk() -> OutgoingChunk {
            let chunk = self.buffer.buffer.nextChunk()
            let promise = self.promise
            return .init(bytes: chunk.bytes, promise: promise, shouldSucceedPromise: !chunk.waitForContinuation)
        }

        static func == (
            lhs: ClientStateMachine.ActiveEncodeContext,
            rhs: ClientStateMachine.ActiveEncodeContext
        ) -> Bool {
            lhs.buffer == rhs.buffer && lhs.promise?.futureResult == rhs.promise?.futureResult
        }
    }

    enum ContinuationRequestAction: Equatable {
        case sendChunks([OutgoingChunk])
        case fireIdleStarted
        case fireAuthenticationChallenge
    }

    enum State: Equatable {
        /// We're expecting either a tagged or untagged response
        case expectingNormalResponse

        /// We're in some part of the idle flow
        case idle(ClientStateMachine.Idle)

        /// We're in some part of the authentication flow
        case authenticating(ClientStateMachine.Authentication)

        /// We're in some part of the appending flow
        case appending(ClientStateMachine.Append)

        /// We've sent a command that requires a continuation request
        /// for example `A1 LOGIN {1}\r\n\\ {1}\r\n\\`, and
        /// we're waiting for the continuation request from the server
        /// before sending another chunk.
        case expectingLiteralContinuationRequest(ActiveEncodeContext)

        /// An error has occurred and the connection should
        /// now be closed.
        case error
    }

    var encodingOptions: ClientEncodingOptions

    var state: State = .expectingNormalResponse
    private var activeCommandTags: Set<String> = []
    private var allocator: ByteBufferAllocator!

    // We mark where we should write up to at the next opportunity
    // using the `flush` method called from the channel handler.
    private var queuedCommands: MarkedCircularBuffer<(CommandStreamPart, EventLoopPromise<Void>?)> = .init(
        initialCapacity: 16
    )

    init(encodingOptions: IMAPClientHandler.EncodingOptions) {
        self.encodingOptions = ClientEncodingOptions(
            userOptions: encodingOptions
        )
    }

    mutating func handlerAdded(_ allocator: ByteBufferAllocator) {
        self.allocator = allocator
    }

    /// Tells the state machine that a continuation request has been received from the network.
    /// Returns the next batch of chunks to write.
    mutating func receiveContinuationRequest(_ req: ContinuationRequest) throws -> ContinuationRequestAction {
        do {
            return try self._receiveContinuationRequest(req)
        } catch {
            self.state = .error
            throw error
        }
    }

    private mutating func _receiveContinuationRequest(_ req: ContinuationRequest) throws -> ContinuationRequestAction {
        switch self.state {
        case .appending:
            return try self.receiveContinuationRequest_appending(request: req)
        case .expectingLiteralContinuationRequest:
            return try self.receiveContinuationRequest_expectingLiteralContinuationRequest(request: req)
        case .authenticating:
            return try self.receiveContinuationRequest_authenticating(request: req)
        case .idle:
            return try self.receiveContinuationRequest_idle(request: req)
        case .expectingNormalResponse, .error:
            throw UnexpectedContinuationRequest(kind: .normal)
        }
    }

    /// Tells the state machine that some response has been received. Note that receiving a response
    /// will never result in the client having to perform some action.
    mutating func receiveResponse(_ response: Response) throws {
        do {
            return try self._receiveResponse(response)
        } catch {
            self.state = .error
            throw error
        }
    }

    mutating func _receiveResponse(_ response: Response) throws {
        if let tag = response.tag {
            guard self.activeCommandTags.remove(tag) != nil else {
                throw UnexpectedResponse(
                    kind: .commandCompletionWithUnknownTag(tag: tag)
                )
            }
        }

        switch self.state {
        case .idle(var idleStateMachine):
            try idleStateMachine.receiveResponse(response)
            self.state = .idle(idleStateMachine)
        case .authenticating(var authStateMachine):
            try authStateMachine.receiveResponse(response)
            self.state = .expectingNormalResponse
        case .appending(var appendStateMachine):
            switch try appendStateMachine.receiveResponse(response) {
            case .doneAppending:
                self.state = .expectingNormalResponse
            case .continueAppending:
                self.state = .appending(appendStateMachine)
            }
        case .error:
            throw UnexpectedResponse(
                kind: .errorState
            )
        case .expectingNormalResponse, .expectingLiteralContinuationRequest:
            // If we’re expecting a Continuation Request, we should still
            // allow all normal responses. They may arrive due to timing.
            // The server may have sent these before we sent the data that
            // moved us into this state.
            switch response {
            case .untagged, .fetch:
                // we expected a normal response and received a normal
                // response, nothing to see here
                break
            case .tagged:
                // If we’re expecting a Continuation Request, and we received a command
                // completion, we need to make sure that it didn’t complete the command
                // that we are still in the process of sending. We can’t really do that
                // here due to how ClientStateMachine is structured, but we’ll at least
                // check that there’s _some_ command running.
                if case .expectingLiteralContinuationRequest(var context) = self.state {
                    guard !self.activeCommandTags.isEmpty else {
                        let promise = context.drop()
                        throw UnexpectedResponse(
                            kind: .taggedWhileExpectingContinuationRequest,
                            activePromise: promise
                        )
                    }
                }
            case .fatal:
                // if the server has sent a fatal then we shouldn't be able to do anything else
                self.state = .error
            case .authenticationChallenge:
                // We should be in a substate
                throw UnexpectedResponse(
                    kind: .authenticationChallenge
                )
            case .idleStarted:
                // We should be in a substate
                throw UnexpectedResponse(
                    kind: .idleStarted
                )
            }
        }
    }

    /// Tells the state machine that the client would like to send a command.
    /// We then return any chunks that can be written.
    mutating func sendCommand(
        _ command: CommandStreamPart,
        promise: EventLoopPromise<Void>? = nil
    ) throws -> OutgoingChunk? {
        guard
            self.state != .error
        else { throw InvalidClientState() }

        if let tag = command.tag {
            let (inserted, _) = self.activeCommandTags.insert(tag)
            guard inserted else {
                throw DuplicateCommandTag(tag: tag)
            }
        }
        self.queuedCommands.append((command, promise))

        if let result = try self.sendNextCommand() {
            // There can only be one chunk
            // 1. if first has a continuation then we will be in the continuation state
            // 2. if first doesn't have a continuation then there won't be a next chunk
            precondition(result.chunks.count == 1)
            return result.chunks.first!
        }
        return nil
    }

    /// Mark the back of the current command queue, and write up to and including
    /// this point next time we receive a continuation request or send a command.
    /// Note that we might not actually reach the mark as we may encounter a command
    /// that requires a continuation request.
    mutating func flush() {
        self.queuedCommands.mark()
    }

    /// Returns all of the promises for the writes that have not yet completed.
    /// These should probably be failed.
    mutating func channelInactive() -> [EventLoopPromise<Void>] {
        var activeEncodeContext: ActiveEncodeContext?
        switch self.state {
        case .expectingNormalResponse, .error, .appending, .authenticating, .idle:
            break
        case .expectingLiteralContinuationRequest(let _activeEncodeContext):
            activeEncodeContext = _activeEncodeContext
        }

        // we don't care what state we were in, all we want is
        // to move to the error state so that nothing else is sent
        self.state = .error

        var promises: [EventLoopPromise<Void>] = []
        if let promise = activeEncodeContext?.drop() {
            promises.append(promise)
        }

        promises.append(contentsOf: self.queuedCommands.compactMap(\.1))
        return promises
    }
}

// MARK: - Receive

extension ClientStateMachine {
    private mutating func receiveContinuationRequest_appending(
        request: ContinuationRequest
    ) throws -> ContinuationRequestAction {
        guard case .appending(var appendingStateMachine) = self.state
        else {
            preconditionFailure("Invalid state: \(self.state)")
        }
        try appendingStateMachine.receiveContinuationRequest(request)
        self.state = .appending(appendingStateMachine)
        return try .sendChunks(self.extractSendableChunks().chunks)
    }

    private mutating func receiveContinuationRequest_expectingLiteralContinuationRequest(
        request: ContinuationRequest
    ) throws -> ContinuationRequestAction {
        guard case .expectingLiteralContinuationRequest(let context) = self.state else {
            preconditionFailure("Invalid state: \(self.state)")
        }

        self.state = .expectingNormalResponse
        let result = try self.extractSendableChunks(currentContext: context)

        // safe to bang as if we've successfully received a
        // continuation request then MUST be something to send
        if let nextContext = result.nextContext {  // we've found another continuation
            self.state = .expectingLiteralContinuationRequest(nextContext)
        } else {
            self.state = .expectingNormalResponse
        }
        return .sendChunks(result.chunks)
    }

    private mutating func receiveContinuationRequest_authenticating(
        request: ContinuationRequest
    ) throws -> ContinuationRequestAction {
        guard case .authenticating(var authenticatingStateMachine) = self.state else {
            preconditionFailure("Invalid state: \(self.state)")
        }

        switch request {
        case .responseText:
            // no valid base 64, so we can assume it was empty
            try authenticatingStateMachine.receiveContinuationRequest(.data(ByteBuffer()))
            self.state = .authenticating(authenticatingStateMachine)
        case .data(let byteBuffer):
            try authenticatingStateMachine.receiveContinuationRequest(.data(byteBuffer))
            self.state = .authenticating(authenticatingStateMachine)
        }
        return .fireAuthenticationChallenge
    }

    private mutating func receiveContinuationRequest_idle(
        request: ContinuationRequest
    ) throws -> ContinuationRequestAction {
        guard case .idle(var idleStateMachine) = self.state else {
            preconditionFailure("Invalid state: \(self.state)")
        }

        // A continuation when in idle state means it's been confirmed
        try idleStateMachine.receiveContinuationRequest(request)
        self.state = .idle(idleStateMachine)
        return .fireIdleStarted
    }
}

// MARK: - Send

extension ClientStateMachine {
    private mutating func sendTaggedCommand(
        _ command: TaggedCommand,
        promise: EventLoopPromise<Void>?
    ) -> SendableChunks {
        guard case .expectingNormalResponse = self.state else {
            preconditionFailure("Invalid state: \(self.state)")
        }

        let buffer = self.makeEncodeBuffer(.tagged(command))
        var context = ActiveEncodeContext(buffer: buffer, promise: promise)

        switch command.command {
        case .idleStart:
            self.guardAgainstMultipleRunningCommands()
            self.state = .idle(Idle())
            return .init(chunks: [context.nextChunk()], nextContext: nil)
        case .authenticate:
            self.guardAgainstMultipleRunningCommands()
            self.state = .authenticating(Authentication())
            return .init(chunks: [context.nextChunk()], nextContext: nil)
        default:
            let chunk = context.nextChunk()

            // if we're meant to succeed the promise then there can't be any next context
            guard chunk.shouldSucceedPromise else {
                self.state = .expectingLiteralContinuationRequest(context)
                return .init(chunks: [chunk], nextContext: context)
            }
            precondition(context.nextChunk().bytes.readableBytes == 0)
            self.state = .expectingNormalResponse
            return .init(chunks: [chunk], nextContext: nil)
        }
    }

    private mutating func sendAppendCommand(
        _ command: AppendCommand,
        promise: EventLoopPromise<Void>?
    ) throws -> SendableChunks {
        guard case .expectingNormalResponse = self.state else {
            preconditionFailure("Invalid state: \(self.state)")
        }
        guard let tag = command.tag else {
            throw UnexpectedAppendCommand()
        }

        // no other commands can be running when we start appending
        self.state = .appending(Append(tag: tag))

        // TODO: This assumes that the append command doesn't require a continuation - fix this in another PR
        let buffer = self.makeEncodeBuffer(.append(command))
        var context = ActiveEncodeContext(buffer: buffer, promise: promise)
        return .init(chunks: [context.nextChunk()], nextContext: nil)
    }

    /// Iterate through the current command queue until we reached the marked position
    /// or encounter a command that requires a continuation request to complete.

    struct SendableChunks {
        var chunks: [OutgoingChunk]
        var nextContext: ActiveEncodeContext?
    }

    private mutating func extractSendableChunks(currentContext: ActiveEncodeContext? = nil) throws -> SendableChunks {
        var results: [OutgoingChunk] = []
        if var currentContext = currentContext {
            let chunk = currentContext.nextChunk()
            guard chunk.shouldSucceedPromise else {
                self.state = .expectingLiteralContinuationRequest(currentContext)
                return .init(chunks: [chunk], nextContext: currentContext)
            }
            results.append(chunk)
        }

        while self.queuedCommands.hasMark, let sendableChunk = try self.sendNextCommand() {
            results.append(contentsOf: sendableChunk.chunks)
            if let context = sendableChunk.nextContext {
                return .init(chunks: results, nextContext: context)
            }
        }

        return .init(chunks: results, nextContext: nil)
    }

    /// Throws an error if more than one command is running, otherwise does nothing.
    /// End users are required to ensure command pipelining compatibility.
    private func guardAgainstMultipleRunningCommands() {
        precondition(self.activeCommandTags.count == 1)
    }

    private func makeEncodeBuffer(_ command: CommandStreamPart? = nil) -> CommandEncodeBuffer {
        let byteBuffer = self.allocator.buffer(capacity: 128)
        var encodeBuffer = CommandEncodeBuffer(
            buffer: byteBuffer,
            options: self.encodingOptions.encodingOptions,
            loggingMode: false
        )
        if let command = command {
            encodeBuffer.writeCommandStream(command)
        }
        return encodeBuffer
    }

    var isWaitingForContinuationRequest: Bool {
        switch self.state {
        case .appending(let sub):
            sub.isWaitingForContinuationRequest
        case .expectingLiteralContinuationRequest:
            true
        case .expectingNormalResponse, .idle, .authenticating, .error:
            false
        }
    }

    private mutating func sendNextCommand() throws -> SendableChunks? {
        guard !isWaitingForContinuationRequest else { return nil }

        guard let (command, promise) = self.queuedCommands.popFirst() else {
            preconditionFailure("You can't send a non-existent command")
        }

        switch self.state {
        case .expectingNormalResponse:
            return try self.sendNextCommand_expectingNormalResponse(command: command, promise: promise)
        case .idle:
            return self.sendNextCommand_idle(command: command, promise: promise)
        case .authenticating:
            return self.sendNextCommand_authenticating(command: command, promise: promise)
        case .appending:
            return self.sendNextCommand_appending(command: command, promise: promise)
        case .expectingLiteralContinuationRequest:
            // if we're waiting for a continuation request
            // the by definition we can't do anything
            return nil
        case .error:
            preconditionFailure("Already in error state, make sure to handle errors appropriately.")
        }
    }

    /// If we're "expecting a normal response" then we aren't waiting for a continuation request. However, the
    /// command we want to send may require a continuation itself. We begin by writing the command to
    /// an encode buffer to isolate any required continuations, and then send every chunk until we run out of chunks
    /// to send, or we find a chunk that requires a continuation request.
    private mutating func sendNextCommand_expectingNormalResponse(
        command: CommandStreamPart,
        promise: EventLoopPromise<Void>?
    ) throws -> SendableChunks {
        guard case .expectingNormalResponse = self.state else {
            preconditionFailure("Invalid state: \(self.state)")
        }

        switch command {
        case .idleDone, .continuationResponse:
            preconditionFailure("Invalid command for state: \(command)")
        case .tagged(let tc):
            return self.sendTaggedCommand(tc, promise: promise)
        case .append(let ac):
            return try self.sendAppendCommand(ac, promise: promise)
        }
    }

    /// When idle we need to first defer to the idle state machine to make sure we can send the
    /// the next part of the authentication. If we can, then just send the message. There's no need
    /// to wait for a continuation request.
    private mutating func sendNextCommand_idle(
        command: CommandStreamPart,
        promise: EventLoopPromise<Void>?
    ) -> SendableChunks {
        guard case .idle(var idleStateMachine) = self.state else {
            preconditionFailure("Invalid state: \(self.state)")
        }
        guard command == .idleDone else {
            preconditionFailure("Invalid command when idle \(command)")
        }

        idleStateMachine.sendCommand(command)
        self.state = .expectingNormalResponse
        var encodeBuffer = self.makeEncodeBuffer(command)
        let chunk = encodeBuffer.buffer.nextChunk()
        precondition(!chunk.waitForContinuation)
        return .init(
            chunks: [.init(bytes: chunk.bytes, promise: promise, shouldSucceedPromise: true)],
            nextContext: nil
        )
    }

    /// When authenticating we need to first defer to the authentication state machine to make sure
    /// can send the next part of the authentication. If we can, then just send the message. There's
    /// no need to wait for a continuation request.
    private mutating func sendNextCommand_authenticating(
        command: CommandStreamPart,
        promise: EventLoopPromise<Void>?
    ) -> SendableChunks {
        guard case .authenticating(var authenticatingStateMachine) = self.state else {
            preconditionFailure("Invalid state: \(self.state)")
        }
        guard case .continuationResponse(let data) = command else {
            preconditionFailure("Continuation responses only")
        }

        authenticatingStateMachine.sendCommand(command)
        self.state = .authenticating(authenticatingStateMachine)
        var encodeBuffer = self.makeEncodeBuffer(.continuationResponse(data))
        let chunk = encodeBuffer.buffer.nextChunk()
        precondition(!chunk.waitForContinuation)
        return .init(
            chunks: [.init(bytes: chunk.bytes, promise: promise, shouldSucceedPromise: true)],
            nextContext: nil
        )
    }

    /// When appending we need to first defer to the appending state machine to see if we can actually
    /// send a command given our current state. If we can then we need to check what kind of command
    /// is being sent. If we're beginning an append or catenation then we need to wait for a continuation
    /// request, otherwise we can send the command and continue.
    private mutating func sendNextCommand_appending(
        command: CommandStreamPart,
        promise: EventLoopPromise<Void>?
    ) -> SendableChunks? {
        guard case .appending(var appendingStateMachine) = self.state
        else {
            preconditionFailure("Invalid state: \(self.state)")
        }
        guard case .append(let command) = command else {
            preconditionFailure("Append commands only in this state")
        }

        // If we're pending a continuation (e.g. after sending a message literal header)
        // then we can't write the command yet.
        guard !appendingStateMachine.isWaitingForContinuationRequest else {
            return nil
        }

        // Workaround: Using non-synchronizing literals is broken for APPEND.
        var encodingOptions = self.encodingOptions.encodingOptions
        encodingOptions.useSynchronizingLiteral = true
        encodingOptions.useNonSynchronizingLiteralPlus = false
        encodingOptions.useNonSynchronizingLiteralMinus = false

        var encodeBuffer = CommandEncodeBuffer(
            buffer: ByteBuffer(),
            options: encodingOptions,
            encodedAtLeastOneCatenateElement: appendingStateMachine.hasCatenatedAtLeastOneObject,
            loggingMode: false
        )
        encodeBuffer.writeCommandStream(.append(command))

        appendingStateMachine.sendCommand(.append(command))
        let chunk = encodeBuffer.buffer.nextChunk()
        self.state = .appending(appendingStateMachine)

        // We always need append commands to be sent instantly so we can receive continuations
        // so the write promise should always be succeeded.
        return .init(
            chunks: [.init(bytes: chunk.bytes, promise: promise, shouldSucceedPromise: true)],
            nextContext: nil
        )
    }
}
