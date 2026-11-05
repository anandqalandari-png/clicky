//
//  FirstTimerModeController.swift
//  leanring-buddy
//
//  Runs First-Timer Mode: a mode for people who are not comfortable with
//  computers. When it starts, Clicky asks two questions out loud (and in
//  large text on screen): the user's age, and how comfortable they are with
//  computers on a 1 to 5 scale. The answers are saved as a persistent
//  profile (see FirstTimerProfile.swift).
//
//  The user can answer by voice (push-to-talk) or, for the comfort level,
//  by clicking one of the big numbered buttons in FirstTimerPanelView.
//
//  CompanionManager owns this controller. While the onboarding questions
//  are being asked, CompanionManager hands every finished voice transcript
//  here first instead of sending it to Claude.
//
//  After onboarding, users at level 1 or 2 get "simple step-by-step
//  guidance": a plain-language system prompt for Claude (built here), a
//  helper bar with big "I did it" and "I'm lost" buttons, and the current
//  step shown in large text. Levels 3 to 5 use Clicky's normal behavior.
//

import AppKit
import Combine
import Foundation

/// Where the user is in the First-Timer onboarding questions.
enum FirstTimerOnboardingStep: Equatable {
    /// No questions are being asked right now.
    case notRunning
    /// Waiting for the user to say their age.
    case askingAge
    /// Waiting for the user to pick a comfort level from 1 to 5.
    case askingComputerComfortLevel
    /// A brand-new level 1 user is watching the short welcome demo, where
    /// Clicky points at one friendly thing to show how it helps.
    case showingWelcomeDemo
    /// Both questions answered by a level 3 to 5 user; the panel shows a
    /// short confirmation with a Close button.
    case finishedAndProfileSaved
}

@MainActor
final class FirstTimerModeController: ObservableObject {
    @Published private(set) var onboardingStep: FirstTimerOnboardingStep = .notRunning
    @Published private(set) var savedUserProfile: FirstTimerUserProfile? = FirstTimerProfileStore.loadSavedProfile()

    /// Large headline text shown in the First-Timer panel (for example the
    /// question currently being asked, or the step Clicky just spoke).
    @Published private(set) var largeOnScreenHeadline: String = ""

    /// Smaller instruction text under the headline (for example how to answer).
    @Published private(set) var largeOnScreenInstruction: String = ""

    /// Whether the big First-Timer panel should be on screen.
    @Published private(set) var isFirstTimerPanelVisible: Bool = false

    /// When true, the panel is shrunk to a small "Show helper" pill so it
    /// doesn't cover what's behind it. Clicking the pill brings it back.
    @Published private(set) var isFirstTimerPanelCollapsed: Bool = false

    /// The age the user gave, held until they also answer the comfort question.
    private var ageInYearsAnsweredDuringOnboarding: Int?

    /// How many times in a row we couldn't understand the spoken age. After
    /// two misses we move on so the user never gets stuck on this question.
    private var numberOfAgeAnswersWeCouldNotUnderstand = 0

    /// Speaks text aloud with Clicky's voice. Supplied by CompanionManager so
    /// this controller reuses the existing ElevenLabs voice pipeline.
    private let speakTextAloud: (String) -> Void

    /// Sends a request to Claude (with a fresh screenshot) exactly as if the
    /// user had said it with push-to-talk. Used by the big helper buttons.
    private let sendUserRequestToClaude: (String) -> Void

    /// Turns First-Timer Mode off through CompanionManager, which also stops
    /// any speech in progress. Used by the panel's "Turn off" link.
    private let requestToTurnOffFirstTimerMode: () -> Void

    /// Starts the welcome demo in CompanionManager, which owns the screenshot,
    /// Claude, voice, and arrow needed to run it.
    private let requestToStartWelcomeDemo: () -> Void

    /// Stops the welcome demo early (the "Skip" button).
    private let requestToStopWelcomeDemo: () -> Void

