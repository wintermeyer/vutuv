defmodule Vutuv.MarkdownContent do
  @moduledoc """
  Content rules for user-written Markdown bodies (posts and direct messages):
  the small set of constructs a body may **not** carry. Rendering lives in
  `VutuvWeb.Markdown`; this is the storage-side guard shared by the
  `Vutuv.Posts.Post` and `Vutuv.Chat.Message` changesets, so every write path
  (the web composer, the API, an import) is validated the same way.
  """

  import Ecto.Changeset

  # Image Markdown `![alt](url)` — the one construct a body may not carry.
  # Images are never embedded inline: a post's uploaded pictures are attachments
  # shown as a gallery, and a message carries none at all.
  @image_markdown ~r/!\[[^\]]*\]\([^)]*\)/

  @doc """
  Reject a body that embeds an image. Code samples are exempt: `![](x)` inside a
  fenced or inline code span renders as literal text, not an image (the same
  distinction `VutuvWeb.Markdown` makes at render time), so it stays allowed.

  Pairs with the render-side drop (`VutuvWeb.Markdown` strips every `<img>`):
  this stops the Markdown from ever being **stored**, that stops any already
  stored `![](…)` from ever **displaying**.
  """
  def validate_no_images(changeset, field \\ :body) do
    body = get_field(changeset, field) || ""

    if Regex.match?(@image_markdown, strip_code(body)) do
      add_error(changeset, field, "must not contain images")
    else
      changeset
    end
  end

  # Ignore fenced (``` / ~~~) and inline (`code`) spans: image syntax there is
  # sample text, not a rendered image.
  defp strip_code(body) do
    body
    |> String.replace(~r/```[\s\S]*?```|~~~[\s\S]*?~~~/, "")
    |> String.replace(~r/`[^`]*`/, "")
  end
end
