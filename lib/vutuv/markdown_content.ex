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
  # `.webp` form old bodies carry), optionally with the crop cache-buster a
  # cropped photo's URL carries (`?v=<hash>`) and an alignment fragment
  # (`#left` / `#right` / `#center`; no fragment = full width). Whether the
  # token really belongs to this post's author is enforced at render time
  # (`VutuvWeb.Markdown.render_post/2` only inlines the post's own
  # attachments), so a foreign token stores but never displays.
  @own_upload_src ~r{\A/post_images/[A-Za-z0-9_-]+/(thumb|feed|large)\.(avif|webp)(\?v=[A-Za-z0-9_-]+)?(#(left|right|center))?\z}

  @doc """
  Reject a body that embeds an image. Code samples are exempt: `![](x)` inside a
  fenced or inline code span renders as literal text, not an image (the same
  distinction `VutuvWeb.Markdown` makes at render time), so it stays allowed.

  Pairs with the render-side drop (`VutuvWeb.Markdown` strips every `<img>`):
  this stops the Markdown from ever being **stored**, that stops any already
  stored `![](…)` from ever **displaying**. Message, organization and job
  posting bodies stay image-free; post bodies use
  `validate_no_new_images/2` instead.
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
  A post body takes no new picture: a photo is an attachment, and the editor
  refuses a dropped or pasted file. What stays allowed is a reference the
  **stored** body already carries — a post written before this rule keeps its
  inline pictures through an edit — and only in the own-upload form
  (`/post_images/<token>/<version>`), never a hotlink that would leak every
  reader's IP. Code samples stay exempt, like in `validate_no_images/2`.
  """
  def validate_no_new_images(changeset, field \\ :body) do
    stored = changeset.data |> Map.get(field) |> image_srcs() |> MapSet.new()

    added? =
      (get_field(changeset, field) || "")
      |> image_srcs()
      |> Enum.any?(&(not MapSet.member?(stored, &1) or not Regex.match?(@own_upload_src, &1)))

    if added? do
      add_error(changeset, field, "must not contain images")
    else
      changeset
    end
  end

  defp image_srcs(nil), do: []

  defp image_srcs(body) do
    @image_markdown
    |> Regex.scan(strip_code(body))
    |> Enum.map(fn [markdown] -> image_src(markdown) end)
  end

  defp image_src(markdown) do
    case Regex.run(~r/!\[[^\]]*\]\(([^)\s]*)[^)]*\)/, markdown) do
      [_, src] -> src
      _ -> ""
    end
  end

  @doc """
  A body with its fenced (``` / ~~~) and inline (`code`) spans removed.

  Two readers, one rule. The image guard here needs it because image syntax
  inside code is sample text, not a rendered image; the language detector
  (`Vutuv.Translations.Detector`) needs it because a code block is not prose
  and would have the model reading a post's language off its identifiers.
  """
  def strip_code(body) do
    body
    |> String.replace(~r/```[\s\S]*?```|~~~[\s\S]*?~~~/, "")
    |> String.replace(~r/`[^`]*`/, "")
  end

  @doc """
  `body` without its embedded images (`@image_markdown`), for a surface that
  shows a post's pictures on their own and would otherwise show each twice.
  """
  def strip_images(body), do: Regex.replace(@image_markdown, body, "")
end