    init(
        speakTextAloud: @escaping (String) -> Void,
        sendUserRequestToClaude: @escaping (String) -> Void,
        requestToTurnOffFirstTimerMode: @escaping () -> Void,
        requestToStartWelcomeDemo: @escaping () -> Void,
        requestToStopWelcomeDemo: @escaping () -> Void
    ) {
        self.speakTextAloud = speakTextAloud
        self.sendUserRequestToClaude = sendUserRequestToClaude
        self.requestToTurnOffFirstTimerMode = requestToTurnOffFirstTimerMode
        self.requestToStartWelcomeDemo = requestToStartWelcomeDemo
        self.requestToStopWelcomeDemo = requestToStopWelcomeDemo

        // A returning level 1 or 2 user sees the helper bar right away.
        if savedUserProfile?.needsSimpleStepByStepGuidance == true {
            showHelperBarWaitingForFirstRequest()
        }
    }

    // MARK: - State Questions

    /// True while Clicky is waiting for an answer to one of the onboarding
    /// questions. CompanionManager uses this to route voice transcripts here.
    var isWaitingForOnboardingAnswer: Bool {
        return onboardingStep == .askingAge || onboardingStep == .askingComputerComfortLevel
    }

    /// True when a saved profile says the user is level 1 or 2, meaning the
    /// simple one-step-at-a-time guidance should be used.
    var isSimpleStepByStepGuidanceActive: Bool {
        return savedUserProfile?.needsSimpleStepByStepGuidance ?? false
    }

    /// True when the helper bar (with "I did it" / "I'm lost") should be shown
    /// instead of the onboarding questions.
    var shouldShowSimpleGuidanceHelperBar: Bool {
        return onboardingStep == .notRunning && isSimpleStepByStepGuidanceActive
    }

    // MARK: - Starting and Stopping

    /// Starts (or restarts) the First-Timer onboarding questions from the top.
    func startFirstTimerOnboarding() {
        currentGoalTheUserAskedFor = nil
        isFirstTimerPanelCollapsed = false
        ageInYearsAnsweredDuringOnboarding = nil
        numberOfAgeAnswersWeCouldNotUnderstand = 0
        isFirstTimerPanelVisible = true
        askAgeQuestion()
    }

    /// Turns First-Timer Mode off completely and forgets the saved profile,
    /// so Clicky goes back to its normal behavior.
    func turnOffFirstTimerMode() {
        FirstTimerProfileStore.clearSavedProfile()
        savedUserProfile = nil
        currentGoalTheUserAskedFor = nil
        onboardingStep = .notRunning
        isFirstTimerPanelVisible = false
        largeOnScreenHeadline = ""
        largeOnScreenInstruction = ""
    }

    /// Shrinks the panel to a small pill so the user can see what's behind it.
    func collapseFirstTimerPanel() {
        isFirstTimerPanelCollapsed = true
    }

    /// Brings the full panel back from the small pill.
    func expandFirstTimerPanel() {
        isFirstTimerPanelCollapsed = false
    }

    /// Called by the panel's "Turn off First-Timer Mode" link.
    func userPressedTurnOffFirstTimerModeLink() {
        requestToTurnOffFirstTimerMode()
    }

    /// Hides the confirmation panel shown to level 3 to 5 users.
    func hideFirstTimerPanel() {
        isFirstTimerPanelVisible = false
        if onboardingStep == .finishedAndProfileSaved {
            onboardingStep = .notRunning
        }
    }

    // MARK: - Question 1: Age

    private func askAgeQuestion() {
        onboardingStep = .askingAge
        largeOnScreenHeadline = "How old are you?"
        largeOnScreenInstruction = "Hold down the Control and Option keys, say your age, then let go."

        speakTextAloud(
            "Hello! I'm Clicky. I'm here to help you use your computer, one small step at a time. "
            + "First, how old are you? Hold down the Control and Option keys together, say your age, and then let go."
        )
    }

    /// Called by the "Skip this question" button on the age screen.
    func skipAgeQuestion() {
        guard onboardingStep == .askingAge else { return }
        ageInYearsAnsweredDuringOnboarding = nil
        askComputerComfortLevelQuestion(introductionBeforeQuestion: "That's okay.")
    }

    private func handleSpokenAgeAnswer(_ spokenTranscript: String) {
        if let understoodAgeInYears = Self.parseAgeInYears(from: spokenTranscript) {
            ageInYearsAnsweredDuringOnboarding = understoodAgeInYears
            askComputerComfortLevelQuestion(introductionBeforeQuestion: "Thank you.")
            return
        }

        numberOfAgeAnswersWeCouldNotUnderstand += 1

        if numberOfAgeAnswersWeCouldNotUnderstand >= 2 {
            // Don't trap the user on this question — age is only context.
            ageInYearsAnsweredDuringOnboarding = nil
            askComputerComfortLevelQuestion(introductionBeforeQuestion: "No problem, let's keep going.")
            return
        }

        largeOnScreenInstruction = "Sorry, I didn't catch that. Hold Control and Option, and say a number, like \"sixty two\"."
        speakTextAloud("Sorry, I didn't quite catch that. Please hold the Control and Option keys again and say your age as a number, like sixty two.")
    }

