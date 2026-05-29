// Placeholder so the Domain target compiles before real domain types exist.
// The Swift implementation stage replaces this with value types and protocols
// (Domain speaks CoreMedia on the hot-path boundary by design — no wrapper layer).
public enum DomainPlaceholder {
    public static let layer = "Domain"
}
