import Foundation
import Testing

/// The views' half of M20 §4C, read from source — there is no UI-test target.
///
/// `WriteFailureTests` proves a failed save changes nothing. That is only worth
/// something if the screen then says so and stays: the detail view used to dismiss to
/// the gallery, or announce "sealed — but reminders are off", whatever the save did, and
/// the capture retry began by committing the failed attempt. A model test cannot see
/// either, so this reads the four functions that render the answer.
///
/// Like `ProOfferTests`' door guard it is a shape check, not a proof: it fails when the
/// stop-and-tell is deleted or the pre-save comes back, not for every way to be wrong.
@Suite("A failed write stays on screen and says so")
struct WriteFailureViewGuardTests {
    @Test func aFailedSealOrUnsealTellsTheUserAndGoesNoFurther() throws {
        let detail = try Self.code("Soundpost/Views/CapsuleDetailView.swift")
        let paths = [("private func seal(until date: Date) {", "store.commitSeal("),
                     ("private func unseal() {", "store.commitUnseal(")]
        for (signature, write) in paths {
            let body = try Self.body(of: signature, in: detail)
            // The write that restores on failure — not the old change-then-save pair,
            // which `WriteFailureTests` cannot see because it calls the store directly.
            #expect(body.contains(write), "\(signature) no longer writes through \(write)")
            #expect(!body.contains("store.seal(") && !body.contains("store.unseal(")
                    && !body.contains(".save()"), "\(signature) changes and saves by hand again")
            let handler = try #require(body.range(of: "catch {"), "\(signature) no longer catches")
            let catchBody = body[handler.upperBound...].prefix { $0 != "}" }
            #expect(catchBody.contains("writeFailed = true"), "\(signature): the failure is not shown")
            #expect(catchBody.contains("return"), "\(signature): it goes on as if the save had worked")
            #expect(!catchBody.contains("dismiss()"), "\(signature): it leaves the screen on a failure")
        }
    }

    @Test func aFailedDeleteDoesNotLeaveTheScreen() throws {
        let body = try Self.body(of: "private func delete() {",
                                 in: try Self.code("Soundpost/Views/CapsuleDetailView.swift"))
        #expect(body.contains("CapsuleActions.delete("), "the delete order is no longer the tested one")
        let squeezed = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(squeezed.contains("if deleted { dismiss() } else { writeFailed = true }"))
        #expect(body.components(separatedBy: "dismiss()").count - 1 == 1, "a second way out of the screen")
    }

    @Test func theCaptureRetryDoesNotBeginBySaving() throws {
        let body = try Self.body(of: "private func save() {",
                                 in: try Self.code("Soundpost/Capture/CaptureView.swift"))
        #expect(body.contains("viewModel.save(using: store)"))
        #expect(!body.contains("store.save()"), "a save before the capture's own commits a failed attempt")
    }

    // MARK: Source

    private static func code(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: path)
        try #require(FileManager.default.fileExists(atPath: url.path), "\(path) has moved; this guard checks nothing")
        // Comments explain these paths and name the very calls being looked for.
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// From `signature` to the closing brace at the function's own indentation.
    private static func body(of signature: String, in code: String) throws -> Substring {
        let start = try #require(code.range(of: signature), "\(signature) is gone")
        let end = try #require(code.range(of: "\n    }\n", range: start.upperBound..<code.endIndex),
                               "\(signature) has no end")
        return code[start.upperBound..<end.lowerBound]
    }
}