    // MARK: - Question 2: Computer Comfort Level

    private func askComputerComfortLevelQuestion(introductionBeforeQuestion: String) {
        onboardingStep = .askingComputerComfortLevel
        largeOnScreenHeadline = "How comfortable are you with computers?"
        largeOnScreenInstruction = "Click the number that sounds most like you. Or hold Control and Option and say the number."

        let spokenLevelExplanations = ComputerComfortLevel.allCases.map { comfortLevel in
            "\(Self.spokenWordForNumber(comfortLevel.rawValue)) means: \(comfortLevel.plainLanguageDescription)"
        }.joined(separator: " ")

        speakTextAloud(
            "\(introductionBeforeQuestion) Next question. On a scale of one to five, how comfortable are you with computers? "
            + spokenLevelExplanations
            + " You can click a number on the screen, or hold Control and Option and say the number."
        )
    }

    /// Called when the user clicks one of the big numbered buttons, or when a
    /// spoken answer was understood.
    func selectComputerComfortLevel(_ selectedComfortLevel: ComputerComfortLevel) {
        guard onboardingStep == .askingComputerComfortLevel else { return }

        let completedProfile = FirstTimerUserProfile(
            ageInYears: ageInYearsAnsweredDuringOnboarding,
            computerComfortLevel: selectedComfortLevel
        )
        FirstTimerProfileStore.saveProfile(completedProfile)
        savedUserProfile = completedProfile
        print("👵 First-Timer profile saved — age: \(completedProfile.ageInYears.map(String.init) ?? "skipped"), level: \(selectedComfortLevel.rawValue)")

        if selectedComfortLevel == .usesComputerForBasicsOnly {
            // Brand-new level 1 users first watch a short demo of Clicky
            // pointing at something, so they see how it works and trust it.
            onboardingStep = .showingWelcomeDemo
            largeOnScreenHeadline = "Watch my blue arrow."
            largeOnScreenInstruction = "I'm going to show you how I point at things on your screen."
            requestToStartWelcomeDemo()
        } else if selectedComfortLevel.needsSimpleStepByStepGuidance {
            // Level 1 and 2 users keep the panel as a helper bar with the
            // big "I did it" and "I'm lost" buttons.
            onboardingStep = .notRunning
            largeOnScreenHeadline = "You're all set."
            largeOnScreenInstruction = "Hold Control and Option, and tell me what you'd like to do."
            speakTextAloud(
                "Thank you. I'll keep everything simple, and we'll go one small step at a time. "
                + "Whenever you need help, hold Control and Option and tell me what you want to do. "
                + "If you ever feel lost, press the I'm lost button, and I'll explain it again."
            )
        } else {
            onboardingStep = .finishedAndProfileSaved
            largeOnScreenHeadline = "You're all set."
            largeOnScreenInstruction = "Hold Control and Option any time to ask me something."
            speakTextAloud("Great, you're all set. Hold Control and Option any time you want to ask me something.")
        }
    }

    // MARK: - Welcome Demo (brand-new level 1 users)

    /// Spoken before the arrow moves.
    static let welcomeDemoIntroductionLine =
        "Thank you. Before we start, let me show you what I can do. "
        + "I can see your screen, and I can point at things with my blue arrow. Watch."

    /// Spoken after the arrow has pointed at something.
    static let welcomeDemoClosingLine =
        "See? That's how I'll help you. I'll point at one thing at a time, and tell you what to do. "
        + "You do the clicking, and I'll be right here with you. "
        + "Whenever you're ready, hold Control and Option, and tell me what you'd like to do. "
        + "And if you ever feel lost, press the I'm lost button."

    /// Shown while the arrow is pointing, so the text matches what's spoken.
    func showWelcomeDemoPointingText(_ spokenDemoLine: String) {
        guard onboardingStep == .showingWelcomeDemo else { return }
        largeOnScreenHeadline = spokenDemoLine
        largeOnScreenInstruction = "That's how I'll show you where to click."
    }

