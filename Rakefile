# SpeechDock Development Rakefile

require 'fileutils'

# Configuration
APP_NAME = "SpeechDock"
PROJECT_FILE = "#{APP_NAME}.xcodeproj"
SCHEME = APP_NAME
BUILD_DIR = "build"
DERIVED_DATA = "#{ENV['HOME']}/Library/Developer/Xcode/DerivedData"

# Get version from VERSION file
def app_version
  File.read("VERSION").strip
end

# Find the built app in DerivedData
def find_built_app(config)
  Dir.glob("#{DERIVED_DATA}/#{APP_NAME}-*/Build/Products/#{config}/#{APP_NAME}.app").first
end

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

# Install app to /Applications
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
      puts "     rake release:full"
      puts ""
      puts "  2. Use GitHub Actions (recommended):"
      puts "     git tag v#{app_version}"
      puts "     git push origin v#{app_version}"
      puts "     # CI will build, notarize, and create the release automatically"
      puts ""
      puts "=" * 60
      exit 1
    end

    puts "Notarizing DMG..."
    sh "chmod +x scripts/notarize.sh && ./scripts/notarize.sh"
  end

  desc "Full release process (build, DMG, notarize, install)"
  task :full => :notarize do
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

namespace :version do
  desc "Show current version"
  task :show do
    puts "Current version: #{app_version}"
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
    File.write("VERSION", new_version)

    # Update project.yml
    project_yml = File.read("project.yml")
    project_yml.gsub!(/MARKETING_VERSION: "[\d.]+"/, "MARKETING_VERSION: \"#{new_version}\"")
    File.write("project.yml", project_yml)

    puts "Version bumped: #{current} -> #{new_version}"
  end
end

namespace :dev do
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
end

# Default task
desc "Build and run Debug version"
task :default => "run:debug"

# Shortcut aliases
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

# Help task
desc "Show available tasks"
task :help do
  puts ""
  puts "SpeechDock Development Tasks"
  puts "=" * 40
  puts ""
  puts "Common tasks:"
  puts "  rake              # Build and run (Debug)"
  puts "  rake run          # Build and run (Debug)"
  puts "  rake build        # Build (Debug)"
  puts "  rake clean        # Clean build"
  puts "  rake quit         # Quit running app"
  puts "  rake restart      # Quit and run again"
  puts "  rake xcode        # Open in Xcode"
  puts ""
  puts "Build tasks:"
  puts "  rake build:debug   # Build Debug"
  puts "  rake build:release # Build Release"
  puts "  rake build:clean   # Clean build"
  puts ""
  puts "Run tasks:"
  puts "  rake run:debug     # Run Debug"
  puts "  rake run:release   # Run Release"
  puts ""
  puts "Install tasks:"
  puts "  rake install          # Build Release and install to /Applications"
  puts "  rake install:release  # Build Release and install to /Applications"
  puts "  rake install:debug    # Build Debug and install to /Applications"
  puts ""
  puts "Release tasks:"
  puts "  rake release:github   # Create release via GitHub Actions (recommended)"
  puts "  rake release:full     # Full local release (build, DMG, notarize, install)"
  puts "  rake release:dmg      # Create DMG only"
  puts "  rake release:notarize # Notarize DMG (requires env vars)"
  puts ""
  puts "Version tasks:"
  puts "  rake version:show  # Show version"
  puts "  rake version:patch # Bump patch"
  puts "  rake version:minor # Bump minor"
  puts "  rake version:major # Bump major"
  puts ""
  puts "Development:"
  puts "  rake dev:watch     # Watch and rebuild"
  puts "  rake gen           # Generate project"
  puts ""
end
