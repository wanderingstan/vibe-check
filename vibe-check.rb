class VibeCheck < Formula
  include Language::Python::Virtualenv

  desc "Claude Code conversation monitoring and analytics"
  homepage "https://github.com/wanderingstan/vibe-check"
  url "https://github.com/wanderingstan/vibe-check/archive/refs/tags/v1.1.14.tar.gz"
  sha256 "5ba521a91b1af3f0ae8ddc5e0d88119c489f08c53a3112fe0ff0aafff99cf300"
  license "MIT"
  head "https://github.com/wanderingstan/vibe-check.git", branch: "main"

  depends_on "python@3.12"

  resource "watchdog" do
    url "https://files.pythonhosted.org/packages/db/7d/7f3d619e951c88ed75c6037b246ddcf2d322812ee8ea189be89511721d54/watchdog-6.0.0.tar.gz"
    sha256 "9ddf7c82fda3ae8e24decda1338ede66e1c99883db93711d8fb941eaa2d8c282"
  end

  resource "requests" do
    url "https://files.pythonhosted.org/packages/63/70/2bf7780ad2d390a8d301ad0b550f1581eadbd9a20f896afe06353c2a2913/requests-2.32.3.tar.gz"
    sha256 "55365417734eb18255590a9ff9eb97e9e1da868d4ccd6402399eaf68af20a760"
  end

  resource "detect-secrets" do
    url "https://files.pythonhosted.org/packages/69/67/382a863fff94eae5a0cf05542179169a1c49a4c8784a9480621e2066ca7d/detect_secrets-1.5.0.tar.gz"
    sha256 "6bb46dcc553c10df51475641bb30fd69d25645cc12339e46c824c1e0c388898a"
  end

  resource "pymysql" do
    url "https://files.pythonhosted.org/packages/b3/8f/ce59b5e5ed4ce8512f879ff1fa5ab699d211ae2495f1adaa5fbba2a1eada/pymysql-1.1.1.tar.gz"
    sha256 "e127611aaf2b417403c60bf4dc570124aeb4a57f5f37b8e95ae399a42f904cd0"
  end

  # Additional dependencies for detect-secrets
  resource "certifi" do
    url "https://files.pythonhosted.org/packages/b0/ee/9b19140fe824b367c04c5e1b369942dd754c4c5462d5674002f75c4dedc1/certifi-2024.8.30.tar.gz"
    sha256 "bec941d2aa8195e248a60b31ff9f0558284cf01a52591ceda73ea9afffd69fd9"
  end

  resource "charset-normalizer" do
    url "https://files.pythonhosted.org/packages/f2/4f/e1808dc01273379acc506d18f1504eb2d299bd4131743b9fc54d7be4df1e/charset_normalizer-3.4.0.tar.gz"
    sha256 "223217c3d4f82c3ac5e29032b3f1c2eb0fb591b72161f86d93f5719079dae93e"
  end

  resource "idna" do
    url "https://files.pythonhosted.org/packages/f1/70/7703c29685631f5a7590aa73f1f1d3fa9a380e654b86af429e0934a32f7d/idna-3.10.tar.gz"
    sha256 "12f65c9b470abda6dc35cf8e63cc574b1c52b11df2c86030af0ac09b01b13ea9"
  end

  resource "urllib3" do
    url "https://files.pythonhosted.org/packages/ed/63/22ba4ebfe7430b76388e7cd448d5478814d3032121827c12a2cc287e2260/urllib3-2.2.3.tar.gz"
    sha256 "e7d814a81dad81e6caf2ec9fdedb284ecc9c73076b62654547cc64ccdcae26e9"
  end

  resource "pyyaml" do
    url "https://files.pythonhosted.org/packages/54/ed/79a089b6be93607fa5cdaedf301d7dfb23af5f25c398d5ead2525b063e17/pyyaml-6.0.2.tar.gz"
    sha256 "d584d9ec91ad65861cc08d42e834324ef890a082e591037abe114850ff7bbc3e"
  end

  def install
    # Create virtual environment
    venv = virtualenv_create(libexec, "python3.12")

    # Install Python dependencies (resources) into the venv
    resources.each do |r|
      venv.pip_install r
    end

    # Copy Python modules to libexec
    libexec.install "vibe-check.py", "secret_detector.py"
    (libexec/"scripts").install "scripts/query-helper.sh"

    # Make vibe-check.py executable
    chmod 0755, libexec/"vibe-check.py"

    # Install MCP server to share directory
    (share/"vibe-check/mcp-server").install Dir["mcp-server/*.py"]
    (share/"vibe-check/mcp-server").install "mcp-server/requirements.txt" if File.exist?("mcp-server/requirements.txt")

    # Install skills to share directory (each skill is a directory with SKILL.md)
    (share/"vibe-check/skills").install Dir["skills/vibe-check-*"]

    # Install MCP server to share directory
    (share/"vibe-check/mcp-server").install Dir["mcp-server/*"]

    # Create executable wrapper for monitor that uses venv python
    (bin/"vibe-check").write <<~EOS
      #!/bin/bash
      export PYTHONPATH="#{libexec}"
      exec "#{libexec}/bin/python3" "#{libexec}/vibe-check.py" "$@"
    EOS
    chmod 0755, bin/"vibe-check"

    # Create query helper wrapper (points to unified location)
    (bin/"vibe-check-query").write_env_script libexec/"scripts/query-helper.sh",
      VIBE_CHECK_DB: "#{Dir.home}/.vibe-check/vibe_check.db"
  end

  def post_install
    # Note: Homebrew's sandbox prevents access to home directory
    # All setup (config, skills) is handled by vibe-check on first run
    ohai "Run 'vibe-check start' to enable monitoring with auto-start on boot!"
  end

  service do
    run [opt_bin/"vibe-check", "--run"]
    working_dir HOMEBREW_PREFIX/"var"
    keep_alive true
    log_path var/"log/vibe-check.log"
    error_log_path var/"log/vibe-check.log"  # Unified: stderr goes to same file as stdout
    environment_variables PATH: std_service_path_env
  end

  test do
    # Test help command works
    system bin/"vibe-check", "--help"

    # Verify skills installed to share directory
    assert_predicate share/"vibe-check/skills/vibe-check-stats/SKILL.md", :exist?

    # Test Python imports work
    system libexec/"bin/python3", "-c", "import watchdog, requests"
  end

  def caveats
    s = ""
    claude_projects = "#{Dir.home}/.claude/projects"
    unless Dir.exist?(claude_projects)
      s += <<~WARN
        ⚠️  Claude Code not detected!
        Vibe Check monitors Claude Code conversations - install Claude Code first:
          https://code.claude.com/docs/en/overview
        Run Claude Code at least once, then start vibe-check.

      WARN
    end
    s += <<~EOS

      ██╗   ██╗██╗██████╗ ███████╗       ██████╗██╗  ██╗███████╗ ██████╗██╗  ██╗
      ██║   ██║██║██╔══██╗██╔════╝      ██╔════╝██║  ██║██╔════╝██╔════╝██║ ██╔╝
      ██║   ██║██║██████╔╝█████╗  █████╗██║     ███████║█████╗  ██║     █████╔╝
      ╚██╗ ██╔╝██║██╔══██╗██╔══╝  ╚════╝██║     ██╔══██║██╔══╝  ██║     ██╔═██╗
       ╚████╔╝ ██║██████╔╝███████╗      ╚██████╗██║  ██║███████╗╚██████╗██║  ██╗
        ╚═══╝  ╚═╝╚═════╝ ╚══════╝       ╚═════╝╚═╝  ╚═╝╚══════╝ ╚═════╝╚═╝  ╚═╝

                         ~ Claude Code Analytics ~

      ╔═══════════════════════════════════════════════════════════════════════╗
      ║                                                                       ║
      ║  🚀 IMPORTANT: Run this command to start monitoring:                  ║
      ║                                                                       ║
      ║                      vibe-check start                                 ║
      ║                                                                       ║
      ╚═══════════════════════════════════════════════════════════════════════╝

    EOS
    s
  end
end
