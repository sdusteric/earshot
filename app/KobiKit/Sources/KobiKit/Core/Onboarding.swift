/// The first-launch steps, in order: what Kobi is, the Claude Code plugin,
/// how it stays out of the way (notifications, other audio, login), what
/// listening needs (mic, hotkey, speech models), a first command, and Activity.
public enum OnboardingStep: Int, Sendable, CaseIterable {
    case intro, plugin, quiet, listen, tryIt, activity
}

public enum Onboarding {
    /// 2 added the listening steps. Stored when the onboarding is done.
    public static let version = 2

    /// What to show: everything to a new user, the listening steps once to someone who
    /// finished an older onboarding, nothing after that.
    public static func steps(onboarded: Bool, storedVersion: Int) -> [OnboardingStep] {
        if !onboarded { return OnboardingStep.allCases }
        if storedVersion < version { return [.listen, .tryIt, .activity] }
        return []
    }
}
