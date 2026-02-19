# SpeechDock Development Rakefile

require 'fileutils'

# Configuration
APP_NAME = "SpeechDock"
PROJECT_FILE = "#{APP_NAME}.xcodeproj"
SCHEME = APP_NAME
BUILD_DIR = "build"
DERIVED_DATA = "#{ENV['HOME']}/Library/Developer/Xcode/DerivedData"
DOCS_DIR = "docs"

# Files that contain version numbers
VERSION_FILES = {
  version: "VERSION",
  project_yml: "project.yml",
  info_plist: "Resources/Info.plist"
}

# Get version from VERSION file
def app_version
  File.read(VERSION_FILES[:version]).strip
end

# Find the built app in DerivedData
def find_built_app(config)
  Dir.glob("#{DERIVED_DATA}/#{APP_NAME}-*/Build/Products/#{config}/#{APP_NAME}.app").first
end

# ============================================================
# Version Management
# ============================================================

namespace :version do
  desc "Show current version"
  task :show do
    puts "Current version: #{app_version}"
    puts ""
    puts "Version locations:"
    VERSION_FILES.each do |key, file|
      if File.exist?(file)
        content = File.read(file)
        case key
        when :version
          puts "  #{file}: #{content.strip}"
        when :project_yml
          if content =~ /MARKETING_VERSION: "(.+?)"/
            puts "  #{file}: #{$1}"
          end
        when :info_plist
          puts "  #{file}: (uses build setting variables)"
        end
      end
    end
  end

  desc "Verify all version numbers are in sync"
  task :verify do
    versions = {}

    # Check VERSION file
    versions[:version] = File.read(VERSION_FILES[:version]).strip

    # Check project.yml
    content = File.read(VERSION_FILES[:project_yml])
    if content =~ /MARKETING_VERSION: "(.+?)"/
      versions[:project_yml] = $1
    end

    # Info.plist uses build setting variables, no need to check

    unique_versions = versions.values.uniq
    if unique_versions.length == 1
      puts "✓ All version numbers are in sync: #{unique_versions.first}"
    else
      puts "✗ Version mismatch detected!"
      versions.each do |file, ver|
        puts "  #{VERSION_FILES[file]}: #{ver}"
      end
      exit 1
    end
  end

  desc "Bump patch version (0.1.0 -> 0.1.1)"
  task :patch do
    bump_version(:patch)
  end

  desc "Bump minor version (0.1.0 -> 0.2.0)"
  task :minor do
    bump_version(:minor)
  end

  desc "Bump major version (0.1.0 -> 1.0.0)"
  task :major do
    bump_version(:major)
  end

  def bump_version(type)
    current = app_version
    parts = current.split('.').map(&:to_i)

    case type
    when :major
      parts[0] += 1
      parts[1] = 0
      parts[2] = 0
    when :minor
      parts[1] += 1
      parts[2] = 0
    when :patch
      parts[2] += 1
    end

    new_version = parts.join('.')

    puts "Bumping version: #{current} -> #{new_version}"
    puts ""

    # Update VERSION file
    puts "  Updating #{VERSION_FILES[:version]}..."
    File.write(VERSION_FILES[:version], new_version)

    # Update project.yml
    puts "  Updating #{VERSION_FILES[:project_yml]}..."
    project_yml = File.read(VERSION_FILES[:project_yml])
    project_yml.gsub!(/MARKETING_VERSION: "[\d.]+"/, "MARKETING_VERSION: \"#{new_version}\"")
    project_yml.gsub!(/CURRENT_PROJECT_VERSION: "[\d.]+"/, "CURRENT_PROJECT_VERSION: \"#{new_version}\"")
    File.write(VERSION_FILES[:project_yml], project_yml)

    puts ""
    puts "✓ Version bumped to #{new_version}"

    # Verify
    Rake::Task["version:verify"].invoke
  end
end

# ============================================================
# Project Management
# ============================================================

namespace :project do
  desc "Generate Xcode project with XcodeGen"
  task :generate do
    puts "Generating Xcode project..."
    sh "xcodegen generate"
    puts "Project generated: #{PROJECT_FILE}"
  end

  desc "Open project in Xcode"
  task :open => :generate do
    sh "open #{PROJECT_FILE}"
  end
end

# ============================================================
# Build Tasks
# ============================================================

