# Homebrew formula for the `quotabar` command.
#
#   brew tap bebepewpew/quotabar https://github.com/bebepewpew/quotabar
#   brew install bebepewpew/quotabar/quotabar
#
# The explicit URL is what lets this live in the project repository rather than
# a separate homebrew-quotabar tap.
#
# It builds from source deliberately. A downloaded Mach-O that Apple has not
# notarized gets the com.apple.quarantine attribute and Gatekeeper blocks it on
# first run; a binary compiled on the installing machine never carries that
# attribute, so `brew install` just works.
#
# After publishing a release, .github/workflows/release.yml opens a pull request
# that moves the tag in `url` and replaces `sha256` with the checksum of that
# tag's source tarball. Keep those two lines each on one line of their own: the
# workflow rewrites them with a line-anchored substitution.
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
