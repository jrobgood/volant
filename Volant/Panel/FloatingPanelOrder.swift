import AppKit

extension NSWindow {
    /// Orders this window directly above a visible peer on the same window level.
    ///
    /// The launcher and notes panels share the floating level and are nonactivating, so their
    /// front-to-back order cannot rely on application activation. Each panel calls this after it
    /// is fronted, making the most recently presented panel explicitly frontmost. Hidden peers,
    /// peers on another level and the window itself are left alone; key status is not changed.
    func orderAboveFloatingPeer(_ peer: NSWindow?) {
        guard isVisible, let peer, peer !== self, peer.isVisible, peer.level == level else { return }
        order(.above, relativeTo: peer.windowNumber)
    }
}
