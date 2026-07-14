# frozen_string_literal: true

require_relative "lib/wallets/version"

Gem::Specification.new do |spec|
  spec.name = "wallets"
  spec.version = Wallets::VERSION
  spec.authors = ["rameerez"]
  spec.email = ["rubygems@rameerez.com"]

  spec.summary = "Add user wallets with money-like balances to your Rails app."
  spec.description = "Allow your users to have wallets with money-like balances for value / assets holding and transferring. Supports multiple currencies. Useful to add append-oriented, multi-asset wallets to your Rails app with balances, transfers, expiration-aware allocations, row-level locking, and full audit trails. Use it for in-game resources, reward apps, marketplace balances, gig-economy earnings, and internal value transfers between app users."
  spec.homepage = "https://github.com/rameerez/wallets"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/main"
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).select do |file|
      file.start_with?("lib/", "sig/") ||
        %w[CHANGELOG.md LICENSE.txt README.md wallets.webp].include?(file)
    end
  end

  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |file| File.basename(file) }
  spec.require_paths = ["lib"]

  spec.add_dependency "rails", ">= 7.2.3.1", "< 9.0"
end
