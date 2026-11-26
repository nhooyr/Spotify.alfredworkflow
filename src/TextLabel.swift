import AppKit

final class TextLabel: NSTextField {
  override var stringValue: String {
    get { super.stringValue }
    set {
      guard super.stringValue != newValue else { return }
      super.stringValue = newValue
      displayTextIfVisible()
    }
  }
  override var font: NSFont? {
    get { super.font }
    set {
      guard super.font != newValue else { return }
      super.font = newValue
      displayTextIfVisible()
    }
  }
  override var textColor: NSColor? {
    get { super.textColor }
    set {
      guard super.textColor != newValue else { return }
      super.textColor = newValue
      displayTextIfVisible()
    }
  }
  private func displayTextIfVisible() {
    guard window?.isVisible == true, !visibleRect.isEmpty else { return }
    // Finish the replacement backing before scrolling can flush another view.
    layoutSubtreeIfNeeded()
    displayIfNeeded()
  }
}