namespace :build do
  desc "Build for Debug"
  task :debug => "project:generate" do
    puts "Building #{APP_NAME} (Debug)..."
    sh "xcodebuild -project #{PROJECT_FILE} -scheme #{SCHEME} -configuration Debug build"
    puts "Build complete!"
  end

  desc "Build for Release"
  task :release => "project:generate" do
    puts "Building #{APP_NAME} (Release)..."
    sh "xcodebuild -project #{PROJECT_FILE} -scheme #{SCHEME} -configuration Release build"
    puts "Build complete!"
  end

  desc "Clean build"
  task :clean do
    puts "Cleaning..."
    sh "xcodebuild -project #{PROJECT_FILE} -scheme #{SCHEME} clean" if File.exist?(PROJECT_FILE)
    FileUtils.rm_rf(BUILD_DIR)
    puts "Clean complete!"
  end
end

# ============================================================
# Test Tasks
# ============================================================

namespace :test do
  desc "Run all tests"
  task :all => "project:generate" do
    puts "Running all tests..."
    sh "xcodebuild test -project #{PROJECT_FILE} -scheme #{SCHEME} -destination 'platform=macOS'"
  end

  desc "Run tests with summary only"
  task :quick => "project:generate" do
    puts "Running tests (summary only)..."
    sh "xcodebuild test -project #{PROJECT_FILE} -scheme #{SCHEME} -destination 'platform=macOS' 2>&1 | grep -E '(Test Suite|Executed|SUCCEEDED|FAILED)'"
  end

  desc "Run specific test class (e.g., rake test:class[AppleScriptTests])"
  task :class, [:name] => "project:generate" do |t, args|
    if args[:name].nil?
      puts "Usage: rake test:class[TestClassName]"
      exit 1
    end
    puts "Running tests for #{args[:name]}..."
    sh "xcodebuild test -project #{PROJECT_FILE} -scheme #{SCHEME} -destination 'platform=macOS' -only-testing:SpeechDockTests/#{args[:name]}"
  end
end

# ============================================================
# Run Tasks
# ============================================================

namespace :run do
  desc "Build and run Debug version"
  task :debug => "build:debug" do
    app_path = find_built_app("Debug")
    if app_path
      puts "Running #{APP_NAME} (Debug)..."
      sh "open '#{app_path}'"
    else
      puts "Error: Could not find built app"
      exit 1
    end
  end

  desc "Build and run Release version"
  task :release => "build:release" do
    app_path = find_built_app("Release")
    if app_path
      puts "Running #{APP_NAME} (Release)..."
      sh "open '#{app_path}'"
    else
      puts "Error: Could not find built app"
      exit 1
    end
  end
end

desc "Quit running app"
task :quit do
  puts "Quitting #{APP_NAME}..."
  system "pkill -x #{APP_NAME}"
  puts "Done"
end

desc "Restart app (quit and run debug)"
task :restart => [:quit, "run:debug"]

# ============================================================
# Install Tasks
# ============================================================

def install_app(app_path)
  dest = "/Applications/#{APP_NAME}.app"

  # Quit running app first
  puts "Quitting #{APP_NAME} if running..."
  system "pkill -x #{APP_NAME}"
  sleep 1

  # Remove existing installation
  if File.exist?(dest)
    puts "Removing existing installation..."
    FileUtils.rm_rf(dest)
  end

  # Copy new build
  puts "Installing to #{dest}..."
  FileUtils.cp_r(app_path, dest)

  puts "Installation complete!"
  puts ""
  puts "To launch: open -a #{APP_NAME}"
end

namespace :install do
  desc "Build and install to /Applications (Release)"
  task :release => "build:release" do
    app_path = find_built_app("Release")
    if app_path
      install_app(app_path)
    else
      puts "Error: Could not find built app"
      exit 1
    end
  end

  desc "Build and install to /Applications (Debug)"
  task :debug => "build:debug" do
    app_path = find_built_app("Debug")
    if app_path
      install_app(app_path)
    else
      puts "Error: Could not find built app"
      exit 1
    end
  end
end

desc "Alias for install:release"
task :install => "install:release"

# ============================================================
# Documentation Tasks
# ============================================================

