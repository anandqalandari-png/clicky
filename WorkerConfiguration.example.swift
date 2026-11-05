//
//  WorkerConfiguration.swift
//  leanring-buddy
//
//  Your own Cloudflare Worker address. This file is listed in .gitignore so
//  it never gets uploaded to GitHub — anyone with this address could use
//  your Worker and spend your API credits.
//
//  To set up a fresh clone: copy WorkerConfiguration.example.swift from the
//  repo root into this folder as WorkerConfiguration.swift, then put your
//  own Worker URL below.
//

enum ClickyWorkerConfiguration {
    /// Base URL of the Cloudflare Worker proxy (no trailing slash).
    static let workerBaseURL = "https://your-worker-name.your-subdomain.workers.dev"
}
