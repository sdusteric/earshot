extension ListenModels.State {
    /// The state to show after `new`. Download progress arrives from separate
    /// tasks, so an older value can come after a newer one; the bar never moves back.
    public func showing(_ new: ListenModels.State) -> ListenModels.State {
        if case .downloading(let old) = self, case .downloading(let p) = new, p < old { return self }
        return new
    }

    /// "42%" while downloading.
    public var percent: String? {
        if case .downloading(let p) = self { return "\(Int((p * 100).rounded(.down)))%" }
        return nil
    }
}