namespace :docs do
  desc "Start Jekyll server for local preview (http://localhost:4000)"
  task :serve do
    puts "Starting Jekyll server..."
    puts "Preview at: http://localhost:4000/SpeechDock/"
    puts "Press Ctrl+C to stop"
    puts ""
    Dir.chdir(DOCS_DIR) do
      sh "bundle exec jekyll serve --livereload"
    end
  end

  desc "Build documentation site"
  task :build do
    puts "Building documentation..."
    Dir.chdir(DOCS_DIR) do
      sh "bundle exec jekyll build"
    end
    puts "Documentation built to #{DOCS_DIR}/_site/"
  end

  desc "Install Jekyll dependencies"
  task :setup do
    puts "Installing Jekyll dependencies..."
    Dir.chdir(DOCS_DIR) do
      sh "bundle install"
    end
    puts "Done!"
  end

  desc "Clean built documentation"
  task :clean do
    site_dir = "#{DOCS_DIR}/_site"
    if File.exist?(site_dir)
      puts "Cleaning #{site_dir}..."
      FileUtils.rm_rf(site_dir)
      puts "Done!"
    else
      puts "Nothing to clean"
    end
  end
end

# ============================================================
# Release Tasks
# ============================================================

namespace :release do
  desc "Create DMG for distribution"
  task :dmg => "build:release" do
    puts "Creating DMG..."
    sh "chmod +x scripts/create-dmg.sh && ./scripts/create-dmg.sh"
  end

  desc "Notarize DMG (requires APPLE_ID, APP_PASSWORD, TEAM_ID environment variables)"
  task :notarize => :dmg do
    # Check for required environment variables
    missing_vars = []
    missing_vars << "APPLE_ID" unless ENV["APPLE_ID"]
    missing_vars << "APP_PASSWORD" unless ENV["APP_PASSWORD"]
    missing_vars << "TEAM_ID" unless ENV["TEAM_ID"]

    unless missing_vars.empty?
      puts ""
      puts "=" * 60
      puts "ERROR: Missing required environment variables for notarization"
      puts "=" * 60
      puts ""
      puts "The following environment variables are not set:"
      missing_vars.each { |v| puts "  - #{v}" }
      puts ""
      puts "Options:"
      puts "  1. Set environment variables and run again:"
      puts "     export APPLE_ID='your-apple-id@example.com'"
      puts "     export APP_PASSWORD='xxxx-xxxx-xxxx-xxxx'  # App-specific password"
      puts "     export TEAM_ID='XXXXXXXXXX'"
      puts "     rake release:local"
      puts ""
      puts "  2. Use GitHub Actions (recommended):"
      puts "     rake prepare:release"
      puts "     # Then follow the instructions"
      puts ""
      puts "=" * 60
      exit 1
    end

    puts "Notarizing DMG..."
    sh "chmod +x scripts/notarize.sh && ./scripts/notarize.sh"
  end

  desc "Local release (requires APPLE_ID, APP_PASSWORD, TEAM_ID env vars). Prefer release:github"
  task :local => :notarize do
    # Install to /Applications after successful notarization
    app_path = find_built_app("Release")
    if app_path
      puts ""
      puts "Installing to /Applications..."
      install_app(app_path)
    end

    puts ""
    puts "=" * 60
    puts "Release complete: #{APP_NAME}-#{app_version}.dmg"
    puts "Installed to: /Applications/#{APP_NAME}.app"
    puts "=" * 60
  end

  desc "Create release via GitHub Actions (recommended)"
  task :github do
    version = app_version
    puts ""
    puts "Creating release v#{version} via GitHub Actions..."
    puts ""

    # Check if tag already exists
    tag_exists = system("git rev-parse v#{version} >/dev/null 2>&1")
    if tag_exists
      puts "Tag v#{version} already exists."
      print "Delete existing tag and recreate? [y/N]: "
      answer = STDIN.gets.chomp.downcase
      if answer == 'y'
        sh "git tag -d v#{version}"
        sh "git push origin :refs/tags/v#{version} 2>/dev/null || true"
        # Delete existing release if any
        system "gh release delete v#{version} --yes 2>/dev/null"
      else
        puts "Aborted."
        exit 0
      end
    end

    # Create and push tag
    sh "git tag v#{version}"
    sh "git push origin v#{version}"

    puts ""
    puts "Tag v#{version} pushed. GitHub Actions will:"
    puts "  1. Build the Release version"
    puts "  2. Create notarized DMG"
    puts "  3. Update appcast.xml"
    puts "  4. Create GitHub Release"
    puts ""
    puts "Monitor progress at:"
    puts "  https://github.com/yohasebe/speechdock/actions"
    puts ""
  end
