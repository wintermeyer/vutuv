defmodule Vutuv.SocialFeed.Post do
  @moduledoc """
  One remote social post as the profile page shows it: sanitized plain text,
  the post's URL on its home network, and when it was posted. Built
  exclusively by the provider clients' `fetch_posts/1`; the `text` is already
  reduced to plain text there (never render it with `raw/1`).

  `html` is presentation data the web layer fills in
  (`VutuvWeb.UserProfileLive` via `VutuvWeb.Markdown.render_remote/1`): the
  `text` run through the member-post pipeline — links, Markdown, hashtag
  linking, sanitized — so *that* field is safe for `raw/1`. It stays nil in
  the cache.
  """

  defstruct [:id, :url, :text, :html, :created_at]

  @type t :: %__MODULE__{
          id: String.t(),
          url: String.t(),
          text: String.t(),
          html: String.t() | nil,
          created_at: DateTime.t()
        }

  # Remote post text is clamped to this many characters (with an ellipsis) in
  # both provider feeds.
  @max_text_length 500

  @doc "The trimmed value, or nil when it is blank/whitespace-only."
  def presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def presence(_value), do: nil

  @doc "Clamps remote post text to #{@max_text_length} characters with a trailing ellipsis."
  def truncate(text), do: truncate(text, @max_text_length)

  @doc """
  Clamps `text` to `max` characters, replacing the tail with a trailing ellipsis
  when it runs over (the shared clamp `Vutuv.CodeStats.Snapshot` reuses for its
  own, shorter description cap).
  """
  def truncate(text, max) do
    if String.length(text) > max do
      String.slice(text, 0, max - 1) <> "…"
    else
      text
    end
  end
end
