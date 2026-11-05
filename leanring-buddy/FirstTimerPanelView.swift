//
//  FirstTimerPanelView.swift
//  leanring-buddy
//
//  The big, easy-to-read panel for First-Timer Mode. During onboarding it
//  shows the current question in large text and the 1 to 5 comfort level
//  buttons. For level 1 and 2 users it then becomes a helper box with the
//  current step in large text plus big "I did it" and "I'm lost" buttons.
//
//  The user can drag it anywhere with the "Move" handle, shrink it to a
//  small "Show helper" pill with "Hide", or turn First-Timer Mode off.
//
//  It lives in its own floating NSPanel (not the cursor overlay) because the
//  cursor overlay is click-through, and this panel needs clickable buttons.
//  The panel is non-activating so clicking a button never steals focus from
//  the app the user is working in (for example Chrome).
//

import AppKit
import Combine
import SwiftUI

// MARK: - Panel Window

/// NSPanel that can receive clicks without activating Clicky, so the user's
/// current app keeps keyboard focus while they press our big buttons.
/// canBecomeKey is true only so SwiftUI buttons work reliably; combined with
/// becomesKeyOnlyIfNeeded the panel never actually takes keyboard focus,
/// because it has no text fields.
private class FirstTimerFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that reacts to the very first click. Without this, the first
/// click on a button in a background panel can be swallowed just to focus it,
/// which would confuse someone who isn't comfortable with computers.
private class FirstClickAcceptingHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Which arrangement the panel is in. Used to decide where it sits on screen
/// and to forget a dragged position when the arrangement changes.
private enum FirstTimerPanelLayout {
    case onboardingQuestions
    case simpleGuidanceHelperBox
    case collapsedPill
}

/// Shows and hides the First-Timer panel, keeps it sized to its SwiftUI
/// content, and remembers where the user dragged it.
@MainActor
final class FirstTimerPanelWindowManager {
    private var firstTimerPanel: FirstTimerFloatingPanel?
    private var firstTimerPanelHostingView: FirstClickAcceptingHostingView<FirstTimerPanelView>?
    private var panelVisibilityCancellable: AnyCancellable?
    private var panelContentChangeCancellable: AnyCancellable?

    /// Once the user drags the panel somewhere, we stop snapping it back to
    /// its default spot every time the text changes.
    private var hasUserDraggedPanelToCustomPosition = false

    /// The arrangement the panel was in the last time we positioned it.
    private var panelLayoutAtLastPositioning: FirstTimerPanelLayout?

    /// Space between the bottom of the panel and the bottom of the usable
    /// screen area (above the Dock).
    private let distanceAboveBottomOfScreen: CGFloat = 40

    /// Space between the helper box and the right edge of the screen.
    private let distanceFromRightEdgeOfScreen: CGFloat = 24

    private let firstTimerModeController: FirstTimerModeController