    /// Called by the "Skip" button during the welcome demo.
    func userPressedSkipWelcomeDemoButton() {
        requestToStopWelcomeDemo()
        finishWelcomeDemo()
    }

    /// Moves from the demo to the helper box. Safe to call more than once.
    func finishWelcomeDemo() {
        guard onboardingStep == .showingWelcomeDemo else { return }
        onboardingStep = .notRunning
        largeOnScreenHeadline = "You're all set."
        largeOnScreenInstruction = "Hold Control and Option, and tell me what you'd like to do."
    }

    private func handleSpokenComputerComfortLevelAnswer(_ spokenTranscript: String) {
        if let understoodComfortLevelNumber = Self.parseComputerComfortLevelNumber(from: spokenTranscript),
           let understoodComfortLevel = ComputerComfortLevel(rawValue: understoodComfortLevelNumber) {
            selectComputerComfortLevel(understoodComfortLevel)
            return
        }

        largeOnScreenInstruction = "Sorry, I didn't catch that. Click a number below, or say a number from one to five."
        speakTextAloud("Sorry, I didn't catch that. You can click one of the numbers on the screen, or say a number from one to five.")
    }

    // MARK: - Helper Bar (levels 1 and 2)

    /// The phrase the "I'm lost" button sends. CompanionManager recognizes it
    /// (and spoken versions like "I'm confused") and asks Claude to re-explain
    /// the last step much more simply.
    static let imLostButtonRequestPhrase = "I'm lost."

    /// The phrase the "I did it" button sends, so Claude checks the screen and
    /// gives the next single step.
    static let iDidItButtonRequestPhrase = "Yes, I did it. What do I do next?"

    private func showHelperBarWaitingForFirstRequest() {
        onboardingStep = .notRunning
        isFirstTimerPanelVisible = true
        largeOnScreenHeadline = "Hi! I'm here to help."
        largeOnScreenInstruction = "Hold Control and Option, and tell me what you'd like to do."
    }

    func userPressedIDidItButton() {
        showWaitingForClaudeOnScreen()
        sendUserRequestToClaude(Self.iDidItButtonRequestPhrase)
    }

    func userPressedImLostButton() {
        showWaitingForClaudeOnScreen()
        sendUserRequestToClaude(Self.imLostButtonRequestPhrase)
    }

    /// Shown while a request is on its way to Claude, so the user knows
    /// their press or question was heard.
    func showWaitingForClaudeOnScreen() {
        guard shouldShowSimpleGuidanceHelperBar else { return }
        largeOnScreenHeadline = "One moment…"
        largeOnScreenInstruction = "I'm looking at your screen."
    }

    /// Shows the step Clicky just spoke in large text, so the user can read
    /// it as well as hear it.
    func showLatestSpokenStepOnScreen(
        _ latestSpokenStepText: String,
        isPointingAtSomething: Bool = true,
        isPointingAtFinalButton: Bool = false
    ) {
        guard shouldShowSimpleGuidanceHelperBar else { return }
        largeOnScreenHeadline = latestSpokenStepText

        if isPointingAtFinalButton {
            largeOnScreenInstruction = "⚠️ This is a final button. Only you decide when to press it. Check everything carefully first."
        } else if isPointingAtSomething {
            largeOnScreenInstruction = "When you've done it, press \"I did it\". If you're not sure, press \"I'm lost\"."
        } else {
            // No arrow means Clicky asked a question or just explained something.
            largeOnScreenInstruction = "To answer me, hold the Control and Option keys, speak, then let go."
        }
    }

    /// Recognizes "I'm lost" style requests, whether spoken or from the button.
    static func isAskingToReExplainLastStep(_ userRequestText: String) -> Bool {
        let lowercasedUserRequest = userRequestText.lowercased()
        let confusionPhrases = [
            "i'm lost", "i am lost", "im lost",
            "i'm confused", "i am confused", "im confused",
            "i don't understand", "i dont understand", "i do not understand",
            "i don't get it", "i dont get it",
            "what do you mean", "say that again", "explain again", "can you repeat"
        ]
        return confusionPhrases.contains { confusionPhrase in
            lowercasedUserRequest.contains(confusionPhrase)
        }
    }

