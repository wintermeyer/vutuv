defmodule VutuvWeb.ContentPolicy do
  @moduledoc """
  The one source of the site's AI-use stance. `VutuvWeb.RobotsTxt` renders
  it as robots.txt `Content-Signal` directives and `VutuvWeb.AgentDocs`
  (plus the feeds) as the per-response `Content-Signal` header, so the two
  can never disagree.

  Configured via `config :vutuv, ai_crawler_policy:` —

    * `:permissive` (default) — all AI crawlers welcome; search, live AI
      input and training all allowed. vutuv exists to give members reach.
    * `:block_training` — search and retrieval stay allowed, training
      crawlers are blocked and `ai-train=no` is declared.

  On top of the site stance every member answers two independent
  questions: `noindex?` (may search engines index my profile?) and `noai?`
  (may AI agents and LLMs use my content — training and live retrieval?).
  All four combinations are valid; `signal_header/2` and
  `robots_directives/2` render them per page.
  """

  def policy do
    Application.get_env(:vutuv, :ai_crawler_policy, :permissive)
  end

  @doc """
  The `Content-Signal` header value for a page. `noindex?` is the page's
  (or member's) search opt-out, `noai?` the AI opt-out; the two axes are
  independent. `ai-train` additionally requires the permissive site stance.
  """
  def signal_header(noindex?, noai?) do
    render_signals(policy() == :permissive and not noai?, not noindex?, not noai?)
  end

  @doc """
  The robots directives a page's meta tag / `X-Robots-Tag` header should
  carry for these opt-outs: `noindex` for search engines, the
  `noai, noimageai` pair (the de-facto AI-crawler vocabulary) for AI use.
  `nil` when there is nothing to declare.
  """
  def robots_directives(noindex?, noai?)
  def robots_directives(false, false), do: nil
  def robots_directives(true, false), do: "noindex"
  def robots_directives(false, true), do: "noai, noimageai"
  def robots_directives(true, true), do: "noindex, noai, noimageai"

  @doc false
  def render_signals(train?, search?, input?) do
    "ai-train=#{yn(train?)}, search=#{yn(search?)}, ai-input=#{yn(input?)}"
  end

  defp yn(true), do: "yes"
  defp yn(false), do: "no"
end
