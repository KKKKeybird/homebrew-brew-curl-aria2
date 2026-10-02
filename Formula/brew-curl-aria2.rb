class BrewCurlAria2 < Formula
  desc "Route Homebrew downloads through aria2c for multi-connection downloads"
  homepage "https://github.com/KKKKeybird/homebrew-brew-curl-aria2"
  url "https://github.com/KKKKeybird/homebrew-brew-curl-aria2/releases/download/v0.2.4/brew-curl-aria2-0.2.4.tar.gz"
  sha256 "87cfae62b678ad4b4c5d49f65a55adeb2ffd09059b2c6398acbcc21cbba19db0"
  license "MIT"
  head "https://github.com/KKKKeybird/homebrew-brew-curl-aria2.git", branch: "main"

  depends_on "aria2"

  def install
    bin.install "bin/brew-curl-aria2"
    libexec.install "libexec/curl-aria2", "libexec/contiguous-progress.rb"
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