    /// Builds the request sent to Claude when the user is lost: re-explain the
    /// last step much more simply, as if to a child.
    static func buildRequestToReExplainLastStep(lastStepClickySpoke: String?) -> String {
        var reExplainRequest = "I'm lost. Please explain your last step again, much more simply, as if you were talking to a child. "
            + "Use very short, easy words. Tell me exactly where the thing is on my screen using its colour, its shape, "
            + "and whether it's at the top, bottom, left, or right. Point at it again. Still give only that one step."
        if let lastStepClickySpoke, !lastStepClickySpoke.isEmpty {
            reExplainRequest += " Your last step was: \"\(lastStepClickySpoke)\""
        }
        return reExplainRequest
    }

    // MARK: - The User's Current Goal

    /// What the user is trying to do right now, for example "how do I open
    /// Chrome". Sent to Claude with every request so short follow-ups like
    /// "I did it" or "I'm lost" stay focused on the same task.
    private(set) var currentGoalTheUserAskedFor: String?

    /// Remembers the request as the user's goal, unless it's just a follow-up
    /// like "yes", "I did it", or "I'm lost".
    func rememberGoalIfThisIsANewRequest(_ userRequestText: String) {
        guard !Self.isAskingToReExplainLastStep(userRequestText) else { return }
        guard !Self.isShortFollowUpConfirmation(userRequestText) else { return }
        currentGoalTheUserAskedFor = userRequestText
        print("🎯 First-Timer goal: \(userRequestText)")
    }

    /// Short answers like "yes", "done", "okay I did it", "no" — replies to
    /// Clicky's last step, not a new task.
    static func isShortFollowUpConfirmation(_ userRequestText: String) -> Bool {
        if userRequestText == iDidItButtonRequestPhrase {
            return true
        }

        let lowercasedWords = splitTranscriptIntoLowercaseWords(userRequestText)

        guard lowercasedWords.count <= 6 else { return false }

        let confirmationWords: Set<String> = [
            "yes", "yeah", "yep", "yup", "done", "did", "ok", "okay", "ready",
            "next", "sure", "no", "nope", "not", "clicked", "finished", "alright"
        ]
        return lowercasedWords.contains { spokenWord in
            confirmationWords.contains(spokenWord)
        }
    }

    private var currentGoalSentenceForClaude: String {
        if let currentGoalTheUserAskedFor {
            return "their goal right now, in their own words: \"\(currentGoalTheUserAskedFor)\""
        }
        return "they haven't said what they want to do yet. if their message isn't clear, gently ask what they'd like to do."
    }

    // MARK: - Tax Filing Playbook (India demo)

    /// True when the user's goal is about filing taxes, for example
    /// "help me file my taxes" or "I need to do my ITR".
    var isCurrentGoalAboutFilingTaxes: Bool {
        guard let currentGoalTheUserAskedFor else { return false }
        let goalWords = Self.splitTranscriptIntoLowercaseWords(currentGoalTheUserAskedFor)
        return goalWords.contains { goalWord in
            goalWord.hasPrefix("tax") || goalWord == "itr"
        }
    }