end

# ============================================================
# Prepare Tasks (Pre-release workflow)
# ============================================================

namespace :prepare do
  desc "Prepare release: bump version, regenerate project, run tests, commit"
  task :release, [:bump_type] do |t, args|
    bump_type = (args[:bump_type] || "patch").to_sym
    unless [:patch, :minor, :major].include?(bump_type)
      puts "Invalid bump type: #{args[:bump_type]}"
      puts "Usage: rake prepare:release[patch|minor|major]"
      exit 1
    end

    puts ""
    puts "=" * 60
    puts "Preparing release (#{bump_type} bump)"
    puts "=" * 60
    puts ""

    # Step 1: Bump version
    puts "Step 1: Bumping version..."
    Rake::Task["version:#{bump_type}"].invoke
    new_version = app_version
    puts ""

    # Step 2: Regenerate project
    puts "Step 2: Regenerating Xcode project..."
    Rake::Task["project:generate"].invoke
    puts ""

    # Step 3: Run tests
    puts "Step 3: Running tests..."
    Rake::Task["test:quick"].invoke
    puts ""

    # Step 4: Show git status
    puts "Step 4: Changes to commit:"
    sh "git status --short"
    puts ""

    # Step 5: Confirm and commit
    print "Commit these changes and push? [y/N]: "
    answer = STDIN.gets.chomp.downcase
    if answer == 'y'
      sh "git add -A"
      sh "git commit -m 'Bump version to #{new_version}'"
      sh "git push"

      puts ""
      puts "=" * 60
      puts "✓ Version #{new_version} committed and pushed"
      puts ""
      puts "Next step:"
      puts "  rake release:github   # Create release via GitHub Actions (recommended)"
      puts "=" * 60
    else
      puts ""
      puts "Changes not committed. To commit manually:"
      puts "  git add -A"
      puts "  git commit -m 'Bump version to #{new_version}'"
      puts "  git push"
    end
  end

  desc "Quick prepare: bump patch, commit, and trigger GitHub release"
  task :quick do
    Rake::Task["prepare:release"].invoke("patch")

    print "Trigger GitHub Actions release now? [y/N]: "
    answer = STDIN.gets.chomp.downcase
    if answer == 'y'
      Rake::Task["release:github"].invoke
    end
  end
end

# ============================================================
# Development Tasks
# ============================================================

namespace :dev do
  desc "Build, quit old dev instance, and launch Dev version"
  task :run => "build:debug" do
    app_path = find_built_app("Debug")
    if app_path
      # Kill only the dev instance (running from DerivedData), not /Applications
      puts "Quitting SpeechDock Dev if running..."
      system "pkill -f 'DerivedData.*SpeechDock.app'"
      sleep 1

      puts "Launching SpeechDock Dev..."
      sh "open '#{app_path}'"
    else
      puts "Error: Could not find built app"
      exit 1
    end
  end

  desc "Quit only the Dev instance (keeps /Applications version running)"
  task :quit do
    puts "Quitting SpeechDock Dev..."
    system "pkill -f 'DerivedData.*SpeechDock.app'"
    puts "Done"
  end

  desc "Quit and relaunch Dev version"
  task :restart => [:quit, :run]

  desc "Watch for changes and rebuild (requires fswatch)"
  task :watch do
    puts "Watching for changes... (Ctrl+C to stop)"
    puts "Monitored directories: App, Models, Services, Views, Utilities"
    dirs = %w[App Models Services Views Utilities].join(' ')
    sh "fswatch -o #{dirs} | xargs -n1 -I{} rake build:debug"
  end

  desc "Show build logs"
  task :logs do
    log_dir = "#{DERIVED_DATA}/#{APP_NAME}-*/Logs/Build"
    latest_log = Dir.glob("#{log_dir}/*.xcactivitylog").max_by { |f| File.mtime(f) }
    if latest_log
      sh "gunzip -c '#{latest_log}' | less"
    else
      puts "No build logs found"
    end
  end

  desc "Open documentation in browser"
  task :docs do
    sh "open https://yohasebe.github.io/SpeechDock/"
  end

  desc "Run app with no API keys (simulates typical user experience)"
  task :no_api => "build:debug" do
    app_path = find_built_app("Debug")
    if app_path
      puts ""
      puts "=" * 60
      puts "Running #{APP_NAME} with NO API keys"
      puts "=" * 60
      puts ""
      puts "This simulates the experience of a typical user who only"
      puts "uses macOS built-in features (Speech Recognition, TTS,"
      puts "Translation) without external API providers."
      puts ""
      puts "All external API providers (OpenAI, Gemini, ElevenLabs,"
      puts "Grok) will appear as unavailable."
      puts ""

      # Launch the app executable directly with environment variable
      executable = "#{app_path}/Contents/MacOS/#{APP_NAME}"
      # Fork a process so rake can exit while app continues running
      pid = spawn({ 'SPEECHDOCK_TEST_NO_API_KEYS' => '1' }, executable)
      Process.detach(pid)
      puts "Launched with PID: #{pid}"
    else
      puts "Error: Could not find built app"
      exit 1
    end
  end
