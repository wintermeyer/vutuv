defmodule VutuvWeb.OpenGraph do
  @moduledoc """
  The link-preview head tags (Open Graph + `twitter:card`) on every HTML
  page — what WhatsApp, Facebook, LinkedIn, Signal and X render when a
  vutuv URL is shared. The root layout renders `tags/1`; the derivation is
  one chokepoint over the conn assigns:

    * a page about a member (`:user` — the profile, its sections, their
      posts): the member's name as title, their work info as description,
      their avatar as image. The avatar is linked as `/:slug/avatar.jpg`
      (`VutuvWeb.AvatarController`) because preview scrapers don't decode
      the AVIF the site serves itself.
    * a visible, unrestricted post additionally previews its first line
      and publication date; restricted posts and teasers never put the
      body into a tag.
    * everything else: the site description and the generated brand card
      (`VutuvWeb.OgCard`).

  The plain `<meta name="description">` renders `description/1` too, so
  the two can never disagree.
  """

  use Gettext, backend: VutuvWeb.Gettext

  alias Vutuv.Accounts.User
  alias Vutuv.Posts.Post
  alias VutuvWeb.OgCard
  alias VutuvWeb.UserHelpers

  @doc "The Open Graph tags for this page, as `{property, content}` pairs."
  def tags(assigns) do
    ca = conn_assigns(assigns)

    [
      {"og:site_name", "vutuv"},
      {"og:type", type(ca)},
      {"og:title", VutuvWeb.LayoutHTML.page_title(assigns) || "vutuv"},
      {"og:description", description(assigns)},
      {"og:locale", og_locale(assigns)}
    ] ++ url_tags(assigns) ++ article_tags(ca) ++ image_tags(image(ca))
  end

  @doc """
  The twitter:card kind matching `tags/1`'s image: `summary` beside a
  square avatar, `summary_large_image` for the wide brand card.
  """
  def twitter_card(assigns) do
    case image(conn_assigns(assigns)) do
      %{card: card} -> card
      nil -> "summary"
    end
  end

  @doc """
  The page description, shared by `<meta name="description">` and
  `og:description`: the post's first line (public posts only), else the
  member's work info, else the site pitch — never empty.
  """
  def description(assigns) do
    ca = conn_assigns(assigns)

    post_excerpt(ca) || member_info(ca) ||
      gettext(
        "Your Fast and Free Career Network. No expensive premium accounts! Get a free account in 30 seconds."
      )
  end

  defp conn_assigns(%{conn: %Plug.Conn{} = conn}), do: conn.assigns
  defp conn_assigns(_assigns), do: %{}

  defp type(%{post: %Post{}}), do: "article"
  defp type(%{user: %User{}}), do: "profile"
  defp type(_ca), do: "website"

  # Only the post show page assigns :post (with :restricted?); the body of
  # a restricted post must not surface in a tag (the teaser page doesn't
  # assign :post at all, so it falls through to the author's info).
  defp post_excerpt(%{post: %Post{} = post, restricted?: false}),
    do: VutuvWeb.AgentDocs.excerpt(post.body)

  defp post_excerpt(_ca), do: nil

  defp member_info(%{user: %User{} = user} = ca) do
    case user
         |> UserHelpers.meta_description(ca[:user_tags], ca[:header_job])
         |> IO.iodata_to_binary() do
      "" -> nil
      text -> text
    end
  end

  defp member_info(_ca), do: nil

  defp og_locale(assigns) do
    case assigns[:locale] do
      "de" -> "de_DE"
      _ -> "en_US"
    end
  end

  defp url_tags(%{conn: %Plug.Conn{} = conn}) do
    [{"og:url", VutuvWeb.Endpoint.url() <> canonical_path(conn.request_path)}]
  end

  defp url_tags(_assigns), do: []

  defp canonical_path("/"), do: "/"
  defp canonical_path(path), do: String.replace_suffix(path, "/", "")

  defp article_tags(%{post: %Post{} = post}),
    do: [{"article:published_time", Date.to_iso8601(post.published_on)}]

  defp article_tags(_ca), do: []

  defp image(%{user: %User{avatar: avatar} = user}) when not is_nil(avatar) do
    size = Vutuv.Avatar.og_size()

    %{
      url: abs_url("/#{user.active_slug}/avatar.jpg"),
      width: size,
      height: size,
      type: "image/jpeg",
      alt: UserHelpers.full_name(user),
      card: "summary"
    }
  end

  defp image(_ca) do
    case OgCard.png() do
      {:ok, _png} ->
        %{
          url: abs_url("/og-card.png"),
          width: OgCard.width(),
          height: OgCard.height(),
          type: "image/png",
          alt: "vutuv",
          card: "summary_large_image"
        }

      :error ->
        nil
    end
  end

  defp image_tags(nil), do: []

  defp image_tags(image) do
    [
      {"og:image", image.url},
      {"og:image:width", Integer.to_string(image.width)},
      {"og:image:height", Integer.to_string(image.height)},
      {"og:image:type", image.type},
      {"og:image:alt", image.alt}
    ]
  end

  defp abs_url(path), do: VutuvWeb.Endpoint.url() <> path
end
