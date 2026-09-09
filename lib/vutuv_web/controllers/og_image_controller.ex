defmodule VutuvWeb.OgImageController do
  @moduledoc """
  `GET /:slug/og.png`, `GET /:slug/posts/:id/og.png` and
  `GET /:slug/posts/:id/og-square.png` — the generated link-preview cards
  (`VutuvWeb.OgImage`) that `og:image` names on a member's pages and on their
  posts (`VutuvWeb.OpenGraph`; the square one for LinkedIn's scraper alone).

  Served outside the browser pipeline like `/:slug/avatar.jpg`, through the
  same `ControllerHelpers.send_og_image/3`: an unknown slug, a withheld
  profile and a post an anonymous reader may not see all answer the same
  plain 404, so a scraper learns nothing from the difference. The card is
  drawn from the **anonymous public view** only — the gates are the ones the
  profile and the permalink ask with no viewer — and a restricted post has no
  card at all rather than a card of its author, so its words never reach a
  picture anybody can fetch by URL.

  The card's few words (the follower line, the date) are written in the
  **member's own** locale, not the scraper's: the picture is one file for
  everybody who shares the link, and its author's language is the one guess
  that is right for most of their readers.
  """

  use VutuvWeb, :controller

  alias Vutuv.Accounts.User
  alias Vutuv.Avatar
  alias Vutuv.Moderation
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Repo
  alias Vutuv.Social
  alias VutuvWeb.ControllerHelpers
  alias VutuvWeb.OgImage
  alias VutuvWeb.OpenGraph
  alias VutuvWeb.Plug.Locale
  alias VutuvWeb.PostTeaser
  alias VutuvWeb.UI
  alias VutuvWeb.UserHelpers
  alias VutuvWeb.UserHTML

  # How many tags the profile card offers the pill rows; the renderer keeps
  # as many as fit two rows.
  @tags_shown 8

  def profile(conn, %{"slug" => slug}) do
    png =
      with %User{} = user <- public_member(slug) do
        in_locale(user, fn -> OgImage.profile_png(profile_data(user)) end)
      end

    ControllerHelpers.send_og_image(conn, png, "image/png")
  end

  def post(conn, params), do: post_card(conn, params, &OgImage.post_png/1)

  def post_square(conn, params), do: post_card(conn, params, &OgImage.square_png/1)

  # Resolved by the id alone, never by the handle beside it (a handle goes
  # stale the moment its owner renames). Member posts only for now: a page's
  # post keeps previewing with its logo (`VutuvWeb.OpenGraph`). For a member's
  # post `Posts.visible_to?/2` with no viewer already refuses a restricted one.
  defp post_card(conn, %{"id" => id}, render) do
    png =
      with %Post{} = post <- Posts.get_post(id),
           %User{} = author <- Posts.author(post),
           true <- Moderation.profile_visible_to?(author, nil),
           true <- Posts.visible_to?(post, nil) do
        in_locale(author, fn -> render.(post_data(post, author)) end)
      end

    ControllerHelpers.send_og_image(conn, png, "image/png")
  end

  defp public_member(slug) do
    with %User{} = user <- Repo.get_by(User, username: slug),
         true <- Moderation.profile_visible_to?(user, nil) do
      user
    end
  end

  defp profile_data(%User{} = user) do
    Map.merge(author_fields(user), %{tags: tags(user), meta: profile_meta(user)})
  end

  defp post_data(%Post{} = post, %User{} = author) do
    Map.merge(author_fields(author), %{
      text: PostTeaser.opening(post, length: 600),
      meta: UI.long_date(post.published_on)
    })
  end

  # What both cards say about the member: name, headline, face and address.
  defp author_fields(%User{} = user) do
    job = UserHelpers.current_job(user)

    %{
      name: UserHelpers.full_name(user),
      headline: UserHelpers.profile_headline(user, job, 120),
      avatar: avatar(user),
      footer: address(user)
    }
  end

  defp avatar(%User{} = user) do
    case Avatar.og_jpeg(user) do
      {:ok, jpeg} -> jpeg
      :error -> nil
    end
  end

  # The member's tags in endorsement order, the same order the profile's Tags
  # card lists them in.
  defp tags(%User{} = user) do
    case Map.get(UserHelpers.tag_summary_map([user], @tags_shown), user.id) do
      %{top: user_tags} -> Enum.map(user_tags, & &1.tag.name)
      nil -> []
    end
  end

  # "7 followers · Member since 2016"; each half only when it has something to
  # say.
  defp profile_meta(%User{} = user) do
    [OpenGraph.follower_detail(Social.follower_count(user)), UserHTML.member_since(user)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  # The profile's address as a reader would type it: host and handle, no
  # scheme — `www.` included when the installation serves under it.
  defp address(%User{username: username}), do: "#{VutuvWeb.Endpoint.host()}/#{username}"

  # The member's locale for the card's words, falling back to the request's
  # for a locale this installation does not serve.
  defp in_locale(%User{locale: locale}, fun) do
    locale = if Locale.locale_supported?(locale), do: locale, else: Gettext.get_locale()
    Gettext.with_locale(VutuvWeb.Gettext, locale, fun)
  end
end
