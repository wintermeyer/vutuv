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
end