    init(firstTimerModeController: FirstTimerModeController) {
        self.firstTimerModeController = firstTimerModeController

        // Show or hide the panel whenever the controller says so.
        panelVisibilityCancellable = firstTimerModeController.$isFirstTimerPanelVisible
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] shouldShowFirstTimerPanel in
                if shouldShowFirstTimerPanel {
                    self?.showFirstTimerPanel()
                } else {
                    self?.hideFirstTimerPanel()
                }
            }

        // Any change to the text or step can change the content size, so
        // re-fit the panel shortly after. The async hop lets SwiftUI re-layout
        // first so fittingSize reflects the new content.
        panelContentChangeCancellable = firstTimerModeController.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.resizeAndRepositionPanelToFitContent()
                }
            }
    }

    private func showFirstTimerPanel() {
        if firstTimerPanel == nil {
            createFirstTimerPanel()
        }
        resizeAndRepositionPanelToFitContent()
        firstTimerPanel?.orderFrontRegardless()
    }

    private func hideFirstTimerPanel() {
        firstTimerPanel?.orderOut(nil)
    }

    private func createFirstTimerPanel() {
        let firstTimerPanelView = FirstTimerPanelView(
            firstTimerModeController: firstTimerModeController,
            onUserStartedDraggingPanel: { [weak self] in
                self?.hasUserDraggedPanelToCustomPosition = true
            }
        )
        let hostingView = FirstClickAcceptingHostingView(rootView: firstTimerPanelView)

        let initialPanelSize = hostingView.fittingSize
        let panel = FirstTimerFloatingPanel(
            contentRect: NSRect(origin: .zero, size: initialPanelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Above normal app windows (including a maximized Chrome) so the
        // buttons are always reachable. The cursor overlay sits even higher
        // but is click-through, so clicks still land on these buttons.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = hostingView

        firstTimerPanel = panel
        firstTimerPanelHostingView = hostingView
    }

    private var currentPanelLayout: FirstTimerPanelLayout {
        if firstTimerModeController.isFirstTimerPanelCollapsed {
            return .collapsedPill
        }
        if firstTimerModeController.shouldShowSimpleGuidanceHelperBar {
            return .simpleGuidanceHelperBox
        }
        return .onboardingQuestions
    }

    private func resizeAndRepositionPanelToFitContent() {
        guard let firstTimerPanel, let firstTimerPanelHostingView else { return }

        let contentFittingSize = firstTimerPanelHostingView.fittingSize
        let panelLayoutNow = currentPanelLayout

        // Switching between the onboarding questions and the helper box is a
        // new arrangement, so go back to its default spot. Hiding to the pill
        // and showing again keeps wherever the user dragged it.
        let isSwitchingBetweenQuestionsAndHelperBox =
            (panelLayoutAtLastPositioning == .onboardingQuestions && panelLayoutNow == .simpleGuidanceHelperBox)
            || (panelLayoutAtLastPositioning == .simpleGuidanceHelperBox && panelLayoutNow == .onboardingQuestions)
        if isSwitchingBetweenQuestionsAndHelperBox {
            hasUserDraggedPanelToCustomPosition = false
        }
        panelLayoutAtLastPositioning = panelLayoutNow

        // Prefer the screen the panel is on (or the mouse is on, the first time).
        let referencePointForChoosingScreen = firstTimerPanel.isVisible
            ? CGPoint(x: firstTimerPanel.frame.midX, y: firstTimerPanel.frame.midY)
            : NSEvent.mouseLocation
        let screenForPanel = NSScreen.screens.first(where: { $0.frame.contains(referencePointForChoosingScreen) }) ?? NSScreen.main
        guard let targetScreen = screenForPanel else { return }
        let usableScreenFrame = targetScreen.visibleFrame

        var panelOriginX: CGFloat
        var panelOriginY: CGFloat

        if hasUserDraggedPanelToCustomPosition {
            // Keep the bottom-left corner where the user left it.
            panelOriginX = firstTimerPanel.frame.origin.x
            panelOriginY = firstTimerPanel.frame.origin.y
        } else {
            panelOriginY = usableScreenFrame.minY + distanceAboveBottomOfScreen
            switch panelLayoutNow {
            case .onboardingQuestions:
                // The questions sit in the middle where they're impossible to miss.
                panelOriginX = usableScreenFrame.midX - (contentFittingSize.width / 2)
            case .simpleGuidanceHelperBox, .collapsedPill:
                // The helper box sits in the bottom-right corner, out of the
                // way of the website or app the user is being guided through.
                panelOriginX = usableScreenFrame.maxX - contentFittingSize.width - distanceFromRightEdgeOfScreen
            }
        }

        // Never let the panel end up partly off screen.
        panelOriginX = min(max(panelOriginX, usableScreenFrame.minX), usableScreenFrame.maxX - contentFittingSize.width)
        panelOriginY = min(max(panelOriginY, usableScreenFrame.minY), usableScreenFrame.maxY - contentFittingSize.height)

        firstTimerPanel.setFrame(
            NSRect(x: panelOriginX, y: panelOriginY, width: contentFittingSize.width, height: contentFittingSize.height),
            display: true
        )
    }
}

// MARK: - Panel Content

struct FirstTimerPanelView: View {
    @ObservedObject var firstTimerModeController: FirstTimerModeController

    /// Tells the window manager the user moved the panel, so it stops
    /// snapping back to the default position.
    let onUserStartedDraggingPanel: () -> Void

    private let onboardingQuestionsPanelWidth: CGFloat = 640
    private let simpleGuidanceHelperBoxWidth: CGFloat = 500

    var body: some View {
        if firstTimerModeController.isFirstTimerPanelCollapsed {
            collapsedShowHelperPill
        } else if firstTimerModeController.shouldShowSimpleGuidanceHelperBar {
            simpleGuidanceHelperBox
        } else {
            onboardingQuestionsPanel
        }
    }

    // MARK: Move / Hide Row

    /// The top row on both the questions panel and the helper box: a drag
    /// handle on the left and a Hide button on the right.
    private var moveAndHideControlsRow: some View {
        HStack {
            FirstTimerPanelDragHandle(onUserStartedDraggingPanel: onUserStartedDraggingPanel)

            Spacer()

            FirstTimerSmallControlButton(buttonTitle: "Hide", buttonSymbolName: "chevron.down") {
                firstTimerModeController.collapseFirstTimerPanel()
            }
        }
    }

    /// Small link at the bottom of the panel to turn the whole mode off.
    private var turnOffFirstTimerModeLink: some View {
        FirstTimerSmallControlButton(buttonTitle: "Turn off First-Timer Mode", buttonSymbolName: "power") {
            firstTimerModeController.userPressedTurnOffFirstTimerModeLink()
        }
    }

    // MARK: Collapsed Pill

    /// What's left on screen after pressing Hide: a small pill the user can
    /// click to bring the full panel back. It can be dragged too.
    private var collapsedShowHelperPill: some View {
        HStack(spacing: 6) {
            FirstTimerPanelDragHandle(onUserStartedDraggingPanel: onUserStartedDraggingPanel, showsMoveLabel: false)

            FirstTimerSmallControlButton(buttonTitle: "Show Clicky helper", buttonSymbolName: "chevron.up", usesLargerText: true) {
                firstTimerModeController.expandFirstTimerPanel()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(firstTimerPanelBackground)
    }

    // MARK: Onboarding Questions

    private var onboardingQuestionsPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            moveAndHideControlsRow

            Text(firstTimerModeController.largeOnScreenHeadline)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if !firstTimerModeController.largeOnScreenInstruction.isEmpty {
                Text(firstTimerModeController.largeOnScreenInstruction)
                    .font(.system(size: 21, weight: .medium, design: .rounded))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch firstTimerModeController.onboardingStep {
            case .askingAge:
                FirstTimerSecondaryTextButton(buttonTitle: "Skip this question") {
                    firstTimerModeController.skipAgeQuestion()
                }

            case .askingComputerComfortLevel:
                VStack(spacing: 10) {
                    ForEach(ComputerComfortLevel.allCases) { comfortLevel in
                        ComputerComfortLevelChoiceButton(comfortLevel: comfortLevel) {
                            firstTimerModeController.selectComputerComfortLevel(comfortLevel)
                        }
                    }
                }

            case .showingWelcomeDemo:
                FirstTimerSecondaryTextButton(buttonTitle: "Skip") {
                    firstTimerModeController.userPressedSkipWelcomeDemoButton()
                }

            case .finishedAndProfileSaved:
                FirstTimerSecondaryTextButton(buttonTitle: "Close") {
                    firstTimerModeController.hideFirstTimerPanel()
                }

            case .notRunning:
                EmptyView()
            }

            turnOffFirstTimerModeLink
        }
        .padding(.horizontal, 30)
        .padding(.top, 16)
        .padding(.bottom, 22)
        .frame(width: onboardingQuestionsPanelWidth, alignment: .leading)
        .background(firstTimerPanelBackground)
    }

    // MARK: Simple Guidance Helper Box (levels 1 and 2)

    /// Stays on screen while a level 1 or 2 user is being guided. Shows the
    /// step Clicky just spoke in large text, plus the two big buttons.
    private var simpleGuidanceHelperBox: some View {
        VStack(alignment: .leading, spacing: 14) {
            moveAndHideControlsRow

            Text(firstTimerModeController.largeOnScreenHeadline)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if !firstTimerModeController.largeOnScreenInstruction.isEmpty {
                Text(firstTimerModeController.largeOnScreenInstruction)
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                FirstTimerBigActionButton(
                    buttonTitle: "I did it",
                    buttonSymbolName: "checkmark.circle.fill",
                    buttonFillColor: Color(hex: "#1F9D61"),
                    buttonHoverFillColor: Color(hex: "#23B06C")
                ) {
                    firstTimerModeController.userPressedIDidItButton()
                }

                FirstTimerBigActionButton(
                    buttonTitle: "I'm lost",
                    buttonSymbolName: "questionmark.circle.fill",
                    buttonFillColor: Color(hex: "#C9631A"),
                    buttonHoverFillColor: Color(hex: "#DB6E1E")
                ) {
                    firstTimerModeController.userPressedImLostButton()
                }
            }

            Text("To talk to me: hold the Control and Option keys, speak, then let go.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            turnOffFirstTimerModeLink
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 18)
        .frame(width: simpleGuidanceHelperBoxWidth, alignment: .leading)
        .background(firstTimerPanelBackground)
    }

    private var firstTimerPanelBackground: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(DS.Colors.background.opacity(0.97))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(DS.Colors.overlayCursorBlue.opacity(0.6), lineWidth: 2)
            )
    }
}

// MARK: - Drag Handle

/// A "Move" grip the user can drag to put the panel anywhere. The visible
/// part is SwiftUI; an invisible AppKit view on top catches the mouse-down
/// and hands it to the window to drag, because SwiftUI alone can't move a
/// borderless NSPanel on macOS 14.
private struct FirstTimerPanelDragHandle: View {
    let onUserStartedDraggingPanel: () -> Void
    var showsMoveLabel: Bool = true

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 14, weight: .semibold))
            if showsMoveLabel {
                Text("Move")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
            }
        }
        .foregroundColor(DS.Colors.textTertiary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(DS.Colors.surface2)
        )
        .overlay(
            WindowDragCatcher(onDragStarted: onUserStartedDraggingPanel)
        )
    }
}

