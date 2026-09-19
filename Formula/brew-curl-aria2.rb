class BrewCurlAria2 < Formula
  desc "Route Homebrew downloads through aria2c for multi-connection downloads"
  homepage "https://github.com/KKKKeybird/homebrew-brew-curl-aria2"
  url "https://github.com/KKKKeybird/homebrew-brew-curl-aria2/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "ad375dcb6755375524520998979a44fdfb9523cb7c87759702819310faf3c32e"
  license "MIT"
  head "https://github.com/KKKKeybird/homebrew-brew-curl-aria2.git", branch: "main"

  depends_on "aria2"

  def install
    bin.install "bin/brew-curl-aria2"
    libexec.install "libexec/curl-aria2"
  end

  def caveats
    <<~EOS
      brew-curl-aria2 is installed but NOT enabled: nothing in your
      configuration was changed.

      To route Homebrew's downloads through aria2c:
        brew-curl-aria2 enable
        brew-curl-aria2 test

      This writes a single HOMEBREW_CURL_PATH line to Homebrew's user
      environment file. Undo it at any time with:
        brew-curl-aria2 disable
    EOS
  end

  test do
    assert_match "aria2", shell_output("#{bin}/brew-curl-aria2 status")
    assert_predicate libexec/"curl-aria2", :executable?
  end
end