end

# ============================================================
# Shortcut Aliases
# ============================================================

desc "Build and run Debug version"
task :default => "run:debug"

desc "Alias for run:debug"
task :run => "run:debug"

desc "Alias for build:debug"
task :build => "build:debug"

desc "Alias for build:clean"
task :clean => "build:clean"

desc "Alias for project:generate"
task :gen => "project:generate"

desc "Alias for project:open"
task :xcode => "project:open"

desc "Alias for test:quick"
task :test => "test:quick"

desc "Alias for docs:serve"
task :docs => "docs:serve"

desc "Alias for dev:no_api (run with no API keys)"
task :noapi => "dev:no_api"

# ============================================================
# Help
# ============================================================

desc "Show available tasks"
task :help do
  puts ""
  puts "SpeechDock Development Tasks"
  puts "=" * 60
  puts ""
  puts "Quick Start:"
  puts "  rake              # Build and run (Debug)"
  puts "  rake test         # Run tests (summary)"
  puts "  rake docs         # Start Jekyll preview server"
  puts ""
  puts "Version Management:"
  puts "  rake version:show    # Show current version"
  puts "  rake version:verify  # Verify version sync across files"
  puts "  rake version:patch   # Bump patch (0.1.0 -> 0.1.1)"
  puts "  rake version:minor   # Bump minor (0.1.0 -> 0.2.0)"
  puts "  rake version:major   # Bump major (0.1.0 -> 1.0.0)"
  puts ""
  puts "Build & Run:"
  puts "  rake build:debug   # Build Debug"
  puts "  rake build:release # Build Release"
  puts "  rake run:debug     # Build and run Debug"
  puts "  rake run:release   # Build and run Release"
  puts "  rake quit          # Quit running app"
  puts "  rake restart       # Quit and run again"
  puts ""
  puts "Testing:"
  puts "  rake test:all              # Run all tests"
  puts "  rake test:quick            # Run tests (summary only)"
  puts "  rake test:class[ClassName] # Run specific test class"
  puts ""
  puts "Documentation:"
  puts "  rake docs:serve  # Start Jekyll server (localhost:4000)"
  puts "  rake docs:build  # Build documentation"
  puts "  rake docs:setup  # Install Jekyll dependencies"
  puts ""
  puts "Installation:"
  puts "  rake install          # Build Release and install to /Applications"
  puts "  rake install:debug    # Build Debug and install"
  puts ""
  puts "Release Preparation:"
  puts "  rake prepare:release[patch]  # Bump, test, commit (patch/minor/major)"
  puts "  rake prepare:quick           # Quick patch release prep"
  puts ""
  puts "Release:"
  puts "  rake release:github   # Create release via GitHub Actions (recommended)"
  puts "  rake release:local    # Local release (requires APPLE_ID/APP_PASSWORD/TEAM_ID env vars)"
  puts "  rake release:dmg      # Create DMG only (no notarization)"
  puts ""
  puts "Development:"
  puts "  rake dev:run      # Build and launch Dev version (green badge)"
  puts "  rake dev:quit     # Quit only Dev (keeps /Applications version)"
  puts "  rake dev:restart  # Quit and relaunch Dev"
  puts "  rake xcode        # Open in Xcode"
  puts "  rake gen          # Regenerate project"
  puts "  rake dev:watch    # Watch and rebuild"
  puts "  rake dev:no_api   # Run with no API keys (test macOS-only mode)"
  puts ""
end
