defmodule Vutuv.Profiles.LinkBadges do
  @moduledoc """
  The badges and copy-and-paste snippets a member puts on their own homepage to
  link their profile here.

  It lives beside `Vutuv.Profiles.LinkVerification` rather than in the media
  kit that shows it, because a snippet is not only decoration: every HTML one
  carries `rel="me"`, which is the exact back-link that module goes looking for
  when it verifies that a page belongs to a member. So the catalog encodes a
  verification rule, and the rule's owner is here. Two surfaces render it — the
  media kit (`VutuvWeb.AgentDocs.MediaKitDoc`) and the link-verification page,
  where a member is mid-proof and needs the line most.

  Nothing here is translated. The badge images carry no words at all — mark plus
  wordmark, never "Find me on": a badge with a sentence in it needs one file per
  language and ages the day the sentence changes. The page around it on
  somebody's own site supplies the words, and the button snippet writes them in
  HTML where the member can edit them.
  """

  alias Vutuv.Profiles.LinkVerification

  # The stand-in handle in every snippet, and the token the handle field in
  # `link_badges.js` swaps out. A token rather than a plausible name, so a
  # member who pastes without reading ends up with an address that is obviously
  # unfinished instead of silently linking a stranger who holds that handle.
  @handle_token "__HANDLE__"
  @handle_placeholder "your-handle"

  @icon_path "/images/brand/vutuv-mark.svg"
  @icon_size 28

  @doc "The stand-in handle an anonymous reader sees in every snippet."
  def handle_placeholder, do: @handle_placeholder

  @doc """
  The badge images, each `%{name:, note:, path:, width:, height:, dark_plate?:}`.

  `dark_plate?` says whether a preview needs a dark surface behind it, and it is
  a field rather than a guess at the filename because getting it wrong is
  invisible in code and obvious on screen: a badge drawn on the very colour it
  is made of has no edge, so it reads as loose glyphs rather than as a badge.

  The icon mark is deliberately **not** in this list. It is already a brand
  asset the media kit offers (`MediaKitDoc.assets/0`), and one file under two
  names in two catalogs is two notes that drift; the icon snippet below points
  at that same file.
  """
  def badges do
    [
      %{
        name: "Badge",
        note: "For a light page. SVG, 130x40.",
        path: "/images/brand/vutuv-badge.svg",
        width: 130,
        height: 40,
        dark_plate?: false
      },
      %{
        name: "Badge, dark",
        note: "The same badge for a dark page.",
        path: "/images/brand/vutuv-badge-dark.svg",
        width: 130,
        height: 40,
        dark_plate?: true
      }
    ]
  end

  @doc "The badge by `key`, for a snippet that draws one."
  def badge(name), do: Enum.find(badges(), &(&1.name == name))

  @doc """
  The one sentence that introduces the catalog wherever it is shown, so the
  page, its `.md` sibling and its `.txt` sibling cannot say three slightly
  different things about what `rel="me"` buys.
  """
  def intro do
    "Put your vutuv profile on your own site. Swap #{@handle_placeholder} for your handle. " <>
      "Every HTML snippet carries rel=\"me\", which is also how vutuv verifies that the " <>
      "page is yours."
  end

  @doc """
  The snippets, each `%{key:, name:, note:, language:, code:, template:}`.

  `code` is finished — `handle` is already in it. `template` is the same string
  with `#{@handle_token}` still standing where the handle goes, which the handle
  field on the media kit rewrites without a reload; a surface that does not
  offer that field can ignore it.

  Absolute URLs throughout, because these are pasted onto somebody else's site
  where a root-relative path names their server rather than ours. Every HTML
  snippet carries `rel="me"`; `company_controller_test.exs` reads them back
  through `Vutuv.WebVerification.rel_me_hrefs/1`, the very parser that reads a
  member's page, so a badge that quietly stops proving anything fails the build.
  """
  def snippets(handle \\ @handle_placeholder) do
    Enum.map(raw_snippets(), fn snippet ->
      Map.merge(snippet, %{
        template: snippet.code,
        code: fill(snippet.code, handle)
      })
    end)
  end

  @doc "Puts `handle` into a snippet template wherever the placeholder stands."
  def fill(template, handle), do: String.replace(template, @handle_token, handle)

  defp raw_snippets do
    badge = badge("Badge")
    dark = badge("Badge, dark")

    [
      %{
        key: "text",
        name: "A plain link",
        note:
          "Works everywhere, including the places that strip images. The address as the " <>
            "link text so a reader sees where it goes.",
        language: "html",
        code: ~s|<a href="#{profile_url()}" rel="me">#{link_text()}</a>|
      },
      %{
        key: "icon",
        name: "An icon",
        note: "For a row of social icons beside the others.",
        language: "html",
        code: """
        <a href="#{profile_url()}" rel="me" title="vutuv">
          <img src="#{asset_url(@icon_path)}" alt="vutuv"
               width="#{@icon_size}" height="#{@icon_size}" style="border-radius:6px">
        </a>\
        """
      },
      %{
        key: "badge",
        name: "A badge",
        note: "The finished image, nothing to style.",
        language: "html",
        code: """
        <a href="#{profile_url()}" rel="me">
          #{img(badge)}
        </a>\
        """
      },
      %{
        key: "badge_auto",
        name: "A badge that follows the reader's dark mode",
        note: "The same badge, swapped for the dark one where the reader is in the dark.",
        language: "html",
        code: """
        <a href="#{profile_url()}" rel="me">
          <picture>
            <source srcset="#{asset_url(dark.path)}" media="(prefers-color-scheme: dark)">
            #{img(badge)}
          </picture>
        </a>\
        """
      },
      %{
        key: "button",
        name: "A button in your own words",
        note: "Change the text and the colour; the link and the icon are all that matter.",
        language: "html",
        code: """
        <a href="#{profile_url()}" rel="me"
           style="display:inline-flex;align-items:center;gap:8px;padding:9px 14px;
                  border-radius:8px;background:#2563EB;color:#fff;text-decoration:none;
                  font:600 14px/1 system-ui,sans-serif">
          <img src="#{asset_url(@icon_path)}" alt="" width="18" height="18"
               style="border-radius:4px">
          #{@handle_token} on vutuv
        </a>\
        """
      },
      %{
        key: "markdown",
        name: "Markdown, for a README",
        note:
          "Markdown has nowhere to put rel=\"me\", so this one links but proves nothing. " <>
            "Use one of the HTML snippets on a page you control if you want the verified mark.",
        language: "markdown",
        code: "[![vutuv](#{asset_url(badge.path)})](#{profile_url()})"
      }
    ]
  end

  # The `<img>` for a badge, so its file and its dimensions are read from the
  # catalog entry rather than spelled again per snippet — resizing a badge would
  # otherwise mean editing four string literals.
  defp img(badge) do
    ~s|<img src="#{asset_url(badge.path)}" alt="vutuv"| <>
      ~s| width="#{badge.width}" height="#{badge.height}">|
  end

  defp profile_url, do: LinkVerification.profile_url(@handle_token)

  # The link text of the plain-link snippet: the address without its scheme,
  # which is how a person writes one down. Host and all, so a reader of somebody
  # else's page can see which installation it points at.
  defp link_text, do: String.replace(profile_url(), ~r{^https?://}, "")

  defp asset_url(path), do: VutuvWeb.Endpoint.url() <> path
end
