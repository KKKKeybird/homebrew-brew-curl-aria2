class BrewCurlAria2 < Formula
  desc "Route Homebrew downloads through aria2c for multi-connection downloads"
  homepage "https://github.com/KKKKeybird/homebrew-brew-curl-aria2"
  url "https://github.com/KKKKeybird/homebrew-brew-curl-aria2/releases/download/v0.3.0/brew-curl-aria2-0.3.0.tar.gz"
  sha256 "e5e49a7d621c43790ca5ed7883211c8117b5d61f22d5fc5df9363e018ec0a6c3"
  license "MIT"
  head "https://github.com/KKKKeybird/homebrew-brew-curl-aria2.git", branch: "main"

  depends_on "aria2"

  def install
    bin.install "bin/brew-curl-aria2"
    libexec.install Dir["libexec/*"]
  end

  def caveats
    <<~EOS
      brew-curl-aria2 is installed but NOT enabled: nothing in your
      configuration was changed.

      To route Homebrew's downloads through aria2c:
        brew-curl-aria2 enable
        brew-curl-aria2 test

      This configures brew.env, patches Homebrew's curl selection, and adds
      a marked wrapper loader to zsh/bash startup files. Open a new terminal
      after enabling. The wrapper repairs the patch after Homebrew updates.
      Absolute-path brew and GUI calls bypass automatic repair.
      Undo this project's changes at any time with:
        brew-curl-aria2 disable
    EOS
  end

  test do
    assert_match "aria2", shell_output("#{bin}/brew-curl-aria2 status")
    assert_predicate libexec/"curl-aria2", :executable?
  end
end
