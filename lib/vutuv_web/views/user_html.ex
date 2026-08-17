defmodule VutuvWeb.UserHTML do
  @moduledoc false
  use VutuvWeb, :html

  import VutuvWeb.FediverseComponents, only: [follow_us_from_elsewhere: 1]

  import VutuvWeb.PostComponents,
    only: [
      composer_trigger: 1,
      post_archive_path: 2,
      post_card: 1,
      post_filter_empty_text: 1,
      post_filter_tabs: 1,
      post_list: 1,
      post_row_class: 0,
      post_thread_entry: 1,
      remote_post_card: 1
    ]

  import VutuvWeb.UserHelpers

  alias Vutuv.CodeStats
  alias Vutuv.Posts.PostImage
  alias Vutuv.Profiles.SocialMediaAccount
  alias Vutuv.SocialFeed.Feed
  alias VutuvWeb.Markdown

  embed_templates("../templates/user/*")

  @doc """
  One compact user row (avatar, name, work line, follow/unfollow) shared by
  the profile page's "Who to follow" rail and the follower/following preview
  cards. Callers pass the page-wide `work_info_by_id` / `following_by_id`
  maps (one query each) so a row never queries on its own.

  `posts` (the suggestion rails, from `Vutuv.Posts.recent_posts_by_authors/3`)
  adds that member's latest posts under the row, each cut to two lines: a name
  and a job title say who someone is, not what they write about, and following
  is a bet on the latter. The preview rows leave it empty — a follower list is
  about the relationship, not about reading.
  """
  attr(:user, Vutuv.Accounts.User, required: true)
  attr(:current_user, :any, required: true)
  attr(:current_user_id, :any, required: true)
  attr(:work_info_by_id, :map, required: true)
  attr(:following_by_id, :map, required: true)
  attr(:posts, :list, default: [])
  # Search match marker(s): substring(s) of the name to wrap in a brand <mark>
  # (string or list, see `VutuvWeb.UI.highlight/2`). nil renders plainly.
  attr(:highlight, :any, default: nil)
  # On a LiveView host (the profile) the follow button fires `phx-click`
  # instead of a CSRF link, so the row toggles with no reload. Dead-page
  # callers (search) leave it false.
  attr(:live?, :boolean, default: false)

  def user_row(assigns) do
    ~H"""
    <li class="space-y-2">
      <div class="flex items-center gap-3">
        <.link href={~p"/#{@user}"} class="shrink-0">
          <.avatar user={@user} size="sm" alt={"Avatar of #{full_name(@user)}"} />
        </.link>
        <div class="min-w-0 text-sm">
          <.link href={~p"/#{@user}"} class="block truncate font-medium text-slate-800 hover:text-brand-700 dark:text-slate-100">{highlight(full_name(@user), @highlight)}</.link>
          <%!-- Always render a line (non-breaking space when empty) so rows keep a
          uniform height and the side-by-side follower/following cards stay aligned.
          Pin text-sm + mb-0 so the legacy global `p` default (15px font, 15px bottom
          margin) doesn't enlarge the line or wedge dead space under it, which would
          push the avatar off-centre against the name/work-line group. --%>
          <p class="mb-0 truncate text-sm text-slate-600 dark:text-slate-400">{work_line(@work_info_by_id, @user.id)}</p>
        </div>
        <.follow_button
          :if={@current_user && not same_user?(@current_user, @user)}
          variant="text"
          follower_id={@current_user_id}
          followee_id={@user.id}
          follow_id={Map.get(@following_by_id, @user.id)}
          live?={@live?}
        />
      </div>
      <%!-- The member's latest posts. Each is its own tinted, tappable tile
      rather than another muted paragraph: a run of same-weight grey lines
      reads as a wall of text, and nothing in it says "these are posts, and
      they are worth opening". The tile gives each one a surface that lifts on
      hover, its lead photo, when it was written and how it was received —
      which together are what makes an account look alive and worth following.
      The photo sits on the **right**: only some posts have one, and a leading
      thumbnail would indent those tiles' text while the others start at the
      card edge, so the reader's eye has no straight left margin to run down. --%>
      <ul :if={@posts != []} data-suggested-posts={@user.id} class="space-y-1.5">
        <%!-- `.teaser-tile` carries the tint and, with it, the colour the
        truncation ellipsis blends into (components.css). The two clamp markers
        are the feed post preview's: app.js measures `[data-clamp-body]` and
        puts `is-clamped` on `[data-post-preview]` when the body really
        overflows, which is what paints the "…" — the server cannot know, since
        three lines is a question of column width and font. The hook re-measures
        after a patch (the card re-renders on every follow toggle). --%>
        <li
          :for={post <- @posts}
          id={"suggested-post-#{post.id}"}
          phx-hook="PostPreviewClamp"
          data-post-preview
          class="teaser-tile"
        >
          <%!-- Stretched link, the same arrangement the feed's "Suggested
          posts" card and the /notifications quotes use: the excerpt is
          formatted Markdown and carries its own links (@mentions, #hashtags,
          URLs), so the tile cannot be one big <a> — that would nest anchors.
          The whole tile opens the post, while the body's own links sit above
          the stretched link (relative + z-20) and keep their targets. --%>
          <.link
            href={~p"/#{@user}/posts/#{post.id}"}
            aria-label={gettext("View post")}
            class="absolute inset-0 z-10"
          >
          </.link>
          <div class="flex items-start gap-3">
            <div class="min-w-0 flex-1">
              <%!-- The body goes through the same pipeline as every other post
              preview, so it reads here the way it does in the feed. The rail
              column is narrow, so hyphenation is on at both breakpoints (long
              German compounds), like the "Suggested posts" card. Type size and
              line height are deliberately absent here: `.teaser-clamp` sets
              both, because its three-line cut is arithmetic against them (see
              components.css) and a `text-*` utility here would silently make
              the box no longer a whole number of lines. --%>
              <div
                data-clamp-body
                class="markdown markdown--post teaser-clamp text-slate-700 dark:text-slate-200 [&_a]:relative [&_a]:z-20"
                style="--post-hyphens-desktop:auto;--post-hyphens-mobile:auto"
              >
                {post_teaser(post.body)}
              </div>
              <p class="mb-0 mt-1 flex items-center gap-2 text-xs text-slate-500 dark:text-slate-400">
                <.post_time at={post.inserted_at} />
                <%!-- Social proof, and only when there is any: a "0" beside
                every post would say the opposite of what the rail is for. --%>
                <span
                  :if={post.likes > 0}
                  data-teaser-likes={post.likes}
                  class="inline-flex items-center gap-1"
                >
                  <.icon_heart class="h-3.5 w-3.5" />{compact_count(post.likes)}
                </span>
              </p>
            </div>
            <img
              :if={post.image}
              src={PostImage.url(post.image, "thumb")}
              alt=""
              loading="lazy"
              class="h-14 w-14 shrink-0 rounded-lg object-cover"
            />
          </div>
        </li>
      </ul>
    </li>
    """
  end

  # How much of a post body reaches the rail: the source is block-cut at this
  # budget so an essay-length post is neither parsed nor shipped in full just
  # to show its opening two lines.
  @teaser_source_chars 400

  # The teaser body, rendered through the exact same Markdown pipeline as any
  # other post preview (`VutuvWeb.Markdown.render_preview/3` → `render_post/2`),
  # so bold, links, @mentions and #hashtags read here the way they do in the
  # feed — a fully-qualified `@user@host` is a link to that remote account
  # rather than bare text. Images are deliberately not passed: a teaser is text,
  # and the post's lead photo rides beside it as the thumbnail. The visible cut
  # is the three-line `.teaser-clamp` height clamp on the wrapper, so the
  # truncation flag is dropped here.
  defp post_teaser(body) do
    {html, _truncated?} = Markdown.render_preview(body, [], limit: @teaser_source_chars)
    html
  end

  @doc """
  The profile's "Who to follow" card. Its home is late in the rail (the
  member's own detail cards lead); for the owner still following fewer than
  five members (`@promote_discovery?` in `UserProfileLive`) the profile
  renders it at the top of the rail instead, `promoted`: marker attribute,
  an intro line saying why following matters, and no late-rail order classes.
  A brand-new member otherwise never learns that there are people here to
  follow — every other card on their fresh profile points inward. The two
  call sites are mutually exclusive, so the DOM id stays unique.
  """
  attr(:promoted, :boolean, default: false)
  attr(:recommended_users, :list, required: true)
  attr(:current_user, :any, required: true)
  attr(:current_user_id, :any, required: true)
  attr(:work_info_by_id, :map, required: true)
  attr(:following_by_id, :map, required: true)
  # `%{user_id => [post]}` from `Vutuv.Posts.recent_posts_by_authors/3` — the
  # two-line samples under each suggestion. Defaults to none, so a caller that
  # doesn't load them still renders the plain rows.
  attr(:posts_by_id, :map, default: %{})

  def who_to_follow_card(assigns) do
    ~H"""
    <.card
      :if={@recommended_users != []}
      id="profile-who-to-follow"
      class={if(@promoted, do: "scroll-mt-24", else: "scroll-mt-24 order-1 md:order-none")}
      data-promoted={@promoted}
    >
      <.section_title class="mb-4">{gettext("Who to follow")}</.section_title>
      <p :if={@promoted} id="discovery-intro" class="-mt-2 mb-4 text-sm text-slate-600 dark:text-slate-400">
        {gettext("Your feed shows the posts of members you follow. Follow a few to fill it.")}
      </p>
      <ul class="space-y-5">
        <.user_row
          :for={user <- @recommended_users}
          user={user}
          current_user={@current_user}
          current_user_id={@current_user_id}
          work_info_by_id={@work_info_by_id}
          following_by_id={@following_by_id}
          posts={Map.get(@posts_by_id, user.id, [])}
          live?
        />
      </ul>
    </.card>
    """
  end

  # Work line for a user row; falls back to a non-breaking space so an empty
  # line still reserves its height and rows stay a uniform two-line height.
  defp work_line(work_info_by_id, user_id) do
    case Map.get(work_info_by_id, user_id) do
      info when info in [nil, ""] -> "\u00A0"
      info -> info
    end
  end

  @doc """
  How long the account has been on vutuv, derived from `inserted_at`.

  "Member since 2008" for an older account; "Member since February 2026" when
  the account was created in the current year, where a bare year reads oddly
  for a fresh profile so the month is spelled out. Follows the viewer's locale
  via gettext. Returns nil for an unsaved struct with no `inserted_at`.
  """
  def member_since(%Vutuv.Accounts.User{inserted_at: %NaiveDateTime{} = inserted_at}) do
    joined = NaiveDateTime.to_date(inserted_at)

    if joined.year == Vutuv.BerlinTime.today().year do
      gettext("Member since %{month} %{year}",
        month: month_name(joined.month),
        year: joined.year
      )
    else
      gettext("Member since %{year}", year: joined.year)
    end
  end

  def member_since(_user), do: nil

  @doc """
  The "Member since" line (calendar icon + label). Rendered in two spots on the
  profile: right-aligned on the counts row, or moved up under the work line
  when the account has no followers and no following. `class` positions it.
  """
  attr(:value, :string, required: true)
  attr(:class, :string, default: nil)

  def member_since_line(assigns) do
    ~H"""
    <p class={["flex items-center gap-1.5 text-sm text-slate-600 dark:text-slate-500", @class]}>
      <svg class="h-4 w-4 shrink-0" fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24">
        <path stroke-linecap="round" stroke-linejoin="round" d="M6.75 3v2.25M17.25 3v2.25M3 18.75V7.5a2.25 2.25 0 0 1 2.25-2.25h13.5A2.25 2.25 0 0 1 21 7.5v11.25m-18 0A2.25 2.25 0 0 0 5.25 21h13.5A2.25 2.25 0 0 0 21 18.75m-18 0v-7.5A2.25 2.25 0 0 1 5.25 9h13.5A2.25 2.25 0 0 1 21 11.25v7.5" />
      </svg>
      {@value}
    </p>
    """
  end

  @doc """
  The profile header's picture, and the click that opens it at full size
  (issue #1528).

  The header shows the avatar at 96 CSS px; the `:large` version behind this is
  1024 px square, so the overlay is a real look at the face on a phone, a tablet
  and a desktop alike rather than a blown-up thumbnail. It reuses the photo
  lightbox — one overlay, one set of keyboard and swipe rules, one dark stage —
  by rendering a `<.lightbox_gallery>` of exactly one picture.

  **The link appears only when the file is really on disk** (`Avatar.large_url/1`
  asks): `:large` is younger than the rows, so an avatar keeps rendering exactly
  as it did before until the deploy's regeneration has re-derived it. Without a
  picture at all there is no link either — the initials tile has nothing to
  enlarge.

  The hover/focus scrim is the whole affordance. A magnifier that only appears
  under the pointer keeps the header calm at rest, and on a touch screen the
  96px picture is already a comfortable target for the tap people try anyway.
  """
  attr(:user, :any, required: true)
  attr(:pending?, :boolean, default: false)

  def profile_avatar(assigns) do
    assigns =
      assign(assigns,
        alt: gettext("Profile picture of %{name}", name: full_name(assigns.user)),
        src: if(assigns.pending?, do: ~p"/settings/pending_image/avatar/medium"),
        zoom: avatar_zoom_url(assigns.user, assigns.pending?),
        zoom_label: gettext("Show the profile picture larger")
      )

    ~H"""
    <.lightbox_gallery :if={@zoom} class="shrink-0">
      <a
        href={@zoom}
        id="profile-avatar-zoom"
        class="group relative inline-flex cursor-zoom-in rounded-2xl focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-500"
        title={@zoom_label}
        aria-label={@zoom_label}
        data-lightbox-photo="0"
        data-photo-src={@zoom}
        data-photo-alt={@alt}
        data-photo-caption={full_name(@user)}
      >
        <.profile_avatar_image user={@user} src={@src} alt="" />
        <span class="pointer-events-none absolute inset-0 z-20 flex items-center justify-center rounded-2xl bg-slate-900/45 text-white opacity-0 transition-opacity group-hover:opacity-100 group-focus-visible:opacity-100">
          <svg class="h-7 w-7" fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" d="M21 21l-5.197-5.197m0 0A7.5 7.5 0 1 0 5.196 5.196a7.5 7.5 0 0 0 10.607 10.607ZM10.5 7.5v6m3-3h-6" />
          </svg>
        </span>
      </a>
    </.lightbox_gallery>
    <.profile_avatar_image :if={!@zoom} user={@user} src={@src} alt={@alt} />
    """
  end

  # The picture itself, identical in both branches so the link can never change
  # how the header looks — only whether it opens.
  attr(:user, :any, required: true)
  attr(:src, :any, required: true)
  attr(:alt, :string, required: true)

  defp profile_avatar_image(assigns) do
    ~H"""
    <.avatar
      user={@user}
      src={@src}
      size="lg"
      shape="square"
      loading="eager"
      alt={@alt}
      class="relative z-10 shrink-0 ring-4 ring-white dark:ring-slate-900"
      presence
    />
    """
  end

  # Where the enlarged picture lives: the served file for everyone, or the
  # authenticated quarantine route while the owner's own upload waits for the
  # AI scan. Both ends answer nil when that version is not on disk, so a member
  # whose avatar predates `:large` simply gets the header they had before.
  defp avatar_zoom_url(user, true) do
    if Vutuv.Avatar.pending_preview_path(user, :large),
      do: ~p"/settings/pending_image/avatar/large"
  end

  defp avatar_zoom_url(user, _pending?), do: Vutuv.Avatar.large_url(user)

  @doc """
  The profile's private-save toggle — bookmark or like *this member* — as the
  twin of the post card's bookmark and heart: the same glyph, the same fill-on-
  active language, one click, in the footer row of the header card. It used to
  be an item in the header's ⋯ menu, where saving a profile cost two taps and
  looked nothing like the act everyone already knows from a post.

  The save is silent and private (no follow, no notification, no public count),
  so unlike the post bar there is no counter beside the glyph and its own state
  is the whole confirmation: the glyph fills, `aria-pressed` flips, and the
  label swaps between "Bookmark" and "Remove bookmark". Icon-only, so that
  label rides `title` + `aria-label`; it is a full 40px touch target because it
  stands alone in a footer row rather than in the post bar's dense cluster.

  `kind` picks the pair of events the profile LiveView handles
  (`bookmark_user` / `unbookmark_user`, `like_user` / `unlike_user`); keep the
  logged-in, non-owner, non-blocker guard on the `:if` at the call site.
  """
  attr(:kind, :atom, required: true, values: [:bookmark, :like])
  attr(:active?, :boolean, required: true)

  def profile_save_toggle(assigns) do
    assigns = assign(assigns, :spec, save_toggle_spec(assigns.kind, assigns.active?))

    ~H"""
    <button
      type="button"
      id={@spec.id}
      phx-click={@spec.event}
      aria-pressed={to_string(@active?)}
      aria-label={@spec.label}
      title={@spec.label}
      data-profile-save={@spec.token}
      class={[
        "inline-flex h-10 w-10 items-center justify-center rounded-lg",
        "hover:bg-slate-100 dark:hover:bg-slate-800",
        # components.css colors a bare `button` brand-600, which would beat the
        # row's inherited slate — so the state color sits on the button itself.
        if(@active?, do: @spec.active_class, else: "text-slate-600 dark:text-slate-400")
      ]}
    >
      <.icon_bookmark :if={@kind == :bookmark} filled?={@active?} />
      <.icon_heart :if={@kind == :like} filled?={@active?} />
    </button>
    """
  end

  # Everything that differs between the two toggles, in one place: the ids the
  # tests key on, the event pair, the label (which names the act, not the
  # state), and the active tint — brand for a bookmark, the coral accent for a
  # like, exactly as the post action bar colors the same two glyphs.
  defp save_toggle_spec(:bookmark, active?) do
    %{
      id: "profile-bookmark",
      token: "bookmark",
      event: if(active?, do: "unbookmark_user", else: "bookmark_user"),
      label: if(active?, do: gettext("Remove bookmark"), else: gettext("Bookmark")),
      active_class: "text-brand-600 dark:text-brand-300"
    }
  end

  defp save_toggle_spec(:like, active?) do
    %{
      id: "profile-like",
      token: "like",
      event: if(active?, do: "unlike_user", else: "like_user"),
      label: if(active?, do: gettext("Unlike"), else: gettext("Like")),
      active_class: "text-accent"
    }
  end

  @doc """
  A single-path brand glyph for a social-media provider (Simple Icons, CC0),
  drawn in `currentColor` so it inherits the surrounding text colour and can
  shift on hover. Unknown providers fall back to a generic link glyph. Used by
  the profile's Social Media card; size and colour it via `class`.
  """
  attr(:provider, :string, required: true)
  attr(:class, :any, default: "h-5 w-5")

  def social_icon(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d={social_icon_path(@provider)} />
    </svg>
    """
  end

  defp social_icon_path("Facebook"),
    do:
      "M9.101 23.691v-7.98H6.627v-3.667h2.474v-1.58c0-4.085 1.848-5.978 5.858-5.978.401 0 .955.042 1.468.103a8.68 8.68 0 0 1 1.141.195v3.325a8.623 8.623 0 0 0-.653-.036 26.805 26.805 0 0 0-.733-.009c-.707 0-1.259.096-1.675.309a1.686 1.686 0 0 0-.679.622c-.258.42-.374.995-.374 1.752v1.297h3.919l-.386 2.103-.287 1.564h-3.246v8.245C19.396 23.238 24 18.179 24 12.044c0-6.627-5.373-12-12-12s-12 5.373-12 12c0 5.628 3.874 10.35 9.101 11.647Z"

  defp social_icon_path("Twitter"),
    do:
      "M18.901 1.153h3.68l-8.04 9.19L24 22.846h-7.406l-5.8-7.584-6.638 7.584H.474l8.6-9.83L0 1.154h7.594l5.243 6.932ZM17.61 20.644h2.039L6.486 3.24H4.298Z"

  defp social_icon_path("Mastodon"),
    do:
      "M23.268 5.313c-.35-2.578-2.617-4.61-5.304-5.004C17.51.242 15.792 0 11.813 0h-.03c-3.98 0-4.835.242-5.288.309C3.882.692 1.496 2.518.917 5.127.64 6.412.61 7.837.661 9.143c.074 1.874.088 3.745.26 5.611.118 1.24.325 2.47.62 3.68.55 2.237 2.777 4.098 4.96 4.857 2.336.792 4.849.923 7.256.38.265-.061.527-.132.786-.213.585-.184 1.27-.39 1.774-.753a.057.057 0 0 0 .023-.043v-1.809a.052.052 0 0 0-.02-.041.053.053 0 0 0-.046-.01 20.282 20.282 0 0 1-4.709.545c-2.73 0-3.463-1.284-3.674-1.818a5.593 5.593 0 0 1-.319-1.433.053.053 0 0 1 .066-.054c1.517.363 3.072.546 4.632.546.376 0 .75 0 1.125-.01 1.57-.044 3.224-.124 4.768-.422.038-.008.077-.015.11-.024 2.435-.464 4.753-1.92 4.989-5.604.008-.145.03-1.52.03-1.67.002-.512.167-3.63-.024-5.545zm-3.748 9.195h-2.561V8.29c0-1.309-.55-1.976-1.67-1.976-1.23 0-1.846.79-1.846 2.35v3.403h-2.546V8.663c0-1.56-.617-2.35-1.848-2.35-1.112 0-1.668.668-1.67 1.977v6.218H4.822V8.102c0-1.31.337-2.35 1.011-3.12.696-.77 1.608-1.164 2.74-1.164 1.311 0 2.302.5 2.962 1.498l.638 1.06.638-1.06c.66-.999 1.65-1.498 2.96-1.498 1.13 0 2.043.395 2.74 1.164.675.77 1.012 1.81 1.012 3.12z"

  defp social_icon_path("Bluesky"),
    do:
      "M5.202 2.857C7.954 4.922 10.913 9.11 12 11.358c1.087-2.247 4.046-6.436 6.798-8.501C20.783 1.366 24 .213 24 3.883c0 .732-.42 6.156-.667 7.037-.856 3.061-3.978 3.842-6.755 3.37 4.854.826 6.089 3.562 3.422 6.299-5.065 5.196-7.28-1.304-7.847-2.97-.104-.305-.152-.448-.153-.327 0-.121-.05.022-.153.327-.568 1.666-2.782 8.166-7.847 2.97-2.667-2.737-1.432-5.473 3.422-6.3-2.777.473-5.899-.308-6.755-3.369C.42 10.04 0 4.615 0 3.883c0-3.67 3.217-2.517 5.202-1.026"

  defp social_icon_path("Instagram"),
    do:
      "M7.0301.084c-1.2768.0602-2.1487.264-2.911.5634-.7888.3075-1.4575.72-2.1228 1.3877-.6652.6677-1.075 1.3368-1.3802 2.127-.2954.7638-.4956 1.6365-.552 2.914-.0564 1.2775-.0689 1.6882-.0626 4.947.0062 3.2586.0206 3.6671.0825 4.9473.061 1.2765.264 2.1482.5635 2.9107.308.7889.72 1.4573 1.388 2.1228.6679.6655 1.3365 1.0743 2.1285 1.38.7632.295 1.6361.4961 2.9134.552 1.2773.056 1.6884.069 4.9462.0627 3.2578-.0062 3.668-.0207 4.9478-.0814 1.28-.0607 2.147-.2652 2.9098-.5633.7889-.3086 1.4578-.72 2.1228-1.3881.665-.6682 1.0745-1.3378 1.3795-2.1284.2957-.7632.4966-1.636.552-2.9124.056-1.2809.0692-1.6898.063-4.948-.0063-3.2583-.021-3.6668-.0817-4.9465-.0607-1.2797-.264-2.1487-.5633-2.9117-.3084-.7889-.72-1.4568-1.3876-2.1228C21.2982 1.33 20.628.9208 19.8378.6165 19.074.321 18.2017.1197 16.9244.0645 15.6471.0093 15.236-.005 11.977.0014 8.718.0076 8.31.0215 7.0301.0839m.1402 21.6932c-1.17-.0509-1.8053-.2453-2.2287-.408-.5606-.216-.96-.4771-1.3819-.895-.422-.4178-.6811-.8186-.9-1.378-.1644-.4234-.3624-1.058-.4171-2.228-.0595-1.2645-.072-1.6442-.079-4.848-.007-3.2037.0053-3.583.0607-4.848.05-1.169.2456-1.805.408-2.2282.216-.5613.4762-.96.895-1.3816.4188-.4217.8184-.6814 1.3783-.9003.423-.1651 1.0575-.3614 2.227-.4171 1.2655-.06 1.6447-.072 4.848-.079 3.2033-.007 3.5835.005 4.8495.0608 1.169.0508 1.8053.2445 2.228.408.5608.216.96.4754 1.3816.895.4217.4194.6816.8176.9005 1.3787.1653.4217.3617 1.056.4169 2.2263.0602 1.2655.0739 1.645.0796 4.848.0058 3.203-.0055 3.5834-.061 4.848-.051 1.17-.245 1.8055-.408 2.2294-.216.5604-.4763.96-.8954 1.3814-.419.4215-.8181.6811-1.3783.9-.4224.1649-1.0577.3617-2.2262.4174-1.2656.0595-1.6448.072-4.8493.079-3.2045.007-3.5825-.006-4.848-.0608M16.953 5.5864A1.44 1.44 0 1 0 18.39 4.144a1.44 1.44 0 0 0-1.437 1.4424M5.8385 12.012c.0067 3.4032 2.7706 6.1557 6.173 6.1493 3.4026-.0065 6.157-2.7701 6.1506-6.1733-.0065-3.4032-2.771-6.1565-6.174-6.1498-3.403.0067-6.156 2.771-6.1496 6.1738M8 12.0077a4 4 0 1 1 4.008 3.9921A3.9996 3.9996 0 0 1 8 12.0077"

  defp social_icon_path("Youtube"),
    do:
      "M23.498 6.186a3.016 3.016 0 0 0-2.122-2.136C19.505 3.545 12 3.545 12 3.545s-7.505 0-9.377.505A3.017 3.017 0 0 0 .502 6.186C0 8.07 0 12 0 12s0 3.93.502 5.814a3.016 3.016 0 0 0 2.122 2.136c1.871.505 9.376.505 9.376.505s7.505 0 9.377-.505a3.015 3.015 0 0 0 2.122-2.136C24 15.93 24 12 24 12s0-3.93-.502-5.814zM9.545 15.568V8.432L15.818 12l-6.273 3.568z"

  defp social_icon_path("Snapchat"),
    do:
      "M12.206.793c.99 0 4.347.276 5.93 3.821.529 1.193.403 3.219.299 4.847l-.003.06c-.012.18-.022.345-.03.51.075.045.203.09.401.09.3-.016.659-.12 1.033-.301.165-.088.344-.104.464-.104.182 0 .359.029.509.09.45.149.734.479.734.838.015.449-.39.839-1.213 1.168-.089.029-.209.075-.344.119-.45.135-1.139.36-1.333.81-.09.224-.061.524.12.868l.015.015c.06.136 1.526 3.475 4.791 4.014.255.044.435.27.42.509 0 .075-.015.149-.045.225-.24.569-1.273.988-3.146 1.271-.059.091-.12.375-.164.57-.029.179-.074.36-.134.553-.076.271-.27.405-.555.405h-.03c-.135 0-.313-.031-.538-.074-.36-.075-.765-.135-1.273-.135-.3 0-.599.015-.913.074-.6.104-1.123.464-1.723.884-.853.599-1.826 1.288-3.294 1.288-.06 0-.119-.015-.18-.015h-.149c-1.468 0-2.427-.675-3.279-1.288-.599-.42-1.107-.779-1.707-.884-.314-.045-.629-.074-.928-.074-.54 0-.958.089-1.272.149-.211.043-.391.074-.54.074-.374 0-.523-.224-.583-.42-.061-.192-.09-.389-.135-.567-.046-.181-.105-.494-.166-.57-1.918-.222-2.95-.642-3.189-1.226-.031-.063-.052-.15-.055-.225-.015-.243.165-.465.42-.509 3.264-.54 4.73-3.879 4.791-4.02l.016-.029c.18-.345.224-.645.119-.869-.195-.434-.884-.658-1.332-.809-.121-.029-.24-.074-.346-.119-1.107-.435-1.257-.93-1.197-1.273.09-.479.674-.793 1.168-.793.146 0 .27.029.383.074.42.194.789.3 1.104.3.234 0 .384-.06.465-.105l-.046-.569c-.098-1.626-.225-3.651.307-4.837C7.392 1.077 10.739.807 11.727.807l.419-.015h.06z"

  defp social_icon_path("LinkedIn"),
    do:
      "M20.447 20.452h-3.554v-5.569c0-1.328-.027-3.037-1.852-3.037-1.853 0-2.136 1.445-2.136 2.939v5.667H9.351V9h3.414v1.561h.046c.477-.9 1.637-1.85 3.37-1.85 3.601 0 4.267 2.37 4.267 5.455v6.286zM5.337 7.433c-1.144 0-2.063-.926-2.063-2.065 0-1.138.92-2.063 2.063-2.063 1.14 0 2.064.925 2.064 2.063 0 1.139-.925 2.065-2.064 2.065zm1.782 13.019H3.555V9h3.564v11.452zM22.225 0H1.771C.792 0 0 .774 0 1.729v20.542C0 23.227.792 24 1.771 24h20.451C23.2 24 24 23.227 24 22.271V1.729C24 .774 23.2 0 22.222 0h.003z"

  defp social_icon_path("XING"),
    do:
      "M18.188 0c-.517 0-.741.325-.927.66 0 0-7.455 13.224-7.702 13.657.015.024 4.919 9.023 4.919 9.023.17.308.436.66.967.66h3.454c.211 0 .375-.078.463-.22.089-.151.089-.346-.009-.536l-4.879-8.916c-.004-.006-.004-.016 0-.022L22.139.756c.095-.191.097-.387.006-.535C22.056.078 21.894 0 21.686 0h-3.498zM3.648 4.74c-.211 0-.385.074-.473.216-.09.149-.078.339.02.531l2.34 4.05c.004.01.004.016 0 .021L1.86 16.051c-.099.188-.093.381 0 .529.085.142.239.234.45.234h3.461c.518 0 .766-.348.945-.667l3.734-6.609-2.378-4.155c-.172-.315-.434-.659-.962-.659H3.648v.016z"

  defp social_icon_path("GitHub"),
    do:
      "M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12"

  defp social_icon_path("GitLab"),
    do:
      "m23.6004 9.5927-.0337-.0862L20.3.9814a.851.851 0 0 0-.3362-.405.8748.8748 0 0 0-.9997.0539.8748.8748 0 0 0-.29.4399l-2.2055 6.748H7.5375l-2.2057-6.748a.8573.8573 0 0 0-.29-.4412.8748.8748 0 0 0-.9997-.0537.8585.8585 0 0 0-.3362.4049L.4332 9.5015l-.0325.0862a6.0657 6.0657 0 0 0 2.0119 7.0105l.0113.0087.03.0213 4.976 3.7264 2.462 1.8633 1.4995 1.1321a1.0085 1.0085 0 0 0 1.2197 0l1.4995-1.1321 2.4619-1.8633 5.006-3.7489.0125-.01a6.0682 6.0682 0 0 0 2.0094-7.003z"

  defp social_icon_path("Codeberg"),
    do:
      "M11.999.747A11.974 11.974 0 0 0 0 12.75c0 2.254.635 4.465 1.833 6.376L11.837 6.19c.072-.092.251-.092.323 0l4.178 5.402h-2.992l.065.239h3.113l.882 1.138h-3.674l.103.374h3.86l.777 1.003h-4.358l.135.483h4.593l.695.894h-5.038l.165.589h5.326l.609.785h-5.717l.182.65h6.038l.562.727h-6.397l.183.65h6.717A12.003 12.003 0 0 0 24 12.75 11.977 11.977 0 0 0 11.999.747zm3.654 19.104.182.65h5.326c.173-.204.353-.433.513-.65zm.385 1.377.18.65h3.563c.233-.198.485-.428.712-.65zm.383 1.377.182.648h1.203c.356-.204.685-.412 1.042-.648z"

  defp social_icon_path("Gitea"),
    do:
      "M4.209 4.603c-.247 0-.525.02-.84.088-.333.07-1.28.283-2.054 1.027C-.403 7.25.035 9.685.089 10.052c.065.446.263 1.687 1.21 2.768 1.749 2.141 5.513 2.092 5.513 2.092s.462 1.103 1.168 2.119c.955 1.263 1.936 2.248 2.89 2.367 2.406 0 7.212-.004 7.212-.004s.458.004 1.08-.394c.535-.324 1.013-.893 1.013-.893s.492-.527 1.18-1.73c.21-.37.385-.729.538-1.068 0 0 2.107-4.471 2.107-8.823-.042-1.318-.367-1.55-.443-1.627-.156-.156-.366-.153-.366-.153s-4.475.252-6.792.306c-.508.011-1.012.023-1.512.027v4.474l-.634-.301c0-1.39-.004-4.17-.004-4.17-1.107.016-3.405-.084-3.405-.084s-5.399-.27-5.987-.324c-.187-.011-.401-.032-.648-.032zm.354 1.832h.111s.271 2.269.6 3.597C5.549 11.147 6.22 13 6.22 13s-.996-.119-1.641-.348c-.99-.324-1.409-.714-1.409-.714s-.73-.511-1.096-1.52C1.444 8.73 2.021 7.7 2.021 7.7s.32-.859 1.47-1.145c.395-.106.863-.12 1.072-.12zm8.33 2.554c.26.003.509.127.509.127l.868.422-.529 1.075a.686.686 0 0 0-.614.359.685.685 0 0 0 .072.756l-.939 1.924a.69.69 0 0 0-.66.527.687.687 0 0 0 .347.763.686.686 0 0 0 .867-.206.688.688 0 0 0-.069-.882l.916-1.874a.667.667 0 0 0 .237-.02.657.657 0 0 0 .271-.137 8.826 8.826 0 0 1 1.016.512.761.761 0 0 1 .286.282c.073.21-.073.569-.073.569-.087.29-.702 1.55-.702 1.55a.692.692 0 0 0-.676.477.681.681 0 1 0 1.157-.252c.073-.141.141-.282.214-.431.19-.397.515-1.16.515-1.16.035-.066.218-.394.103-.814-.095-.435-.48-.638-.48-.638-.467-.301-1.116-.58-1.116-.58s0-.156-.042-.27a.688.688 0 0 0-.148-.241l.516-1.062 2.89 1.401s.48.218.583.619c.073.282-.019.534-.069.657-.24.587-2.1 4.317-2.1 4.317s-.232.554-.748.588a1.065 1.065 0 0 1-.393-.045l-.202-.08-4.31-2.1s-.417-.218-.49-.596c-.083-.31.104-.691.104-.691l2.073-4.272s.183-.37.466-.497a.855.855 0 0 1 .35-.077z"

  defp social_icon_path("Forgejo"),
    do:
      "M16.7773 0c1.6018 0 2.9004 1.2986 2.9004 2.9005s-1.2986 2.9004-2.9004 2.9004c-1.0854 0-2.0315-.596-2.5288-1.4787H12.91c-2.3322 0-4.2272 1.8718-4.2649 4.195l-.0007 2.1175a7.0759 7.0759 0 0 1 4.148-1.4205l.1176-.001 1.3385.0002c.4973-.8827 1.4434-1.4788 2.5288-1.4788 1.6018 0 2.9004 1.2986 2.9004 2.9005s-1.2986 2.9004-2.9004 2.9004c-1.0854 0-2.0315-.596-2.5288-1.4787H12.91c-2.3322 0-4.2272 1.8718-4.2649 4.195l-.0007 2.319c.8827.4973 1.4788 1.4434 1.4788 2.5287 0 1.602-1.2986 2.9005-2.9005 2.9005-1.6018 0-2.9004-1.2986-2.9004-2.9005 0-1.0853.596-2.0314 1.4788-2.5287l-.0002-9.9831c0-3.887 3.1195-7.0453 6.9915-7.108l.1176-.001h1.3385C14.7458.5962 15.692 0 16.7773 0ZM7.2227 19.9052c-.6596 0-1.1943.5347-1.1943 1.1943s.5347 1.1943 1.1943 1.1943 1.1944-.5347 1.1944-1.1943-.5348-1.1943-1.1944-1.1943Zm9.5546-10.4644c-.6596 0-1.1944.5347-1.1944 1.1943s.5348 1.1943 1.1944 1.1943c.6596 0 1.1943-.5347 1.1943-1.1943s-.5347-1.1943-1.1943-1.1943Zm0-7.7346c-.6596 0-1.1944.5347-1.1944 1.1943s.5348 1.1943 1.1944 1.1943c.6596 0 1.1943-.5347 1.1943-1.1943s-.5347-1.1943-1.1943-1.1943Z"

  # Generic link glyph for any provider without a dedicated brand icon.
  defp social_icon_path(_),
    do:
      "M3.9 12c0-1.71 1.39-3.1 3.1-3.1h4V7H7c-2.76 0-5 2.24-5 5s2.24 5 5 5h4v-1.9H7c-1.71 0-3.1-1.39-3.1-3.1zM8 13h8v-2H8v2zm9-6h-4v1.9h4c1.71 0 3.1 1.39 3.1 3.1s-1.39 3.1-3.1 3.1h-4V17h4c2.76 0 5-2.24 5-5s-2.24-5-5-5z"

  @doc """
  One account block on the profile's "Code" card (`Vutuv.CodeStats`): the
  linked handle, a glanceable facts line and the account's top repositories,
  all read from the stored snapshot map (string keys — it round-trips the
  jsonb column). Every fact is optional: a forge that doesn't expose it
  (GitLab has no public follower count or repo language) simply drops the
  span. Repo names/URLs came from remote JSON, so a URL renders as a link
  only when it is https.
  """
  attr(:account, :any, required: true)

  def code_stats_account(assigns) do
    stats = assigns.account.code_stats

    assigns =
      assigns
      |> assign(:stats, stats)
      |> assign(:facts, code_stats_facts_line(stats))
      |> assign(:top_repos, List.wrap(stats["top_repos"]))
      |> assign(:languages, List.wrap(stats["languages"]))

    ~H"""
    <div data-code-stats={@account.provider} class="min-w-0">
      <div class="flex items-center gap-2.5">
        <.social_icon
          provider={@account.provider}
          class="h-4 w-4 shrink-0 text-slate-600 dark:text-slate-400"
        />
        <.social_link
          account={@account}
          class="truncate text-sm font-semibold text-slate-800 transition hover:text-brand-700 dark:text-slate-100 dark:hover:text-brand-300"
        >
          {social_handle(@account)}
        </.social_link>
        <span
          :if={code_stats_year(@stats["member_since"])}
          data-code-since
          class="ml-auto shrink-0 text-xs text-slate-600 dark:text-slate-400"
        >
          {gettext("since %{year}", year: code_stats_year(@stats["member_since"]))}
        </span>
      </div>

      <p :if={@facts != ""} data-code-facts class="mt-2 text-sm text-slate-600 dark:text-slate-400">
        {@facts}
      </p>

      <div :if={@languages != []} class="mt-2 flex flex-wrap gap-1.5">
        <span
          :for={language <- @languages}
          data-code-language
          class="rounded-full bg-slate-100 px-2 py-0.5 text-xs font-medium text-slate-600 dark:bg-slate-800 dark:text-slate-300"
        >
          {language}
        </span>
      </div>

      <ul :if={@top_repos != []} class="mt-3 space-y-2">
        <li :for={repo <- @top_repos} class="min-w-0 text-sm">
          <div class="flex items-baseline gap-2">
            <%= if https_url?(repo["url"]) do %>
              <a
                href={repo["url"]}
                target="_blank"
                rel="noopener nofollow ugc"
                class="truncate font-medium text-brand-700 hover:text-brand-800 dark:text-brand-300"
              >
                {repo["name"]}
              </a>
            <% else %>
              <span class="truncate font-medium text-slate-800 dark:text-slate-100">
                {repo["name"]}
              </span>
            <% end %>
            <span
              :if={is_integer(repo["stars"]) and repo["stars"] > 0}
              class="shrink-0 text-xs text-slate-600 dark:text-slate-400"
            >
              ★ {compact_count(repo["stars"])}
            </span>
            <span
              :if={is_binary(repo["language"]) and repo["language"] != ""}
              class="shrink-0 text-xs text-slate-600 dark:text-slate-400"
            >
              {repo["language"]}
            </span>
          </div>
          <p
            :if={is_binary(repo["description"]) and repo["description"] != ""}
            class="truncate text-xs text-slate-600 dark:text-slate-400"
          >
            {repo["description"]}
          </p>
        </li>
      </ul>
    </div>
    """
  end

  # The dot-separated facts line under the handle: stars, followers, and —
  # only once the account has been quiet for over four weeks
  # (CodeStats.dormant_since/1, a dormancy signal, not a live ticker) — the
  # last-activity date. The repository count is deliberately absent
  # (interesting in principle, but layout noise on the card — the agent
  # formats keep it), and the member-since year sits in the handle row.
  defp code_stats_facts_line(stats) do
    [
      is_integer(stats["total_stars"]) &&
        "★ " <>
          ngettext(
            "%{formatted} star",
            "%{formatted} stars",
            stats["total_stars"],
            formatted: compact_count(stats["total_stars"])
          ),
      is_integer(stats["followers"]) &&
        ngettext(
          "%{formatted} follower",
          "%{formatted} followers",
          stats["followers"],
          formatted: compact_count(stats["followers"])
        ),
      code_stats_dormant(stats) &&
        gettext("Last active %{date}", date: code_stats_dormant(stats))
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" · ")
  end

  # "2010-05-01" -> "2010"; nil/garbage -> nil (the span is dropped).
  defp code_stats_year(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> Integer.to_string(date.year)
      _ -> nil
    end
  end

  defp code_stats_year(_), do: nil

  # The dormancy date to show (CodeStats.dormant_since/1), trimmed to save
  # real estate on the compact card; nil while the account is recently active.
  defp code_stats_dormant(stats) do
    case CodeStats.dormant_since(stats["last_active_at"]) do
      %Date{} = date -> compact_activity_date(date, Vutuv.BerlinTime.today())
      _ -> nil
    end
  end

  @doc """
  A last-activity date trimmed for the compact Code card. A date in `today`'s
  (Berlin) year drops the redundant year and shows only day + month in the
  reader's own region ("28.05.", "5/28"); any earlier year shows just the year
  ("2025"), since the exact day of a long-dormant account no longer matters.
  Public for a region-specific unit test.
  """
  def compact_activity_date(%Date{} = date, %Date{} = today) do
    if date.year == today.year do
      Vutuv.ViewerClock.format(date, :day_month)
    else
      Integer.to_string(date.year)
    end
  end

  # A snapshot URL came from remote JSON; only https may render as a link.
  defp https_url?(url), do: is_binary(url) and String.starts_with?(url, "https://")

  @doc """
  The profile's "Social Media" card body. Splits the member's accounts into
  two buckets so real social networks (Facebook, Mastodon, LinkedIn …) and
  code forges (GitHub, GitLab, Codeberg — which also drive the enriched "Code"
  card) read as distinct kinds instead of one confusing "Social Media" list.
  `CodeStats.code_provider?/1` is the split chokepoint. The subgroup headings
  only appear when **both** kinds are present; a member with just one kind
  gets a plain list under the card title, no redundant single label.
  """
  attr(:accounts, :list, required: true)
  attr(:social_feed_loading, :any, required: true)
  attr(:social_feeds, :map, default: %{})

  def social_media_accounts(assigns) do
    social = Enum.reject(assigns.accounts, &CodeStats.code_provider?(&1.provider))
    code = Enum.filter(assigns.accounts, &CodeStats.code_provider?(&1.provider))
    assigns = assign(assigns, social: social, code: code, split?: social != [] and code != [])

    ~H"""
    <%!-- space-y-6 (not -4) so the second group's heading gets clear air above
    it: the list's -my-1.5 pulls the groups together, and at -4 the gap over
    "Code & repositories" read the same as the gap between entries. --%>
    <div class="space-y-6">
      <.social_media_group
        :if={@social != []}
        label={@split? && gettext("Social networks")}
        accounts={@social}
        social_feed_loading={@social_feed_loading}
        social_feeds={@social_feeds}
      />
      <.social_media_group
        :if={@code != []}
        label={@split? && gettext("Code & repositories")}
        accounts={@code}
        social_feed_loading={@social_feed_loading}
        social_feeds={@social_feeds}
      />
    </div>
    """
  end

  # One labeled bucket of social-media accounts: an optional uppercase
  # subheading (`false` = no heading, a lone bucket) above one compact line
  # per account (brand glyph + handle; the provider name is dropped since the
  # icon carries it). The loading spinner rides accounts whose inline social
  # feed (Mastodon, Bluesky) is still being fetched in the background, and the
  # follower count rides the fetched feed once it arrives.
  attr(:label, :any, default: false)
  attr(:accounts, :list, required: true)
  attr(:social_feed_loading, :any, required: true)
  attr(:social_feeds, :map, default: %{})

  defp social_media_group(assigns) do
    ~H"""
    <div>
      <h3
        :if={@label}
        class="mb-1.5 text-xs font-semibold uppercase tracking-wide text-slate-500 dark:text-slate-400"
      >
        {@label}
      </h3>
      <ul class="-my-1.5 text-sm">
        <li :for={account <- @accounts}>
          <.social_link
            account={account}
            class="group flex items-center gap-2.5 py-1.5 text-slate-700 transition hover:text-brand-700 dark:text-slate-200"
          >
            <.social_icon
              provider={account.provider}
              class="h-4 w-4 shrink-0 text-slate-400 transition group-hover:text-brand-600 dark:text-slate-500 dark:group-hover:text-brand-300"
            />
            <span class="truncate font-medium">{social_handle(account)}</span>
            <%!-- The member proved this account is theirs
            (Vutuv.Profiles.SocialAccountVerification) — same emerald mark a
            verified webpage link gets, shown to every viewer. --%>
            <.verified_mark
              :if={account.verified_at}
              title={gettext("Verified profile")}
              class="shrink-0"
            />
            <.social_follower_count followers={
              Map.get(@social_feeds, {account.provider, account.value})
            } />
            <span
              :if={MapSet.member?(@social_feed_loading, {account.provider, account.value})}
              data-feed-loading
              title={gettext("Loading posts")}
              class="shrink-0"
            >
              <svg
                class="h-3.5 w-3.5 animate-spin text-slate-400 dark:text-slate-500"
                viewBox="0 0 24 24"
                fill="none"
                aria-hidden="true"
              >
                <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4" />
                <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 0 1 8-8v4a4 4 0 0 0-4 4H4z" />
              </svg>
            </span>
          </.social_link>
        </li>
      </ul>
    </div>
    """
  end

  # The account's follower count as the remote network reports it, taken off
  # the feed the cache already holds (`Vutuv.SocialFeed.Feed`) — so it costs
  # neither a request nor a query. Renders **nothing** unless there is a real
  # number: a feed not fetched yet, a network that offered no count, and a
  # provider with no feed at all (LinkedIn, a code forge) must all stay silent
  # rather than claim "0 followers".
  attr(:followers, :any, required: true)

  defp social_follower_count(%{followers: %Feed{followers: count}} = assigns)
       when is_integer(count) do
    assigns = assign(assigns, count: count)

    ~H"""
    <span
      data-social-followers
      class="shrink-0 text-xs text-slate-600 dark:text-slate-400"
    >
      <%!-- The formatted figure rides its own placeholder: ngettext auto-binds
      %{count} to the raw integer, which a `count:` binding cannot override,
      so `%{count}` here would print 60023 instead of 60K. --%>
      {ngettext("%{formatted} follower", "%{formatted} followers", @count,
        formatted: compact_count(@count)
      )}
    </span>
    """
  end

  defp social_follower_count(assigns), do: ~H""

  @doc """
  Wraps a social-media entry in an outbound link (`target=_blank`, `rel="me
  noopener"`) when the provider has a canonical URL, or a plain `<span>` for a
  provider that only has a bare handle (e.g. Snapchat). The `class` styles the
  tile/chip/row; the inner block is the icon and/or handle.
  """
  attr(:account, :any, required: true)
  attr(:class, :any, required: true)
  attr(:rest, :global)
  slot(:inner_block, required: true)

  def social_link(assigns) do
    url = SocialMediaAccount.url(assigns.account)
    assigns = assign(assigns, url: url, linkable?: String.starts_with?(url, "http"))

    ~H"""
    <.link
      :if={@linkable?}
      href={@url}
      target="_blank"
      rel="me noopener"
      aria-label={"#{@account.provider}: #{social_handle(@account)}"}
      class={@class}
      {@rest}
    >
      {render_slot(@inner_block)}
    </.link>
    <span :if={!@linkable?} class={@class} {@rest}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  # The handle as shown to a visitor: an "@" leads the Twitter/Mastodon/Instagram
  # handle (matching the legacy display rules), every other provider shows it
  # bare. Mastodon's value already carries the instance (user@instance.tld), so
  # the lead "@" yields the canonical @user@instance.tld address.
  defp social_handle(%{provider: provider, value: value})
       when provider in ~w(Twitter Mastodon Instagram),
       do: "@" <> value

  defp social_handle(%{value: value}), do: value

  @doc """
  Splits the profile's contact channels into the Beruflich/Privat buckets the
  contact card shows. E-mails are work unless explicitly typed "Personal";
  phone numbers count as private when typed "Home" or "Cell" (private landline /
  mobile, issue #948), so a work or unlabeled number lands in work. Returns the
  non-empty groups in `[work, private]` order, each `{label, emails, phones}`
  with e-mails before phones (the card's row order). A single bucket renders
  without a heading.
  """
  def contact_groups(emails, phone_numbers) do
    {work_emails, private_emails} =
      Enum.split_with(emails, fn email -> email.email_type != "Personal" end)

    {private_phones, work_phones} =
      Enum.split_with(phone_numbers, fn number -> number.number_type in ["Home", "Cell"] end)

    [{:work, work_emails, work_phones}, {:private, private_emails, private_phones}]
    |> Enum.reject(fn {_label, group_emails, group_phones} ->
      group_emails == [] and group_phones == []
    end)
  end

  @doc "Localized heading for a contact group (see `contact_groups/2`)."
  def contact_group_label(:work), do: gettext("Professional")
  def contact_group_label(:private), do: gettext("Personal")
end