/// Invisible AppKit view that starts a window drag on mouse-down and shows
/// an open-hand cursor so it reads as "grab me".
private struct WindowDragCatcher: NSViewRepresentable {
    let onDragStarted: () -> Void

    func makeNSView(context: Context) -> WindowDragCatcherView {
        let dragCatcherView = WindowDragCatcherView()
        dragCatcherView.onDragStarted = onDragStarted
        return dragCatcherView
    }

    func updateNSView(_ nsView: WindowDragCatcherView, context: Context) {
        nsView.onDragStarted = onDragStarted
    }
}

private class WindowDragCatcherView: NSView {
    var onDragStarted: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onDragStarted?()
        window?.performDrag(with: event)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}

// MARK: - Buttons

/// One big row for a comfort level: a large number on the left and the
/// plain-language description on the right. The whole row is clickable.
private struct ComputerComfortLevelChoiceButton: View {
    let comfortLevel: ComputerComfortLevel
    let onChooseComfortLevel: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onChooseComfortLevel) {
            HStack(alignment: .center, spacing: 18) {
                Text("\(comfortLevel.rawValue)")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(DS.Colors.overlayCursorBlue))

                Text(comfortLevel.plainLanguageDescription)
                    .font(.system(size: 19, weight: .medium, design: .rounded))
                    .foregroundColor(DS.Colors.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isHovered ? DS.Colors.surface3 : DS.Colors.surface1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isHovered ? DS.Colors.overlayCursorBlue : DS.Colors.borderSubtle, lineWidth: 2)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHoveringNow in
            isHovered = isHoveringNow
        }
        .pointerCursor()
    }
}

