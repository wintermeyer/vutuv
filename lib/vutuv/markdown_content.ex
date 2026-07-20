defmodule Vutuv.MarkdownContent do
  @moduledoc """
  Content rules for user-written Markdown bodies (posts and direct messages):
  the small set of constructs a body may **not** carry. Rendering lives in
  `VutuvWeb.Markdown`; this is the storage-side guard shared by the
  `Vutuv.Posts.Post` and `Vutuv.Chat.Message` changesets, so every write path
  (the web composer, the API, an import) is validated the same way.
  """

  import Ecto.Changeset

  # Image Markdown `![alt](url)`.
  @image_markdown ~r/!\[[^\]]*\]\([^)]*\)/

  # The one src form a post body may embed: a served version of an uploaded
  # post image (`Vutuv.Posts.PostImage.url/2`, incl. the legacy pre-AVIF
  # `.webp` form old bodies carry), optionally with an alignment fragment
  # (`#left` / `#right` / `#center`; no fragment = full width). Whether the
  # token really belongs to this post's author is enforced at render time
  # (`VutuvWeb.Markdown.render_post/2` only inlines the post's own
  # attachments), so a foreign token stores but never displays.
  @own_upload_src ~r{\A/post_images/[A-Za-z0-9_-]+/(thumb|feed|large)\.(avif|webp)(#(left|right|center))?\z}

  @doc """
  Reject a body that embeds an image. Code samples are exempt: `![](x)` inside a
  fenced or inline code span renders as literal text, not an image (the same
  distinction `VutuvWeb.Markdown` makes at render time), so it stays allowed.

  Pairs with the render-side drop (`VutuvWeb.Markdown` strips every `<img>`):
  this stops the Markdown from ever being **stored**, that stops any already
  stored `![](…)` from ever **displaying**. Message, organization and job
  posting bodies stay image-free; post bodies use
  `validate_own_images_only/2` instead.
  """
  def validate_no_images(changeset, field \\ :body) do
    body = get_field(changeset, field) || ""

    if Regex.match?(@image_markdown, strip_code(body)) do
      add_error(changeset, field, "must not contain images")
    else
      changeset
    end
  end

  @doc """
  Allow only inline images that reference an **uploaded post image** (the
  `/post_images/<token>/<version>` proxy URL scheme, plus an optional
  alignment fragment). A hotlinked remote image is rejected — it would leak
  every reader's IP to a third party — and so is any other src form. Code
  samples stay exempt, like in `validate_no_images/2`.
  """
  def validate_own_images_only(changeset, field \\ :body) do
    body = get_field(changeset, field) || ""

    foreign? =
      @image_markdown
      |> Regex.scan(strip_code(body))
      |> Enum.any?(fn [markdown] ->
        src = image_src(markdown)
        not Regex.match?(@own_upload_src, src)
      end)

    if foreign? do
      add_error(changeset, field, "may only embed images uploaded to this post")
    else
      changeset
    end
  end

  defp image_src(markdown) do
    case Regex.run(~r/!\[[^\]]*\]\(([^)\s]*)[^)]*\)/, markdown) do
      [_, src] -> src
      _ -> ""
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
