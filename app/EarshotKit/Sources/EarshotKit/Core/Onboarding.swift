/// The first-launch steps, in the spec's order.
public enum OnboardingStep: Int, Sendable, CaseIterable {
    case intro, voice, mic, hotkey, models, ducking, tryIt
}

public enum Onboarding {
    /// 2 added the listening steps. Stored when the onboarding is done.
    public static let version = 2

    /// What to show: everything to a new user, the listening steps once to someone who
    /// finished an older onboarding, nothing after that.
    public static func steps(onboarded: Bool, storedVersion: Int) -> [OnboardingStep] {
        if !onboarded { return OnboardingStep.allCases }
        if storedVersion < version { return [.mic, .hotkey, .models, .tryIt] }
        return []
    }
}
