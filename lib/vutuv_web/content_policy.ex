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

  Per-member opt-out stays all-or-nothing on purpose ("safer", per product
  decision): a noindexed page sends every signal as no, whatever the
  site-wide policy says.
  """

  def policy do
    Application.get_env(:vutuv, :ai_crawler_policy, :permissive)
  end

  @doc """
  The `Content-Signal` header value for a page; `noindex?` is the page's
  (or member's) opt-out state.
  """
  def signal_header(noindex?)
  def signal_header(true), do: render_signals(false, false, false)
  def signal_header(false), do: render_signals(policy() == :permissive, true, true)

  @doc false
  def render_signals(train?, search?, input?) do
    "ai-train=#{yn(train?)}, search=#{yn(search?)}, ai-input=#{yn(input?)}"
  end

  defp yn(true), do: "yes"
  defp yn(false), do: "no"
end
