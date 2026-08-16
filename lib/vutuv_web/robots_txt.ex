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

  alias Vutuv.Fediverse
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

  @doc """
  The file the **tag host** answers with (issue #1330): a different document,
  because that host is a different kind of thing.

  `tags.<our host>` carries the ActivityPub address of every topic and nothing
  anybody reads, so none of it belongs in a search index — and saying that is
  the whole file. What it must **not** say is `Disallow: /`, which is how a URL
  gets *stuck* in an index rather than kept out of one: a Disallow stops the
  fetch, so the redirect can never consolidate and the `X-Robots-Tag: noindex`
  every response here carries is never read, leaving anything already indexed
  stranded as a bare link. That is the same mistake this project shipped on the
  apex once (v7.106.3, 44 URLs reported by Search Console as "indexed, though
  blocked by robots.txt"), and it is worth stating twice.
  """
  def tag_host do
    """
    # robots.txt for #{Fediverse.tag_host()}
    #
    # This host carries the fediverse address of every topic on #{VutuvWeb.Endpoint.host()}.
    # Nothing on it is for reading: ask it for a page and you are redirected to
    # #{VutuvWeb.Endpoint.url()}, ask it for a topic and you land on that topic's
    # page there. Every answer it gives also carries the header
    # `X-Robots-Tag: noindex, noai, noimageai`.
    #
    # So nothing here belongs in a search index or a training corpus, and
    # crawling is DELIBERATELY still allowed, because a `Disallow: /` is how a
    # URL gets stuck in an index rather than kept out of one: it stops the
    # fetch, and a URL nobody may fetch is one whose noindex is never read and
    # whose redirect can never consolidate. Fetch it, read the header, drop the
    # URL. That is the fastest way for this host to disappear from your results,
    # which is what both of us want.

    User-agent: *
    Allow: /
    Content-Signal: #{ContentPolicy.render_signals(false, false, false)}
    """
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
