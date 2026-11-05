//
//  FirstTimerProfile.swift
//  leanring-buddy
//
//  The persistent "user profile" for First-Timer Mode: the user's age and
//  how comfortable they are with computers (1 to 5). Collected once during
//  the First-Timer onboarding questions and saved to UserDefaults so it
//  survives app restarts. Everything First-Timer Mode does afterwards is
//  shaped by this profile.
//

import Foundation

/// How comfortable the user says they are with computers, on a 1 to 5 scale.
/// Only levels 1 and 2 get the special First-Timer guidance. Levels 3 to 5
/// fall back to Clicky's normal behavior.
enum ComputerComfortLevel: Int, Codable, CaseIterable, Identifiable {
    case usesComputerForBasicsOnly = 1
    case canGetAroundAndTriedAIOnce = 2
    case fairlyComfortableUsesAISometimes = 3
    case confidentUsesAIRegularly = 4
    case buildsThingsWithAI = 5

    var id: Int { rawValue }

    /// The plain-language description shown on screen and read aloud.
    var plainLanguageDescription: String {
        switch self {
        case .usesComputerForBasicsOnly:
            return "I use my computer for basic things — email, YouTube, maybe some Excel. I've never really used AI."
        case .canGetAroundAndTriedAIOnce:
            return "I can get around, and I've maybe asked an AI a simple question once or twice."
        case .fairlyComfortableUsesAISometimes:
            return "I'm fairly comfortable and use AI sometimes."
        case .confidentUsesAIRegularly:
            return "I'm confident and use AI tools regularly."
        case .buildsThingsWithAI:
            return "I build things with AI."
        }
    }

    /// Levels 1 and 2 get one-step-at-a-time guidance, plain words, a bigger
    /// pointer, a slower voice, and the "I'm lost" button.
    var needsSimpleStepByStepGuidance: Bool {
        return rawValue <= 2
    }
}

/// The answers to the two First-Timer onboarding questions.
struct FirstTimerUserProfile: Codable, Equatable {
    /// The user's age, or nil if they skipped the question or we couldn't
    /// understand the answer. Only used as context for Claude.
    var ageInYears: Int?
    var computerComfortLevel: ComputerComfortLevel

    var needsSimpleStepByStepGuidance: Bool {
        return computerComfortLevel.needsSimpleStepByStepGuidance
    }
}

/// Saves and loads the First-Timer profile. A saved profile means First-Timer
/// Mode is on; clearing it turns First-Timer Mode off.
enum FirstTimerProfileStore {
    private static let userDefaultsKey = "firstTimerUserProfile"

    static func loadSavedProfile() -> FirstTimerUserProfile? {
        guard let savedProfileData = UserDefaults.standard.data(forKey: userDefaultsKey) else {
            return nil
        }
        return try? JSONDecoder().decode(FirstTimerUserProfile.self, from: savedProfileData)
    }

    static func saveProfile(_ profileToSave: FirstTimerUserProfile) {
        guard let encodedProfileData = try? JSONEncoder().encode(profileToSave) else { return }
        UserDefaults.standard.set(encodedProfileData, forKey: userDefaultsKey)
    }

    static func clearSavedProfile() {
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }
}