    /// Extra instructions for the showcase flow: helping a first-timer in
    /// India file an income tax return. First ask a few simple questions one
    /// at a time, then guide them to the official website and explain the
    /// boxes that matter. Clicky never fills anything in or submits anything.
    private var taxFilingPlaybookIfTheGoalIsAboutTaxes: String {
        guard isCurrentGoalAboutFilingTaxes else { return "" }

        return """

        their goal is filing their income tax. follow this playbook, still one small step per reply.

        part one — a few simple questions, before any clicking. ask them one at a time, one question per reply, \
        and wait for each answer. be warm and reassuring, for example "don't worry, we'll do this together, slowly." \
        don't point at anything while asking these (use [POINT:none]).
        1. which country: say "i'm guessing you're in india, is that right?"
        2. what kind of work they do: a salary from a job, their own business or shop, a pension, or something else.
        3. roughly how much they earn in a year. tell them a rough number is completely fine and they don't need to be exact.
        4. if they get a salary or pension: do they have a paper called form sixteen from their employer or bank? it's fine if they don't know.
        never ask for their PAN, aadhaar, bank account, or password, not even to "check".
        then, in one or two plain sentences, tell them which form fits and why: \
        a salary or pension, with income up to fifty lakh rupees a year and at most one house, usually means ITR one, also called "sahaj". \
        a small business or shop usually means ITR four, called "sugam". anything more complicated: say the website will help pick, \
        and it's a good idea to ask a tax helper or chartered accountant. \
        then reassure them: "we'll go slowly, and nothing gets sent until you decide." then start part two.

        part two — guiding them, one step per reply, pointing at each thing:
        - open chrome (use the facts about their mac above; if chrome is already open, help them bring it to the front).
        - click the long white bar at the very top where the website address goes, type incometax.gov.in, and press the return key. \
        explain that this is the official income tax department website of the government of india.
        - on that website, the "login" button is near the top right.
        - the first box asks for their user id: explain "this box wants your PAN number. that's the ten letter-and-number code \
        on the card from the income tax department." tell them to type it in themselves, and not to say it out loud.
        - the password box: they type their password themselves. never ask for it. if they've forgotten it, the website has a "forgot password" link.
        - after they log in: point at the "e-file" menu near the top, then "income tax returns", then "file income tax return". \
        for the year, pick the one the website already suggests. choose "online" if asked.
        - from then on, when they reach each important box, explain it in plain words, for example: \
        gross salary is your total pay before anything is cut, and it's written on your form sixteen. \
        TDS means tax that was already taken out of your pay by your employer. \
        deductions like 80C are money you put in things like PPF or life insurance, which can lower your tax.
        - if anything on the website asks for something they don't have, reassure them it's okay to stop and come back later.
        - you never press submit, pay, confirm, or e-verify for them. when they reach a final button, tell them it's their decision, \
        to check everything carefully, and that it's a good idea to have a family member or tax helper look it over first.
        """
    }

    // MARK: - Facts About This Mac

    /// Bundle identifier for Google Chrome, the browser the tax demo uses.
    private static let googleChromeBundleIdentifier = "com.google.Chrome"

    /// Facts Claude can't see in a screenshot but needs to give correct
    /// directions — most importantly whether the Dock is hidden. When the
    /// Dock auto-hides it's invisible in the screenshot, and Claude would
    /// otherwise keep saying "look at the bottom of your screen" at nothing.
    static func describeThisMacsSetupForClaude() -> String {
        // The Dock's own settings. Readable because Clicky isn't sandboxed.
        let dockPreferences = UserDefaults(suiteName: "com.apple.dock")
        let isDockSetToAutoHide = dockPreferences?.bool(forKey: "autohide") ?? false
        let dockScreenEdge = dockPreferences?.string(forKey: "orientation") ?? "bottom"

        let dockPinnedApps = dockPreferences?.array(forKey: "persistent-apps") as? [[String: Any]] ?? []
        let isChromePinnedInDock = dockPinnedApps.contains { dockTile in
            let dockTileData = dockTile["tile-data"] as? [String: Any]
            return (dockTileData?["bundle-identifier"] as? String) == googleChromeBundleIdentifier
        }

        let isChromeInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: googleChromeBundleIdentifier) != nil
        let isChromeAlreadyOpen = !NSRunningApplication.runningApplications(withBundleIdentifier: googleChromeBundleIdentifier).isEmpty

        var setupFacts: [String] = []

        if isDockSetToAutoHide {
            setupFacts.append(
                "the dock (the strip of app pictures) is set to hide itself, so it is NOT visible in the screenshot even though it exists. "
                + "it is on the \(dockScreenEdge) edge of the screen. it only slides into view when they move their mouse all the way to the very \(dockScreenEdge) edge and wait a moment. "
                + "so when they need the dock, first tell them to slowly move their mouse all the way to the very \(dockScreenEdge) edge of the screen until a strip of pictures slides into view, "
                + "and point at the middle of that edge. don't describe dock pictures as if they can already see them."
            )
        } else {
            setupFacts.append("the dock (the strip of app pictures) is always visible on the \(dockScreenEdge) edge of the screen.")
        }

        if isChromeInstalled {
            setupFacts.append("google chrome is installed.")
            setupFacts.append(isChromePinnedInDock ? "chrome has a picture in the dock." : "chrome is NOT in the dock.")
            setupFacts.append(isChromeAlreadyOpen ? "chrome is already open right now." : "chrome is not open right now.")
        } else {
            setupFacts.append("google chrome is NOT installed. safari, the blue compass, can be used instead.")
        }

