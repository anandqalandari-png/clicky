//
//  FirstTimerSafetyGuard.swift
//  leanring-buddy
//
//  Hard rules for First-Timer Mode that are enforced in code, not just asked
//  for in the prompt. Everything passes through here before Clicky acts, so
//  even if the model ignores its instructions, these rules still hold.
//
//  THE CORE RULE: First-Timer Mode only ever SPEAKS and POINTS.
//  It never clicks, types, fills in a form, or presses submit / pay /
//  confirm for the user — on any website, especially tax or government
//  sites. The human does every click and keystroke.
//
//  How that's guaranteed:
//  1. Clicky has no code that creates mouse clicks or key presses. Its only
//     keyboard hook is a listen-only event tap for push-to-talk
//     (GlobalPushToTalkShortcutMonitor), which can observe keys but can't
//     send them. Claude's reply can only ever become speech and an arrow.
//  2. FirstTimerAllowedAction below lists the only two things a reply may
//     turn into. Any other action-looking tag in Claude's reply (for example
//     [CLICK:...], [TYPE:...], [FILL:...], [SUBMIT]) is deleted here before
//     anything is spoken or shown, and logged.
//  3. Only ONE [POINT:...] tag is kept, so the arrow points at one thing at
//     a time.
//  4. When the arrow points at a final button (submit, pay, confirm,
//     e-verify...), a fixed warning is added that only the user decides
//     whether to press it. This text is hard-coded, not left to the model.
//  5. PAN and Aadhaar numbers spoken out loud are blanked out of the
//     transcript before it leaves the Mac.
//

import Foundation

/// The complete list of things a First-Timer reply is allowed to do.
/// There is deliberately no click, type, fill, or submit case.
enum FirstTimerAllowedAction {
    /// Say something out loud (and show it in large text).
    case speak
    /// Move the blue arrow to ONE thing on screen.
    case pointAtOneThing
}

/// Claude's reply after the safety rules have been applied.
struct FirstTimerSafeResponse {
    /// The reply text with at most one [POINT:...] tag at the end and every
    /// other action-looking tag removed.
    let responseTextWithAtMostOnePointTag: String
    /// Tags that were removed because they asked for something First-Timer
    /// Mode never does (for logging and debugging).
    let removedDisallowedActionTags: [String]
}

enum FirstTimerSafetyGuard {

    // MARK: - Reply Clean-Up

    /// Matches any [POINT:...] tag anywhere in the reply, including
    /// [POINT:none].
    private static let anyPointTagPattern = #"\[POINT:[^\]]*\]"#

    /// Matches tag-like instructions such as [CLICK:120,40], [TYPE:abc],
    /// [FILL:pan], [SUBMIT], [PRESS:return]. POINT tags are handled separately.
    private static let anyActionLookingTagPattern = #"\[(?!POINT:)[A-Z_]{2,}(?::[^\]]*)?\]"#

    /// Applies every reply rule: removes disallowed action tags and keeps
    /// only one arrow. This is the single entry point the response pipeline uses.
    static func makeClaudeResponseSafeForFirstTimerMode(_ claudeResponseText: String) -> FirstTimerSafeResponse {
        let (responseTextWithoutActionTags, removedDisallowedActionTags) = removeDisallowedActionTags(from: claudeResponseText)

        if !removedDisallowedActionTags.isEmpty {
            print("🛡️ First-Timer guard: removed tags First-Timer Mode never acts on: \(removedDisallowedActionTags)")
        }

        return FirstTimerSafeResponse(
            responseTextWithAtMostOnePointTag: keepOnlyOnePointTag(in: responseTextWithoutActionTags),
            removedDisallowedActionTags: removedDisallowedActionTags
        )
    }

    /// Removes any [SOMETHING:...] tag that isn't a POINT tag, so a reply can
    /// never smuggle in a "click", "type", or "submit" instruction — and so
    /// those tags are never read aloud either.
    private static func removeDisallowedActionTags(from claudeResponseText: String) -> (String, [String]) {
        guard let actionLookingTagRegex = try? NSRegularExpression(pattern: anyActionLookingTagPattern) else {
            return (claudeResponseText, [])
        }

        let fullResponseRange = NSRange(claudeResponseText.startIndex..., in: claudeResponseText)
        let removedTagStrings: [String] = actionLookingTagRegex
            .matches(in: claudeResponseText, range: fullResponseRange)
            .compactMap { actionTagMatch in
                guard let actionTagRange = Range(actionTagMatch.range, in: claudeResponseText) else { return nil }
                return String(claudeResponseText[actionTagRange])
            }

        let responseTextWithoutActionTags = actionLookingTagRegex.stringByReplacingMatches(
            in: claudeResponseText,
            range: fullResponseRange,
            withTemplate: ""
        )
        return (responseTextWithoutActionTags, removedTagStrings)
    }

