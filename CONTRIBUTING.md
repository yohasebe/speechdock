# Contributing to SpeechDock

Thank you for your interest in contributing to SpeechDock! This document provides guidelines and instructions for contributing.

## Development Setup

### Prerequisites

- macOS 14.0 (Sonoma) or later
- Xcode 16.0 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (for regenerating project files)

### Getting Started

1. **Clone the repository**
   ```bash
   git clone https://github.com/yohasebe/speechdock.git
   cd speechdock
   ```

2. **Generate the Xcode project**
   ```bash
   xcodegen generate
   ```

3. **Open in Xcode**
   ```bash
   open SpeechDock.xcodeproj
   ```

4. **Build and run**
   - Select the `SpeechDock` scheme
   - Press `Cmd+R` to build and run

### Project Structure

```
speechdock/
├── App/                    # Application entry point and state
│   ├── AppDelegate.swift   # App lifecycle management
│   ├── AppState.swift      # Central state management
│   └── SpeechDockApp.swift   # SwiftUI app entry
├── Models/                 # Data models
├── Services/               # Business logic and API integrations
│   ├── RealtimeSTT/        # Speech-to-text services
│   └── TTS/                # Text-to-speech services
├── Views/                  # SwiftUI views
│   ├── FloatingWindow/     # Floating panel views
│   └── Settings/           # Settings views
├── Resources/              # Assets and configuration files
├── Tests/                  # Unit tests
└── scripts/                # Build and deployment scripts
```

## Code Style

### Swift Guidelines

- Use Swift's native types and conventions
- Follow the [Swift API Design Guidelines](https://swift.org/documentation/api-design-guidelines/)
- Use `@MainActor` for UI-related code
- Prefer `async/await` over completion handlers
- Use meaningful variable and function names

### Documentation

- Add documentation comments (`///`) for public APIs
- Include brief descriptions for complex logic
- Keep comments up-to-date with code changes

### Error Handling

- Use Swift's error handling (`throw`, `try`, `catch`)
- Provide meaningful error messages
- Log errors appropriately (use `#if DEBUG` for debug-only logs)

## Testing

### Running Tests

```bash
xcodebuild test -scheme SpeechDock -destination 'platform=macOS'
```

Or in Xcode: `Cmd+U`

### Writing Tests

- Place test files in the `Tests/` directory
- Name test files with the `Tests` suffix (e.g., `KeychainServiceTests.swift`)
- Test both success and failure cases
- Use descriptive test method names

## Pull Request Process

1. **Create a feature branch**
   ```bash
   git checkout -b feature/your-feature-name
   ```

2. **Make your changes**
   - Write clean, well-documented code
   - Add tests for new functionality
   - Ensure all existing tests pass

3. **Commit your changes**
   - Use clear, descriptive commit messages
   - Follow the format: `type: brief description`
   - Types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`

4. **Push and create a PR**
   ```bash
   git push origin feature/your-feature-name
   ```
   - Open a pull request on GitHub
   - Fill in the PR template
   - Link any related issues

5. **Code Review**
   - Address review feedback
   - Keep the PR focused and reasonably sized

## Reporting Issues

### Bug Reports

When reporting bugs, please include:
- macOS version
- SpeechDock version
- Steps to reproduce
- Expected vs actual behavior
- Relevant logs or screenshots

### Feature Requests

For feature requests, please describe:
- The problem you're trying to solve
- Your proposed solution
- Any alternatives you've considered

## License

By contributing to SpeechDock, you agree that your contributions will be licensed under the Apache License 2.0.

## Questions?

If you have questions, feel free to:
- Open a GitHub issue
- Check existing issues and discussions

Thank you for contributing!
