# frozen_string_literal: true

require_relative "lib/robot_lab/cyborg/version"

Gem::Specification.new do |spec|
  spec.name = "robot_lab-cyborg"
  spec.version = RobotLab::Cyborg::VERSION
  spec.authors = ["Dewayne VanHoozer"]
  spec.email = ["dvanhoozer@gmail.com"]

  spec.summary = "Cyborg extension for the RobotLab multi-robot LLM orchestration framework."
  spec.description = "Adds a human peer worker to RobotLab networks: same bus and memory, receiving and issuing tasks alongside robots."
  spec.homepage = "https://github.com/MadBomber/robot_lab-cyborg"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/MadBomber/robot_lab-cyborg"
  spec.metadata["changelog_uri"] = "https://github.com/MadBomber/robot_lab-cyborg/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore test/])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "robot_lab", "~> 0.2", ">= 0.2.6"
end
