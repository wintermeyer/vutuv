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
  member's work info and follower count, else a per-page description for the
  known site pages (settings, the /system directory, the public info pages),
  else the generic site pitch — never empty.
  """
  def description(assigns) do
    ca = conn_assigns(assigns)

    # A page may set its own description (the CV builder describes the member's
    # Lebenslauf, a tag page names its tag); otherwise fall back to the post /
    # member / per-page copy / site pitch. `assigns[:meta_description]` catches
    # both a controller render assign and a LiveView socket assign; `ca` catches
    # a conn assign set in a plug.
    assigns[:meta_description] || ca[:meta_description] || post_excerpt(ca) ||
      member_info(ca) || path_description(assigns) || default_description()
  end

  # The generic fallback for a page that is about neither a member nor a post
  # and has no page-specific copy: the site pitch. vutuv is a business network,
  # so the pitch leads with that, not the old "career network / no premium
  # accounts" line.
  defp default_description do
    gettext(
      "vutuv is the open business network where professionals connect, share, and get found. Free to join."
    )
  end

  # A per-area fallback description, keyed on the request path so it works for
  # both dead controller pages and the disconnected LiveView render (the conn is
  # present in both). Returns nil for an unknown path, so `default_description/0`
  # still backstops it. The settings pages redirect logged-out link-preview bots
  # to the landing page, so their copy is really for signed-in shares, but every
  # page still carries an honest description.
  defp path_description(%{conn: %Plug.Conn{request_path: path}}) when is_binary(path),
    do: path |> String.split("/", trim: true) |> page_copy()

  defp path_description(_assigns), do: nil

  defp page_copy(["settings" | rest]), do: settings_copy(rest)

  defp page_copy(["system", "members" | _]),
    do: gettext("Browse the vutuv member directory.")

  defp page_copy(["organizations" | _]),
    do: gettext("Verified organization pages on vutuv, each with a proven web domain.")

  defp page_copy(["login" | _]), do: gettext("Sign in to your vutuv account.")
  defp page_copy(["feed"]), do: gettext("Your personal vutuv newsfeed.")

  defp page_copy(["community"]),
    do: gettext("The community guidelines that keep vutuv friendly and fair.")

  defp page_copy(["impressum"]),
    do: gettext("Who runs vutuv: the legal notice and operator details.")

  defp page_copy(["datenschutzerklaerung"]),
    do: gettext("How vutuv handles your personal data.")

  defp page_copy(["nutzungsbedingungen"]), do: gettext("The terms of use for vutuv.")

  defp page_copy(["developers" | _]),
    do: gettext("Developer documentation for the vutuv API.")

  defp page_copy(["listings", "most_followed_users"]),
    do: gettext("The most followed members on vutuv.")

  defp page_copy(["tags" | _]),
    do: gettext("Browse tags on vutuv and discover the members behind them.")

  defp page_copy(_segments), do: nil

  # The settings scope: one description per section, keyed on the segment after
  # /settings (so the new / edit / manage variants of a section share it). An
  # unknown or hub path falls to the generic account description.
  defp settings_copy([]), do: settings_hub_copy()

  defp settings_copy(["security" | _]),
    do:
      gettext(
        "Manage how you sign in to vutuv: username, email addresses, devices, passkeys and login codes."
      )

  defp settings_copy(["totp" | _]),
    do: gettext("Set up an authenticator app (TOTP) for your vutuv login.")

  defp settings_copy(["login_codes" | _]),
    do: gettext("Generate printable one-time login codes for vutuv.")

  defp settings_copy(["usernames" | _]), do: gettext("Change your vutuv username.")

  defp settings_copy(["preferences" | _]),
    do: gettext("Choose your language and map preferences on vutuv.")

  defp settings_copy(["privacy" | _]),
    do:
      gettext("Control who can find you on vutuv and what search engines and AI agents may use.")

  defp settings_copy(["fediverse" | _]),
    do: gettext("Connect your vutuv profile to the Fediverse.")

  defp settings_copy(["notifications" | _]),
    do: gettext("Choose which vutuv activity you get emails about.")

  defp settings_copy(["apps" | _]),
    do: gettext("Manage the apps and API tokens connected to your vutuv account.")

  defp settings_copy(["delete" | _]), do: gettext("Delete your vutuv account.")

  defp settings_copy(["import" | _]),
    do: gettext("Import your profile from a LinkedIn data export.")

  defp settings_copy(["profile" | _]),
    do: gettext("Edit your vutuv profile basics: name, photo, tagline and about.")

  defp settings_copy(["work_experiences" | _]),
    do: gettext("Manage the work experience on your vutuv profile.")

  defp settings_copy(["educations" | _]),
    do: gettext("Manage the education on your vutuv profile.")

  defp settings_copy(["qualifications" | _]),
    do: gettext("Manage the certificates and licenses on your vutuv profile.")

  defp settings_copy(["languages" | _]),
    do: gettext("Manage the languages on your vutuv profile.")

  defp settings_copy(["links" | _]),
    do: gettext("Manage the links on your vutuv profile.")

  defp settings_copy(["social_media_accounts" | _]),
    do: gettext("Manage the social media accounts on your vutuv profile.")

  defp settings_copy(["emails" | _]),
    do: gettext("Manage the email addresses on your vutuv profile.")

  defp settings_copy(["phone_numbers" | _]),
    do: gettext("Manage the phone numbers on your vutuv profile.")

  defp settings_copy(["addresses" | _]),
    do: gettext("Manage the addresses on your vutuv profile.")

  defp settings_copy(["tags" | _]),
    do: gettext("Manage the tags on your vutuv profile.")

  defp settings_copy(_rest), do: settings_hub_copy()

  defp settings_hub_copy,
    do: gettext("Manage your vutuv account: profile, privacy, notifications and sign-in.")

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

  A controller may set an explicit `:canonical_url` assign to override the
  request-path default — used by the organization page (issue #941), which serves at
  both `/organizations/:slug` and its root `/:handle` and must point both at the
  single root URL when a handle exists.
  """
  def canonical_url(%{canonical_url: url}) when is_binary(url), do: url

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
