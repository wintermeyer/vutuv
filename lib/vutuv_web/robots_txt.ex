defmodule VutuvWeb.RobotsTxt do
  @moduledoc """
  Renders robots.txt for the configured AI-crawler policy (see
  `VutuvWeb.ContentPolicy`). A pure function of the policy, so both
  stances stay unit-testable; the controller passes
  `ContentPolicy.policy/0`.

  robots.txt groups do not inherit from `User-agent: *`, so every allowed
  group carries its own copy of the path rules. Only the *rules* repeat:
  the reasoning behind them used to sit in the same string and was
  therefore printed once per group, which is what made the file 3.4 KB of
  the same paragraphs over and over. The prose lives in `preamble/0` now
  and is written once, so a group is its User-agent lines plus two rules.
  `Content-Signal` is the (draft) IETF/Cloudflare vocabulary (`search`,
  `ai-input`, `ai-train`), declared per group.
  """

  alias VutuvWeb.ContentPolicy

  # Built at call time so the comment names the installation's own host.
  defp preamble do
    """
    # robots.txt for #{VutuvWeb.Endpoint.host()}
    #
    # vutuv is the friendly social/business network.
    # Humans and robots are welcome and overly enthusiastic crawlers
    # are politely asked to read the house rules.
    #
    # The rules are short on purpose: help yourself to the public stuff
    # (profiles, tags, listings), but the admin area is backstage, no
    # autographs, no peeking. Every welcome group below repeats those two
    # lines, because robots.txt groups do not inherit from `User-agent: *`.
    #
    # Everything else that must stay out of search is DELIBERATELY not
    # disallowed, though several paths look like candidates. A Disallow only
    # stops the fetch: a URL linked from elsewhere still gets indexed as a
    # bare link, can never be crawled to learn it should drop out, and a
    # redirect on it can never consolidate. So instead:
    #
    # 1. Redirects stay crawlable so their 301 can do its job: the old
    #    /users/... URLs (-> /<slug>), /sessions/new (-> /login) and the
    #    legacy /api/1.0/users/<slug>/vcard URLs (-> /<slug>.vcf).
    #
    # 2. Pages that must never surface in results carry a page-level
    #    `X-Robots-Tag: noindex` and stay crawlable precisely so that header
    #    is seen: the personal profile detail sub-pages (/<slug>/emails,
    #    /tags, /work_experiences, /followers, ...; VutuvWeb.Plug.NoIndex),
    #    the RSS feeds, /login and /search. Keeping /login fetchable also
    #    lets the sign-in redirect behind every login-only URL a crawler
    #    stumbles into (/posts/<id>/reply, /messages, ...) resolve cleanly
    #    instead of stranding those URLs as "blocked by robots.txt".
    #
    # 3. /api/ is linked nowhere and answers every crawler itself: 404/301
    #    for the legacy 1.0 paths, 401 for the token-only 2.0 endpoints.
    """
  end

  @path_rules "Allow: /\nDisallow: /admin/\n"
  @blocked_rules "Disallow: /\n"

  # The AI crawlers named explicitly (the spec's list): training collects
  # for model training, retrieval fetches for live search/answers. Under
  # :permissive both sets share one welcoming group; under :block_training
  # the training set is blocked outright.
  @training_bots ~w(GPTBot anthropic-ai Google-Extended Applebot-Extended Bytespider CCBot)
  @retrieval_bots ~w(OAI-SearchBot ChatGPT-User ClaudeBot PerplexityBot)

  def render(:permissive) do
    [
      preamble(),
      group("everyone", ["*"], @path_rules, ContentPolicy.render_signals(true, true, true)),
      group(
        "AI crawlers, same house rules said explicitly",
        @training_bots ++ @retrieval_bots,
        @path_rules,
        allowed_signals(:permissive)
      ),
      sitemap_line()
    ]
    |> IO.iodata_to_binary()
  end

  def render(:block_training) do
    [
      preamble(),
      group("everyone", ["*"], @path_rules, allowed_signals(:block_training)),
      group(
        "retrieval and AI search, which may read",
        @retrieval_bots,
        @path_rules,
        allowed_signals(:block_training)
      ),
      group(
        "training crawlers, which sit this one out",
        @training_bots,
        @blocked_rules,
        ContentPolicy.render_signals(false, false, false)
      ),
      sitemap_line()
    ]
    |> IO.iodata_to_binary()
  end

  defp allowed_signals(policy),
    do: ContentPolicy.render_signals(policy == :permissive, true, true)

  defp group(comment, agents, rules, signals) do
    [
      "\n# Rules for #{comment}:\n",
      Enum.map(agents, &"User-agent: #{&1}\n"),
      rules,
      "Content-Signal: #{signals}\n"
    ]
  end

  defp sitemap_line, do: "\nSitemap: #{VutuvWeb.Endpoint.url()}/sitemap.xml\n"
end
