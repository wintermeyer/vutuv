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
      assert count(body, "Disallow: /admin/") == 2, "expected the path rules in both groups"
      assert count(body, "Allow: /\n") == 2
    end

    # The *rules* have to repeat per group, the *reasoning* does not. It used to
    # ride along in the same string, so the whole 29-line essay about why
    # nothing else is disallowed was printed once per group and the file was
    # 3.4 KB of mostly the same paragraphs. The prose now lives in the preamble
    # and is written once; a group is its User-agent lines plus two rules.
    test "explains itself once, not once per group" do
      for policy <- [:permissive, :block_training] do
        body = RobotsTxt.render(policy)

        for sentence <- ["A Disallow only", "Redirects stay crawlable", "linked nowhere"] do
          assert count(body, sentence) == 1,
                 "#{policy}: #{inspect(sentence)} should appear once, not per group"
        end
      end
    end

    test "stays small: the prose is written once, the rules are two lines a group" do
      # A guard on the shape, not the wording. The duplicated version was 3.4 KB
      # because each group dragged the whole explanation along; deduplicated it
      # is ~2.2 KB, nearly all of it the one-time preamble. If this trips again,
      # someone re-attached prose to a per-group block.
      assert byte_size(RobotsTxt.render(:permissive)) < 2_500
    end

    test "advertises the sitemap with an absolute URL" do
      assert RobotsTxt.render(:permissive) =~ "\nSitemap: http://localhost:4001/sitemap.xml\n"
    end

    test "leaves the legacy /users/ redirects crawlable so the 301 can consolidate them" do
      # The pre-2026 /users/:slug URLs 301 to the canonical /:slug profile.
      # Blocking them would stop Googlebot from ever seeing the redirect, so the
      # old URL is stranded in the index ("indexiert, obwohl durch robots.txt
      # blockiert"). Leaving them crawlable lets the 301 consolidate them.
      refute RobotsTxt.render(:permissive) =~ "Disallow: /users/"
    end

    test "fences off only the admin area; everything else resolves itself" do
      body = RobotsTxt.render(:permissive)

      assert body =~ "Disallow: /admin/"

      # /login and /search stay crawlable and carry X-Robots-Tag: noindex
      # instead: /login is the redirect target of every login-only URL a
      # crawler stumbles into (/posts/:id/reply, /messages, ...), so blocking
      # it stranded all those chains as "blocked by robots.txt" and kept the
      # Search Console validation failing.
      refute body =~ "Disallow: /login"
      refute body =~ "Disallow: /search"

      # GET /logout does not exist (signing out is a DELETE), /sessions/new is
      # a 301 that must be crawlable to consolidate, and /api/ answers 401/404
      # for a crawler by itself — the legacy /api/1.0 vcard URLs 301 to the
      # canonical /:slug.vcf and must be fetchable for that to happen.
      refute body =~ "Disallow: /logout"
      refute body =~ "Disallow: /sessions"
      refute body =~ "Disallow: /api/"
    end

    test "does not robots-block the per-user detail sub-pages (they carry X-Robots-Tag: noindex)" do
      # /:slug/emails, /:slug/tags, /:slug/work_experiences, ... are kept out of
      # search by the page-level noindex header (VutuvWeb.Plug.NoIndex on the
      # :user_pipe pipeline, see detail_pages_noindex_test.exs), not a robots
      # block. A Disallow only stops crawling, so a linked detail URL is still
      # indexed as a bare link and can never be crawled to see the noindex.
      body = RobotsTxt.render(:permissive)

      for section <- ~w(emails tags work_experiences educations followers following
                        links social_media_accounts addresses phone_numbers
                        languages qualifications connections) do
        refute body =~ "Disallow: /*/#{section}",
               "#{section} should rely on the noindex header, not a robots block"
      end
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

  # The two member choices are independent axes: noindex? answers the
  # search engines, noai? answers AI training and live AI retrieval. All
  # four combinations must hold.
  describe "ContentPolicy.signal_header/2" do
    test "both allowed signals the configured stance" do
      assert ContentPolicy.signal_header(false, false) ==
               "ai-train=yes, search=yes, ai-input=yes"
    end

    test "search opted out, AI allowed" do
      assert ContentPolicy.signal_header(true, false) ==
               "ai-train=yes, search=no, ai-input=yes"
    end

    test "search allowed, AI opted out" do
      assert ContentPolicy.signal_header(false, true) ==
               "ai-train=no, search=yes, ai-input=no"
    end

    test "both opted out signals all-no" do
      assert ContentPolicy.signal_header(true, true) ==
               "ai-train=no, search=no, ai-input=no"
    end
  end

  describe "ContentPolicy.robots_directives/2" do
    test "nothing to say for a fully permissive page" do
      assert ContentPolicy.robots_directives(false, false) == nil
    end

    test "search opt-out yields noindex" do
      assert ContentPolicy.robots_directives(true, false) == "noindex"
    end

    test "AI opt-out yields the noai directives" do
      assert ContentPolicy.robots_directives(false, true) == "noai, noimageai"
    end

    test "both opt-outs combine" do
      assert ContentPolicy.robots_directives(true, true) == "noindex, noai, noimageai"
    end
  end

  defp count(body, needle), do: length(String.split(body, needle)) - 1
end