        return setupFacts.joined(separator: " ")
    }

    // MARK: - Simple Guidance Prompt for Claude

    /// The system prompt used instead of Clicky's normal prompt for level 1
    /// and 2 users. Keeps the same [POINT:...] tag format so the existing
    /// pointing pipeline works unchanged.
    func buildSimpleGuidanceSystemPrompt() -> String {
        let comfortLevelNumber = savedUserProfile?.computerComfortLevel.rawValue ?? 1
        let comfortLevelDescription = savedUserProfile?.computerComfortLevel.plainLanguageDescription
            ?? ComputerComfortLevel.usesComputerForBasicsOnly.plainLanguageDescription
        let ageSentence: String
        if let ageInYears = savedUserProfile?.ageInYears {
            ageSentence = "they are \(ageInYears) years old."
        } else {
            ageSentence = "they didn't share their age."
        }

        return """
        you're clicky, a patient, kind helper sitting right next to someone who is not comfortable with computers. \
        you can see their screen and you have a blue arrow you can move to point at things. your reply is read aloud slowly.

        about this person: \(ageSentence) on a scale of one to five for computer comfort they said \(comfortLevelNumber), \
        which means: "\(comfortLevelDescription)" they may get nervous or overwhelmed by technical screens.

        about their mac (checked by the app, trust this over the screenshot): \(Self.describeThisMacsSetupForClaude())

        \(currentGoalSentenceForClaude)

        staying on track:
        - every step must move them toward their goal. never bring up other apps or windows you can see on screen \
        (for example code editors, chat apps, terminals, or settings) unless they are part of the goal.
        - when they say they're lost, do not jump to a different method or a different part of the screen. \
        repeat the same step in even simpler words. only try a different way if the same step clearly cannot work, and say so gently.
        - if a step needs something that is not visible in the screenshot (like a hidden dock), first tell them how to make it appear.
        - the screenshots never show clicky's own helper box or blue arrow, so don't mention them.

        how to help them:
        - give exactly one small step per reply. never two. if a task takes many steps, give only the very next one and then stop.
        - keep each reply to one or two short sentences. write for the ear: no lists, no markdown, no symbols, no emojis.
        - use plain, everyday words. never use technical words like url, browser, tab, navigate, field, input, dropdown, cursor, toggle, icon, menu bar, scroll, or login page.
        - instead, describe what the thing looks like and where it is, using colour, shape, and position. for example, \
        instead of "navigate to the url field", say "click the long white bar at the very top, where the website address goes."
        - if the thing you're talking about is on screen, always point at it.
        - end every step by asking them to tell you when it's done, for example: "did you click it? say yes, or press I did it, when you're ready."
        - when they say yes or that they did it, look at the new screenshot, check that it worked, and give the next single step. \
        if it didn't work, gently say what you see and help them try again.
        - be warm and encouraging. never make them feel slow. it's okay to say "you're doing great."
        - if they say they're lost or confused, explain the last step again even more simply, like you're talking to a child, and point at it again.
        - never ask them to say a password, a PAN number, an aadhaar number, or bank details out loud. tell them to type those in themselves.
        - you can never click, type, or fill anything in for them. you only point and explain. if they ask you to do it for them, \
        kindly say that they press the buttons themselves and you'll show them exactly where.
        - if their message contains "[PAN number hidden by Clicky]" or "[Aadhaar number hidden by Clicky]", the app hid a private number they said out loud. \
        gently tell them they never need to say it to you, and that they should type it in themselves when the time comes.
        - if you receive multiple screen images, the one labeled "primary focus" is where their mouse is.
        \(taxFilingPlaybookIfTheGoalIsAboutTaxes)

        pointing:
        point at only one thing per reply. append exactly one coordinate tag at the very end of your reply, after your spoken words. \
        the screenshot images are labeled with their pixel dimensions; use those as the coordinate space. \
        the origin (0,0) is the top-left corner. x increases to the right, y increases downward.

        format: [POINT:x,y:label] where label is a short one to three word name for the thing, like "chrome" or "address bar". \
        if the thing is on a different screen than the cursor, add :screenN, for example [POINT:400,300:address bar:screen2]. \
        if there's nothing useful to point at, append [POINT:none].

        example: "let's open chrome. it's the round picture with red, yellow, green and blue, down at the bottom of your screen. \
        click it once. did you click it? say yes, or press I did it, when you're ready. [POINT:640,880:chrome]"
        """
    }

    // MARK: - Voice Transcript Routing

    /// Gives a finished voice transcript to the onboarding questions.
    /// Returns true if the transcript was used here, meaning CompanionManager
    /// should NOT also send it to Claude.
    func handleSpokenTranscriptIfWaitingForOnboardingAnswer(_ spokenTranscript: String) -> Bool {
        switch onboardingStep {
        case .askingAge:
            handleSpokenAgeAnswer(spokenTranscript)
            return true
        case .askingComputerComfortLevel:
            handleSpokenComputerComfortLevelAnswer(spokenTranscript)
            return true
        case .notRunning, .finishedAndProfileSaved, .showingWelcomeDemo:
            return false
        }
    }

    // MARK: - Spoken Number Parsing

    private static let spokenOnesWordValues: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19
    ]

    private static let spokenTensWordValues: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90
    ]

    /// Lowercases the transcript and turns punctuation and hyphens into spaces,
    /// so "Sixty-two." becomes ["sixty", "two"].
    private static func splitTranscriptIntoLowercaseWords(_ spokenTranscript: String) -> [String] {
        let lowercasedTranscript = spokenTranscript.lowercased()
        let transcriptWithOnlyLettersAndDigits = lowercasedTranscript.map { character -> Character in
            return (character.isLetter || character.isNumber) ? character : " "
        }
        return String(transcriptWithOnlyLettersAndDigits)
            .split(separator: " ")
            .map(String.init)
    }

    /// Understands answers like "62", "I'm 62 years old", "sixty two", or
    /// "seventy". Returns nil if no believable age (5 to 120) is found.
    static func parseAgeInYears(from spokenTranscript: String) -> Int? {
        let spokenWords = splitTranscriptIntoLowercaseWords(spokenTranscript)

        // Digits are the most common: speech-to-text usually writes "62".
        for spokenWord in spokenWords {
            if let digitAge = Int(spokenWord), (5...120).contains(digitAge) {
                return digitAge
            }
        }

        // Otherwise look for number words like "sixty two" or "seventy".
        for (wordIndex, spokenWord) in spokenWords.enumerated() {
            if let tensValue = spokenTensWordValues[spokenWord] {
                var wordAge = tensValue
                let nextWordIndex = wordIndex + 1
                if nextWordIndex < spokenWords.count,
                   let onesValue = spokenOnesWordValues[spokenWords[nextWordIndex]],
                   onesValue >= 1 && onesValue <= 9 {
                    wordAge += onesValue
                }
                return wordAge
            }
            if let teenOrSmallValue = spokenOnesWordValues[spokenWord], (5...19).contains(teenOrSmallValue) {
                return teenOrSmallValue
            }
        }

        return nil
    }

    /// Understands answers like "1", "one", "level two", or "I'd say three".
    /// Returns a number from 1 to 5, or nil if none was found.
    static func parseComputerComfortLevelNumber(from spokenTranscript: String) -> Int? {
        let spokenWords = splitTranscriptIntoLowercaseWords(spokenTranscript)

        for spokenWord in spokenWords {
            if let digitLevel = Int(spokenWord), (1...5).contains(digitLevel) {
                return digitLevel
            }
        }

        let comfortLevelNumberWords: [String: Int] = [
            "one": 1, "two": 2, "three": 3, "four": 4, "five": 5
        ]
        for spokenWord in spokenWords {
            if let wordLevel = comfortLevelNumberWords[spokenWord] {
                return wordLevel
            }
        }

        // Speech-to-text sometimes hears a lone number as a sound-alike word.
        // Only trust these when the whole answer is very short, so a sentence
        // like "I'd like to say three" isn't read as "two".
        let soundAlikeNumberWords: [String: Int] = [
            "won": 1, "to": 2, "too": 2, "tree": 3, "for": 4, "fore": 4
        ]
        if spokenWords.count <= 2 {
            for spokenWord in spokenWords {
                if let soundAlikeLevel = soundAlikeNumberWords[spokenWord] {
                    return soundAlikeLevel
                }
            }
        }

        return nil
    }

    /// "1" → "One", used so the spoken explanation reads naturally.
    private static func spokenWordForNumber(_ number: Int) -> String {
        let capitalizedNumberWords = ["Zero", "One", "Two", "Three", "Four", "Five"]
        guard number >= 0 && number < capitalizedNumberWords.count else { return String(number) }
        return capitalizedNumberWords[number]
    }
}
