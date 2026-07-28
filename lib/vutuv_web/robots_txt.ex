defmodule VutuvWeb.RobotsTxt do
  @moduledoc """
  Renders robots.txt for the configured AI-crawler policy (see
  `VutuvWeb.ContentPolicy`). A pure function of the policy, so both
  stances stay unit-testable; the controller passes
  `ContentPolicy.policy/0`.

  robots.txt groups do not inherit from `User-agent: *`, so every allowed
  group carries its own copy of the sensitive-path rules. `Content-Signal`
  is the (draft) IETF/Cloudflare vocabulary — `search`, `ai-input`,
  `ai-train` — declared per group.
  """

  alias VutuvWeb.ContentPolicy

  # Built at call time so the comment names the installation's own host.
  defp header do
    """
    # robots.txt for #{VutuvWeb.Endpoint.host()}
    #
    # vutuv is the friendly social/business network.
    # Humans and robots are welcome and overly enthusiastic crawlers
    # are politely asked to read the house rules.
    """
  end

  @path_rules """
  # Help yourself to the public stuff: profiles, tags, listings.
  Allow: /

  # ...but the admin area is backstage. No autographs, no peeking.
  Disallow: /admin/

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

  # The AI crawlers named explicitly (the spec's list): training collects
  # for model training, retrieval fetches for live search/answers. Under
  # :permissive both sets share one welcoming group; under :block_training
  # the training set is blocked outright.
  @training_bots ~w(GPTBot anthropic-ai Google-Extended Applebot-Extended Bytespider CCBot)
  @retrieval_bots ~w(OAI-SearchBot ChatGPT-User ClaudeBot PerplexityBot)

  def render(:permissive) do
    [
      header(),
      group("everyone", ["*"], @path_rules, ContentPolicy.render_signals(true, true, true)),
      "\n# AI crawlers are welcome too — same house rules, said explicitly.\n",
      group(nil, @training_bots ++ @retrieval_bots, @path_rules, allowed_signals(:permissive)),
      sitemap_line()
    ]
    |> IO.iodata_to_binary()
  end

  def render(:block_training) do
    [
      header(),
      group("everyone", ["*"], @path_rules, allowed_signals(:block_training)),
      "\n# Retrieval and AI search may read; model training may not.\n",
      group(nil, @retrieval_bots, @path_rules, allowed_signals(:block_training)),
      "\n# Training crawlers sit this one out.\n",
      group(
        nil,
        @training_bots,
        "Disallow: /\n",
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
      if(comment, do: "\n# Rules for #{comment}:\n", else: "\n"),
      Enum.map(agents, &"User-agent: #{&1}\n"),
      rules,
      "Content-Signal: #{signals}\n"
    ]
  end

  defp sitemap_line, do: "\nSitemap: #{VutuvWeb.Endpoint.url()}/sitemap.xml\n"
end
