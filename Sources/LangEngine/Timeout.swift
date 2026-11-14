import Foundation
import os
import LangCore

/// One-shot rendezvous between the operation, the timer and the awaiting caller. The first
/// `finish` wins; a result that arrives before the caller installs its continuation is parked.
private final class Race<T: Sendable>: Sendable {
    private enum State {
        case idle
        case waiting(CheckedContinuation<Result<T, EngineError>, Never>)
        case parked(Result<T, EngineError>)
        case done
    }
    private let state = OSAllocatedUnfairLock<State>(initialState: .idle)

    func install(_ c: CheckedContinuation<Result<T, EngineError>, Never>) {
        let parked: Result<T, EngineError>? = state.withLock { s in
            switch s {
            case .idle:
                s = .waiting(c)
                return nil
            case .parked(let r):
                s = .done
                return r
            case .waiting, .done:
                return nil
            }
        }
        if let parked { c.resume(returning: parked) }
    }

    /// Returns true when this call decided the race.
    @discardableResult
    func finish(_ result: Result<T, EngineError>) -> Bool {
        let (won, waiter): (Bool, CheckedContinuation<Result<T, EngineError>, Never>?) = state.withLock { s in
            switch s {
            case .idle:
                s = .parked(result)
                return (true, nil)
            case .waiting(let c):
                s = .done
                return (true, c)
            case .parked, .done:
                return (false, nil)
            }
        }
        waiter?.resume(returning: result)
        return won
    }
}

/// Run `operation` but give up after `seconds`: `onTimeout` is called, the operation is cancelled
/// and `.timeout` is thrown. The caller is released at the deadline even if the operation ignores
/// cancellation (its result is then discarded).
public func withTimeout<T: Sendable>(
    seconds: Double,
    onTimeout: @escaping @Sendable () async -> Void = {},
    operation: @escaping @Sendable () async throws -> T
) async throws(EngineError) -> T {
    let race = Race<T>()
    let op = Task {
        do { race.finish(.success(try await operation())) }
        catch let e as EngineError { race.finish(.failure(e)) }
        catch is CancellationError { race.finish(.failure(EngineError(.timeout, "engine call cancelled"))) }
        catch { race.finish(.failure(EngineError(.internalError, "unexpected engine failure"))) }
    }
    let timer = Task {
        do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
        if race.finish(.failure(EngineError(.timeout, "engine call timed out after \(seconds)s"))) {
            await onTimeout()
            op.cancel()
        }
    }
    let result = await withTaskCancellationHandler {
        await withCheckedContinuation { race.install($0) }
    } onCancel: {
        op.cancel()
        timer.cancel()
        race.finish(.failure(EngineError(.timeout, "engine call cancelled")))
    }
    timer.cancel()
    return try result.get()
}