    /// Returns the reply with at most one [POINT:...] tag, placed at the very
    /// end. Prefers the first tag that has real coordinates; falls back to
    /// [POINT:none] if that's all there is.
    static func keepOnlyOnePointTag(in claudeResponseText: String) -> String {
        guard let anyPointTagRegex = try? NSRegularExpression(pattern: anyPointTagPattern) else {
            return claudeResponseText
        }

        let fullResponseRange = NSRange(claudeResponseText.startIndex..., in: claudeResponseText)
        let allPointTagMatches = anyPointTagRegex.matches(in: claudeResponseText, range: fullResponseRange)

        guard !allPointTagMatches.isEmpty else {
            return claudeResponseText
        }

        let allPointTagStrings: [String] = allPointTagMatches.compactMap { pointTagMatch in
            guard let pointTagRange = Range(pointTagMatch.range, in: claudeResponseText) else { return nil }
            return String(claudeResponseText[pointTagRange])
        }

        let firstPointTagWithCoordinates = allPointTagStrings.first { pointTagString in
            return pointTagString.lowercased() != "[point:none]"
        }
        let singlePointTagToKeep = firstPointTagWithCoordinates ?? "[POINT:none]"

        if allPointTagStrings.count > 1 {
            print("🛡️ First-Timer guard: reply had \(allPointTagStrings.count) point tags — keeping only \(singlePointTagToKeep)")
        }

        let responseTextWithoutAnyPointTags = anyPointTagRegex.stringByReplacingMatches(
            in: claudeResponseText,
            range: fullResponseRange,
            withTemplate: ""
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)

        return responseTextWithoutAnyPointTags + " " + singlePointTagToKeep
    }

    // MARK: - Final Button Warning

    /// Words that mean a button finishes something for real — sends a tax
    /// return, pays money, or confirms an action that can't be undone.
    /// Deliberately leaves out words like "send" and "verify" on their own, so
    /// everyday steps like "Send OTP" don't get a scary final-step warning.
    private static let finalButtonKeywords = [
        "submit", "pay", "payment", "confirm", "e-verify", "everify", "e verify",
        "file return", "file now", "file itr", "proceed to", "finish", "final"
    ]

    /// The fixed warning added whenever Clicky points at a final button.
    static let finalButtonSpokenWarning =
        "One important thing: this is a final button. Only you decide when to press it. "
        + "Please check everything carefully first. I will never press it for you."

    /// True if the thing being pointed at looks like a submit / pay / confirm
    /// style button.
    static func isPointingAtFinalButton(pointedElementLabel: String?) -> Bool {
        guard let pointedElementLabel else { return false }
        let lowercasedElementLabel = pointedElementLabel.lowercased()
        return finalButtonKeywords.contains { finalButtonKeyword in
            lowercasedElementLabel.contains(finalButtonKeyword)
        }
    }

    /// Adds the fixed "only you decide" warning to the spoken reply when the
    /// arrow is pointing at a final button. Done in code so the warning is
    /// always there, whatever the model says.
    static func addFinalButtonWarningIfNeeded(spokenText: String, pointedElementLabel: String?) -> String {
        guard isPointingAtFinalButton(pointedElementLabel: pointedElementLabel) else {
            return spokenText
        }
        print("🛡️ First-Timer guard: pointing at a final button (\(pointedElementLabel ?? "")) — adding the 'only you decide' warning")
        return spokenText + " " + finalButtonSpokenWarning
    }

    // MARK: - Private Number Redaction

    /// A PAN is 5 letters, 4 digits, 1 letter (for example ABCDE1234F).
    /// Speech-to-text may put spaces between the characters, so allow those.
    private static let panNumberPattern = #"(?i)\b(?:[A-Z]\s?){5}(?:[0-9]\s?){4}[A-Z]\b"#

    /// An Aadhaar number is 12 digits, usually spoken in groups of four.
    private static let aadhaarNumberPattern = #"\b[0-9]{4}[\s-]?[0-9]{4}[\s-]?[0-9]{4}\b"#

    /// Blanks out PAN and Aadhaar numbers from what the user said, before the
    /// transcript is sent anywhere. Claude is told these were hidden, so it
    /// can remind the user to type them in themselves instead.
    static func hidePrivateIdentityNumbers(in spokenTranscript: String) -> String {
        var transcriptWithPrivateNumbersHidden = spokenTranscript

        if let panNumberRegex = try? NSRegularExpression(pattern: panNumberPattern) {
            transcriptWithPrivateNumbersHidden = panNumberRegex.stringByReplacingMatches(
                in: transcriptWithPrivateNumbersHidden,
                range: NSRange(transcriptWithPrivateNumbersHidden.startIndex..., in: transcriptWithPrivateNumbersHidden),
                withTemplate: "[PAN number hidden by Clicky]"
            )
        }

        if let aadhaarNumberRegex = try? NSRegularExpression(pattern: aadhaarNumberPattern) {
            transcriptWithPrivateNumbersHidden = aadhaarNumberRegex.stringByReplacingMatches(
                in: transcriptWithPrivateNumbersHidden,
                range: NSRange(transcriptWithPrivateNumbersHidden.startIndex..., in: transcriptWithPrivateNumbersHidden),
                withTemplate: "[Aadhaar number hidden by Clicky]"
            )
        }

        if transcriptWithPrivateNumbersHidden != spokenTranscript {
            print("🛡️ First-Timer guard: hid a PAN or Aadhaar number from the transcript")
        }

        return transcriptWithPrivateNumbersHidden
    }
}
