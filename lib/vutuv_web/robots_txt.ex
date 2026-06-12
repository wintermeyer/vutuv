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

  @header """
  # robots.txt for vutuv.de
  #
  # vutuv is the friendly social/business network.
  # Humans and robots are welcome and overly enthusiastic crawlers
  # are politely asked to read the house rules.
  """

  @path_rules """
  # Help yourself to the public stuff: profiles, tags, listings.
  Allow: /

  # ...but these are backstage. No autographs, no peeking.
  Disallow: /admin/
  Disallow: /login
  Disallow: /logout
  Disallow: /sessions
  Disallow: /api/

  # Search results are an endless hall of mirrors; don't get lost in there.
  Disallow: /search

  # The old /users/... URLs are permanent redirects now; skip the detour.
  Disallow: /users/

  # Personal profile detail pages (phone numbers, emails, addresses, links,
  # social media, work history, followers, ...) are off-limits. The profile
  # page /<slug> itself stays crawlable; only its sub-pages are blocked.
  Disallow: /*/addresses
  Disallow: /*/connections
  Disallow: /*/edit
  Disallow: /*/emails
  Disallow: /*/followers
  Disallow: /*/following
  Disallow: /*/groups
  Disallow: /*/links
  Disallow: /*/phone_numbers
  Disallow: /*/search_terms
  Disallow: /*/slugs
  Disallow: /*/social_media_accounts
  Disallow: /*/tags
  Disallow: /*/work_experiences
  """

  # The AI crawlers named explicitly (the spec's list): training collects
  # for model training, retrieval fetches for live search/answers. Under
  # :permissive both sets share one welcoming group; under :block_training
  # the training set is blocked outright.
  @training_bots ~w(GPTBot anthropic-ai Google-Extended Applebot-Extended Bytespider CCBot)
  @retrieval_bots ~w(OAI-SearchBot ChatGPT-User ClaudeBot PerplexityBot)

  def render(:permissive) do
    [
      @header,
      group("everyone", ["*"], @path_rules, ContentPolicy.render_signals(true, true, true)),
      "\n# AI crawlers are welcome too — same house rules, said explicitly.\n",
      group(nil, @training_bots ++ @retrieval_bots, @path_rules, allowed_signals(:permissive)),
      sitemap_line()
    ]
    |> IO.iodata_to_binary()
  end

  def render(:block_training) do
    [
      @header,
      group("everyone", ["*"], @path_rules, allowed_signals(:block_training)),
      "\n# Retrieval and AI search may read; model training may not.\n",
      group(nil, @retrieval_bots, @path_rules, allowed_signals(:block_training)),
      "\n# Training crawlers sit this one out.\n",
      group(nil, @training_bots, "Disallow: /\n", ContentPolicy.render_signals(false, false, false)),
      sitemap_line()
    ]
    |> IO.iodata_to_binary()
  end

  defp allowed_signals(policy), do: ContentPolicy.render_signals(policy == :permissive, true, true)

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
