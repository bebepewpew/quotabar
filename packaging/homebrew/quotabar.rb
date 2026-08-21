# Homebrew formula for the `quotabar` command.
#
#   brew tap bebepewpew/tap
#   brew install quotabar
#
# THIS FILE IS THE SOURCE OF TRUTH, AND IT IS NOT A TAP. Homebrew installs from
# bebepewpew/homebrew-tap; the release workflow copies this file there, rewrites
# `url` and `sha256`, and only pushes once it has audited, installed and tested
# the result. It lives here rather than in the tap because `install` and `test`
# below execute on every user's machine, so they belong behind this repository's
# branch protection and review. The tap is generated output; edits made directly
# there are overwritten by the next release.
#
# `url` and `sha256` are the only lines the workflow rewrites, and it does so
# with a line-anchored substitution, so keep each on a line of its own. They
# track the last published release; a stale pair here is harmless because the
# workflow replaces them before anything installs from them.
#
# It builds from source deliberately. A downloaded Mach-O that Apple has not
# notarized gets the com.apple.quarantine attribute and Gatekeeper blocks it on
# first run; a binary compiled on the installing machine never carries that
# attribute, so `brew install` just works.
class Quotabar < Formula
  desc "Quota monitor for the Codex, Claude Code and Gemini CLIs"
  homepage "https://github.com/bebepewpew/quotabar"
  url "https://github.com/bebepewpew/quotabar/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "1d621b318af73a3c093c7bfe9a1461dc39df5917d771ec33a63c5b58b95a0c31"
  license "MIT"
  head "https://github.com/bebepewpew/quotabar.git", branch: "main"

  # The menu-bar app is macOS-only and the CLI needs a Swift 6 toolchain, which
  # on this platform means Xcode. Linux users install the .deb, the .rpm or the
  # tarball from the same release instead.
  depends_on :macos
  depends_on xcode: ["16.0", :build]

  def install
    # `main` keeps a placeholder version and the release workflow stamps the
    # real one into the sources it builds without ever committing it, so the
    # tagged tarball still says 0.1.0. Stamp it here too, otherwise
    # `quotabar --version` would misreport whatever Homebrew installed.
    inreplace "Sources/QuotaBarCLI/Arguments.swift",
              /static let version = "[^"]*"/,
              "static let version = \"#{version}\""

    system "swift", "build",
           "--disable-sandbox",
           "--configuration", "release",
           "--product", "quotabar"
    bin.install ".build/release/quotabar"
  end

  def caveats
    <<~EOS
      quotabar reports quotas for provider CLIs that are already installed and
      authenticated; it never completes a login prompt or reads credentials.

      The Gemini probe drives an interactive TUI and therefore needs `expect`,
      which macOS ships at /usr/bin/expect. The Codex and Claude Code probes
      speak over plain pipes and need nothing extra.
    EOS
  end

  test do
    assert_match "quotabar #{version}", shell_output("#{bin}/quotabar --version")
    assert_match "USAGE", shell_output("#{bin}/quotabar --help")
  end
end
