#!/usr/bin/env ruby
# frozen_string_literal: true

# Documentation figures: the SVGs in docs/images/ and docs/images/ja/ are
# drawn by scripts/generate-doc-figures.swift and its companions (rake docs:figures). The allow list admits any SVG there, so
# this checks that each one is such a figure, and a hand-written or exported
# SVG cannot pass for one:
# - the files are exactly the figures the generators register, in English
#   (docs/images/) and Japanese (docs/images/ja/);
# - each uses only the elements and attributes the generators write, points
#   only at its own definitions (url(#id)), and has no comments, declarations,
#   processing instructions or entities other than &amp; &lt; &gt; &quot;.
#
# Usage:
#   ruby scripts/lint/check_doc_figures.rb               # the index (next commit)
#   ruby scripts/lint/check_doc_figures.rb --tree REV    # a commit (e.g. before a push)
#   ruby scripts/lint/check_doc_figures.rb --against DIR # also compare with figures
#                                                        # drawn into DIR (rake docs:check_figures)
#
# --against compares each figure's elements, attribute names and text with the
# drawn one. Numbers are left out, since text widths depend on the fonts of the
# machine that draws; a machine with other fonts may also break lines elsewhere.
#
# Output is paths only. Exits 1 on any finding, and when the files cannot be
# read (outside a checkout nothing is "clean").

require 'pathname'

ROOT = Pathname.new(__dir__).join('..', '..').realpath
GENERATORS = %w[scripts/generate-doc-figures.swift scripts/doc-figures-settings.swift scripts/doc-figures-tools.swift].freeze
FIGURE_DIRS = { 'docs/images' => 'en', 'docs/images/ja' => 'ja' }.freeze

ELEMENTS = %w[svg title defs filter feDropShadow linearGradient stop clipPath g rect text path circle ellipse].freeze
ATTRIBUTES = %w[
  xmlns role width height viewBox font-family id x y x1 y1 x2 y2 dx dy rx ry r cx cy d offset
  fill fill-opacity fill-rule stroke stroke-width stroke-opacity stroke-linecap stroke-linejoin stroke-dasharray
  opacity color filter clip-path transform stop-color flood-color flood-opacity stdDeviation
  font-size font-weight text-anchor xml:space
].freeze
TAG = /<(\/?)([A-Za-z][\w:-]*)((?:\s+[\w:-]+="[^"<>]*")*)\s*(\/?)>/
ATTRIBUTE = /([\w:-]+)="([^"]*)"/

def git_read(*args)
  out = IO.popen(['git', '-C', ROOT.to_s, *args], err: File::NULL, &:read)
  $?.success? ? out : nil
rescue SystemCallError
  nil
end

def fail_with(message)
  puts "[lint:doc_figures] #{message}"
  exit 1
end

tree = nil
against = nil
if ARGV.include?('--tree')
  tree = ARGV[ARGV.index('--tree') + 1]
  fail_with('--tree needs a revision; refusing to pass.') if tree.nil? || tree.start_with?('-')
end
if ARGV.include?('--against')
  against = ARGV[ARGV.index('--against') + 1]
  fail_with('--against needs a directory; refusing to pass.') if against.nil? || !File.directory?(against)
end

paths = tree ? git_read('ls-tree', '-r', '--name-only', tree) : git_read('ls-files')
fail_with('cannot list the tracked files; refusing to pass.') if paths.nil?
paths = paths.split("\n")

def read_file(tree, path)
  git_read('show', tree ? "#{tree}:#{path}" : ":#{path}") || fail_with("cannot read #{path}; refusing to pass.")
end

# The figure names the generators register, as in `("stt-panel", sttPanel),`.
names = GENERATORS.select { |g| paths.include?(g) }.flat_map do |generator|
  read_file(tree, generator).scan(/^\s*\("([a-z0-9-]+)", \w+\),$/).flatten
end
fail_with('no figures are registered in the generators; refusing to pass.') if names.empty?

expected = FIGURE_DIRS.keys.flat_map { |dir| names.map { |name| "#{dir}/#{name}.svg" } }
present = paths.select { |p| FIGURE_DIRS.key?(File.dirname(p)) && p.end_with?('.svg') }

findings = []
(present - expected).each { |p| findings << "#{p}: not a figure the generators draw" }
(expected - present).each { |p| findings << "#{p}: missing" }

# The parts of a figure that do not depend on the fonts that measured it.
def skeleton(svg)
  svg.scan(TAG).map do |closing, name, attributes, _|
    pairs = attributes.scan(ATTRIBUTE).map { |key, value| "#{key}=#{value.gsub(/-?\d+(\.\d+)?/, 'N')}" }
    "#{closing}#{name} #{pairs.join(' ')}"
  end + [svg.gsub(TAG, "\n").split("\n").map(&:strip).reject(&:empty?).join("\n")]
end

(present & expected).each do |path|
  svg = read_file(tree, path)
  rest = svg.gsub(TAG, '')
  findings << "#{path}: has markup the generators do not write" if rest.include?('<') || rest.include?('>')
  findings << "#{path}: has an entity the generators do not write" if svg.scan(/&[^;\s]*;?/).any? { |e| !%w[&amp; &lt; &gt; &quot;].include?(e) }
  svg.scan(TAG) do |_, name, attributes, _|
    findings << "#{path}: element <#{name}>" unless ELEMENTS.include?(name)
    attributes.scan(ATTRIBUTE) do |key, value|
      findings << "#{path}: attribute #{key} on <#{name}>" unless ATTRIBUTES.include?(key)
      next if key == 'xmlns' && value == 'http://www.w3.org/2000/svg'

      value.scan(/url\(([^)]*)\)/) { |(target)| findings << "#{path}: url(#{target})" unless target.match?(/\A#[\w-]+\z/) }
      findings << "#{path}: #{key} refers outside the figure" if value.match?(/:\/\/|data:|javascript:/i)
    end
  end
  next unless against

  drawn = File.join(against, path.delete_prefix('docs/images/'))
  if !File.file?(drawn)
    findings << "#{path}: not drawn by the generators"
  elsif skeleton(svg) != skeleton(File.read(drawn))
    findings << "#{path}: differs from the figure the generators draw"
  end
end

if findings.empty?
  puts "[lint:doc_figures] OK — #{present.size} figures, each one the generators draw#{against ? ' and matching a fresh drawing' : ''}."
else
  findings.uniq.each { |f| puts "[lint:doc_figures] #{f}" }
  exit 1
end
