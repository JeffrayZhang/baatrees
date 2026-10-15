class Baa < Formula
  desc "Tiny ram for your RAM: menu bar app that frees what your dev tools left running"
  homepage "https://github.com/JeffrayZhang/baatrees"
  # trees-v<upstream version>.<n>: never collides with upstream's v* tags, and brew reads it as 1.2.0.1 > 1.2.0
  url "https://github.com/JeffrayZhang/baatrees.git", tag: "trees-v1.2.0.3"
  license "MIT"

  depends_on macos: :sonoma

  def install
    app = prefix/"Baa.app/Contents"
    (app/"MacOS").mkpath
    (app/"Resources").mkpath
    system "swiftc", "-O", "-swift-version", "5", "-parse-as-library",
           "-target", "#{Hardware::CPU.arch}-apple-macos14",
           "-o", app/"MacOS/Baa", "Sources/main.swift"
    cp "Info.plist", app
    cp ["icon/AppIcon.icns", "sounds/baa.wav"], app/"Resources"
    system "codesign", "--force", "-s", "-", prefix/"Baa.app"

    (bin/"baa").write <<~SH
      #!/bin/zsh
      exec "#{opt_prefix}/Baa.app/Contents/MacOS/Baa" "${@:---now}"
    SH
  end

  service do
    run opt_prefix/"Baa.app/Contents/MacOS/Baa"
    keep_alive successful_exit: false
    process_type :interactive
    error_log_path "/tmp/baa.err"
  end

  def caveats
    <<~EOS
      start baa now and at every login:
        brew services start baa
    EOS
  end

  test do
    assert_predicate prefix/"Baa.app/Contents/MacOS/Baa", :executable?
  end
end
