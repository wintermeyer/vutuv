defmodule VutuvWeb.OpenGraph do
  @moduledoc """
  The link-preview head tags (Open Graph + `twitter:card`) on every HTML
  page — what WhatsApp, Facebook, LinkedIn, Signal and X render when a
  vutuv URL is shared. The root layout renders `tags/1`; the derivation is
  one chokepoint over the conn assigns:

    * a page about a member (`:user` — the profile, its sections, their
      posts): the member's name as title, their work info and follower
      count as description, their avatar as image. The avatar is linked as `/:slug/avatar.jpg`
      (`VutuvWeb.AvatarController`) because preview scrapers don't decode
      the AVIF the site serves itself.
    * a visible, unrestricted post additionally previews its first line,
      its publication date and — when it has images — its first image
      (`/post_images/<token>/og.jpg`, the proxy's on-the-fly JPEG);
      restricted posts and teasers never put the body or an image into
      a tag.
    * everything else: the site description and the generated brand card
      (`VutuvWeb.OgCard`).

  The plain `<meta name="description">` renders `description/1` too, so
  the two can never disagree.
  """

  use Gettext, backend: VutuvWeb.Gettext

  alias Vutuv.Accounts.User
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostImage
  alias VutuvWeb.OgCard
  alias VutuvWeb.UI
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
  member's work info and follower count, else the site pitch — never empty.
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
         |> UserHelpers.meta_description(follower_detail(ca[:follower_count]), ca[:header_job])
         |> IO.iodata_to_binary() do
      "" -> nil
      text -> text
    end
  end

  defp member_info(_ca), do: nil

  # The member's follower count as a localized, compacted phrase ("3 followers",
  # "1.2K followers"), matching the count shown in the profile header. Empty
  # when the count is absent (a non-profile page) or zero, so a profile with no
  # followers and no work info falls through to the site pitch like before.
  defp follower_detail(count) when is_integer(count) and count > 0,
    do: "#{UI.compact_count(count)} #{ngettext("follower", "followers", count)}"

  defp follower_detail(_count), do: ""

  defp og_locale(assigns) do
    case assigns[:locale] do
      "de" -> "de_DE"
      _ -> "en_US"
    end
  end

  @doc """
  The canonical absolute URL for this page — the single value shared by
  `og:url` and the `<link rel="canonical">` tag (rendered in the root
  layout). Built from the request path only, so volatile query params
  (`?lang`, `?page`) never leak into the canonical. Returns `nil` when there
  is no conn (e.g. an error page rendered without one).
  """
  def canonical_url(%{conn: %Plug.Conn{} = conn}),
    do: VutuvWeb.Endpoint.url() <> canonical_path(conn.request_path)

  def canonical_url(_assigns), do: nil

  defp url_tags(assigns) do
    case canonical_url(assigns) do
      nil -> []
      url -> [{"og:url", url}]
    end
  end

  defp canonical_path("/"), do: "/"
  defp canonical_path(path), do: String.replace_suffix(path, "/", "")

  defp article_tags(%{post: %Post{} = post}),
    do: [{"article:published_time", Date.to_iso8601(post.published_on)}]

  defp article_tags(_ca), do: []

  # Image priority: an unrestricted post's first image, else the member's
  # avatar, else the brand card. A restricted post's images must stay out
  # of the tags like its body does.
  defp image(%{post: %Post{} = post, restricted?: false} = ca) do
    case first_image(post) do
      %PostImage{} = post_image -> post_image_entry(post_image, ca)
      nil -> member_image(ca) || brand_card()
    end
  end

  defp image(ca), do: member_image(ca) || brand_card()

  defp first_image(%Post{images: images}) when is_list(images) do
    images |> Enum.sort_by(&{&1.position, &1.id}) |> List.first()
  end

  defp first_image(_post), do: nil

  defp post_image_entry(post_image, ca) do
    {width, height} = Vutuv.PostImageStore.og_dimensions(post_image)

    %{
      url: abs_url(PostImage.og_url(post_image)),
      width: width,
      height: height,
      type: "image/jpeg",
      alt: image_alt(post_image, ca),
      card: "summary_large_image"
    }
  end

  defp image_alt(%{alt: alt}, _ca) when alt not in [nil, ""], do: alt
  defp image_alt(_post_image, %{user: %User{} = user}), do: UserHelpers.full_name(user)
  defp image_alt(_post_image, _ca), do: "vutuv"

  defp member_image(%{user: %User{avatar: avatar} = user}) when not is_nil(avatar) do
    size = Vutuv.Avatar.og_size()

    %{
      url: abs_url("/#{user.username}/avatar.jpg"),
      width: size,
      height: size,
      type: "image/jpeg",
      alt: UserHelpers.full_name(user),
      card: "summary"
    }
  end

  defp member_image(_ca), do: nil

  defp brand_card do
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
