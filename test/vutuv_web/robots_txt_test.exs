defmodule VutuvWeb.RobotsTxtTest do
  @moduledoc """
  The robots.txt renderer and the one AI-use policy source behind it.
  `VutuvWeb.ContentPolicy` owns the site stance (config
  `:ai_crawler_policy`); robots.txt directives and the per-response
  `Content-Signal` header both render from it, so they cannot disagree.
  """

  use ExUnit.Case, async: true

  alias VutuvWeb.ContentPolicy
  alias VutuvWeb.RobotsTxt

  @named_bots ~w(GPTBot OAI-SearchBot ChatGPT-User ClaudeBot anthropic-ai
                 Google-Extended Applebot-Extended PerplexityBot Bytespider CCBot)

  describe "render(:permissive)" do
    test "names every AI crawler and welcomes it" do
      body = RobotsTxt.render(:permissive)

      for bot <- @named_bots do
        assert body =~ "User-agent: #{bot}\n", "missing group for #{bot}"
      end

      refute body =~ "Disallow: /\n"
    end

    test "declares all-yes Content-Signals" do
      body = RobotsTxt.render(:permissive)

      assert body =~ "Content-Signal: ai-train=yes, search=yes, ai-input=yes"
      refute body =~ "ai-train=no"
    end

    test "repeats the path rules in the named group (no inheritance from *)" do
      body = RobotsTxt.render(:permissive)

      # Each group carries its own copy of the sensitive-path rules.
      occurrences = body |> String.split("Disallow: /*/emails") |> length()
      assert occurrences == 3, "expected the path rules in both groups"
    end

    test "advertises the sitemap with an absolute URL" do
      assert RobotsTxt.render(:permissive) =~ "\nSitemap: http://localhost:4001/sitemap.xml\n"
    end
  end

  describe "render(:block_training)" do
    test "blocks the training crawlers outright" do
      body = RobotsTxt.render(:block_training)

      for bot <- ~w(GPTBot anthropic-ai Google-Extended Applebot-Extended Bytespider CCBot) do
        assert body =~ ~r/User-agent: #{Regex.escape(bot)}\n(User-agent: [^\n]+\n)*Disallow: \/\n/,
               "#{bot} should be in the blocked group"
      end
    end

    test "keeps retrieval and search bots allowed, without training" do
      body = RobotsTxt.render(:block_training)

      for bot <- ~w(OAI-SearchBot ChatGPT-User ClaudeBot PerplexityBot) do
        assert body =~ "User-agent: #{bot}\n"
      end

      assert body =~ "Content-Signal: ai-train=no, search=yes, ai-input=yes"
      refute body =~ "ai-train=yes"
    end
  end

  describe "ContentPolicy.signal_header/1" do
    test "a noindexed page signals all-no regardless of policy" do
      assert ContentPolicy.signal_header(true) == "ai-train=no, search=no, ai-input=no"
    end

    test "an indexable page signals the configured stance" do
      assert ContentPolicy.signal_header(false) == "ai-train=yes, search=yes, ai-input=yes"
    end
  end
end
