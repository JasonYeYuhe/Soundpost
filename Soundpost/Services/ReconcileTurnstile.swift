import Foundation

/// One notification reconcile at a time, and the newest plan wins (M20 §4D).
///
/// `NotificationScheduler.reconcile` reads the pending set, removes what is stale, then
/// awaits one `add` per missing request. Eleven call sites can start one, and nothing
/// stopped two from overlapping: an older reconcile suspended in an `add` could resume
/// after a newer one had finished and put back a request the newer plan had dropped — a
/// reminder for a capsule that was unsealed, or a 65th request that pushed a real one out
/// of iOS's 64.
///
/// **Making the scheduler an actor would not have fixed it.** Actors are reentrant across
/// `await`: two calls to an actor method interleave at every suspension exactly as they do
/// now, and the code would merely *look* serialised. This is a lock held across the
/// awaits — a FIFO of waiting calls — plus a ticket, so a call that has been overtaken
/// while it waited does nothing: the newer call behind it carries the newer plan.
///
/// The work runs in the caller's own task, so nothing non-`Sendable` crosses into the
/// actor; only the turn-taking lives here.
actor ReconcileTurnstile {
    private var highestTicket = 0
    private var lastApplied = 0
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Wait for the turn, holding `generation` as this call's place in line.
    ///
    /// **Pass the generation when the caller has one.** `reconcile` is a nonisolated
    /// `async` function, so it reaches this actor after a hop off the main actor, and
    /// the order calls *arrive here* is not the order they were *made*: a call whose
    /// hop stalls can arrive after a newer one (M20 §4D review). The coordinator
    /// numbers each `sync` on the main actor before its first suspension and passes
    /// that number in. Without one, the ticket is the next in arrival order.
    func enter(generation: Int? = nil) async -> Int {
        let ticket = generation ?? highestTicket + 1
        highestTicket = max(highestTicket, ticket)
        if busy {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            busy = true
        }
        return ticket
    }

    /// Whether this call's plan is no longer the newest: a newer call has taken a place
    /// in line, or one has already been applied.
    func isSuperseded(_ ticket: Int) -> Bool { ticket < highestTicket || ticket <= lastApplied }

    /// Record that `ticket`'s plan is what the centre now holds.
    func didApply(_ ticket: Int) { lastApplied = max(lastApplied, ticket) }

    /// Hand the turn to the next caller, in arrival order.
    func leave() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}
