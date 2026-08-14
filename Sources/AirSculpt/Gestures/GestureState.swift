/// The two top-level modes of the app, toggled by the rock sign 🤘.
enum GestureState: String, Sendable {
    /// MOVE mode: all manipulation — single flat hand turns the sculpture,
    /// two open hands hold-and-move it (turning the pair rolls it), two
    /// pinches resize it. No drawing.
    case idle
    /// DRAW mode: pointing draws, 🤙/✌️ snap the last stroke. No movement —
    /// keeping the modes exclusive is what stops gesture confusion.
    case active
}
