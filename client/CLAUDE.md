# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## Project Overview

**WeSee** — A macOS companion app for partners to view each other's work and life status. Built with SwiftUI.

## Build Commands

```bash
# Build the project
xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug build

# Run tests
xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug test

# Clean build
xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug clean build
```

## Architecture

- **App Entry**: `WeSee/WeSeeApp.swift` — `@main` entry point, `WindowGroup` scene
- **Root View**: `WeSee/ContentView.swift` — Main content view (currently placeholder)

## Tech Stack

- **Platform**: macOS
- **UI Framework**: SwiftUI
- **Language**: Swift
- **IDE**: Xcode

## Conventions

- SwiftUI patterns following Apple's Human Interface Guidelines for macOS
- Use Swift concurrency (`async/await`) for asynchronous operations
- Views should be small and focused — extract subviews when complexity grows
- Use `#Preview` for all views
- No force unwrapping; use optional binding or `guard let`
