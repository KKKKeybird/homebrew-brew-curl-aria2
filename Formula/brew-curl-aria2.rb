class BrewCurlAria2 < Formula
  desc "Route Homebrew downloads through aria2c for multi-connection downloads"
  homepage "https://github.com/KKKKeybird/homebrew-brew-curl-aria2"
  url "https://github.com/KKKKeybird/homebrew-brew-curl-aria2/releases/download/v0.2.2/brew-curl-aria2-0.2.2.tar.gz"
  sha256 "d74bea88f71bbe4aadfd0d8833dd4cddba95b74bf7fcf5477566b9e5923b4ce3"
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
