/// What a spoken command asks for. Targets are as said ("billing"); the
/// session directory finds the session.
public enum Command: Sendable, Equatable {
    /// Put a prompt into a session. No target: the only session, or the one
    /// Earshot last spoke about.
    case send(target: String?, prompt: String)
    /// No target: the roll call.
    case status(target: String?)
    /// "How are you doing?": a short answer with what needs you, not the whole roll call.
    case greet
    /// now: stop at once (background sessions), else after the current step.
    case stop(target: String?, now: Bool)
    case start(project: String, prompt: String?)
    /// Yes or no to a permission prompt.
    case answer(allow: Bool, target: String?)
    case unknown
}