/// A plain, medium-sized text button for less important actions like
/// "Skip this question" or "Close".
private struct FirstTimerSecondaryTextButton: View {
    let buttonTitle: String
    let onPress: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onPress) {
            Text(buttonTitle)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundColor(isHovered ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isHovered ? DS.Colors.surface3 : DS.Colors.surface2)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHoveringNow in
            isHovered = isHoveringNow
        }
        .pointerCursor()
    }
}

/// A small icon + text button for panel controls like "Hide" and
/// "Turn off First-Timer Mode". Brightens on hover so it reads as clickable.
private struct FirstTimerSmallControlButton: View {
    let buttonTitle: String
    let buttonSymbolName: String
    var usesLargerText: Bool = false
    let onPress: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onPress) {
            HStack(spacing: 6) {
                Image(systemName: buttonSymbolName)
                    .font(.system(size: usesLargerText ? 15 : 13, weight: .semibold))
                Text(buttonTitle)
                    .font(.system(size: usesLargerText ? 17 : 14, weight: .semibold, design: .rounded))
            }
            .foregroundColor(isHovered ? DS.Colors.textPrimary : DS.Colors.textTertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? DS.Colors.surface3 : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHoveringNow in
            isHovered = isHoveringNow
        }
        .pointerCursor()
    }
}

/// A large, colourful button with an icon and a word, used for the helper
/// box's "I did it" and "I'm lost". Big enough to hit easily, with a clear
/// colour change on hover so it obviously reads as clickable.
private struct FirstTimerBigActionButton: View {
    let buttonTitle: String
    let buttonSymbolName: String
    let buttonFillColor: Color
    let buttonHoverFillColor: Color
    let onPress: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onPress) {
            HStack(spacing: 10) {
                Image(systemName: buttonSymbolName)
                    .font(.system(size: 24, weight: .semibold))
                Text(buttonTitle)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isHovered ? buttonHoverFillColor : buttonFillColor)
            )
            .scaleEffect(isHovered ? 1.03 : 1.0)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHoveringNow in
            isHovered = isHoveringNow
        }
        .pointerCursor()
    }
}
