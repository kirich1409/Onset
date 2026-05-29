import Domain

// Placeholder so the Infrastructure target compiles before the capture/encoding
// implementations exist (ScreenCaptureKit / AVFoundation / AVAssetWriter /
// VideoToolbox / CoreMedia). Infrastructure depends only on Domain.
public enum InfrastructurePlaceholder {
    public static let layer = "Infrastructure"
    public static let dependsOn = DomainPlaceholder.layer
}
