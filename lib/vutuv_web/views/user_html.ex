defmodule VutuvWeb.UserHTML do
  @moduledoc false
  use VutuvWeb, :html

  import VutuvWeb.PostComponents,
    only: [composer_trigger: 1, post_list: 1, post_row_class: 0, post_thread_entry: 1]

  import VutuvWeb.UserHelpers

  alias Vutuv.CodeStats
  alias Vutuv.Profiles.SocialMediaAccount

  embed_templates("../templates/user/*")

  @doc """
  One compact user row (avatar, name, work line, follow/unfollow) shared by
  the profile page's "Who to follow" rail and the follower/following preview
  cards. Callers pass the page-wide `work_info_by_id` / `following_by_id`
  maps (one query each) so a row never queries on its own.
  """
  attr(:user, Vutuv.Accounts.User, required: true)
  attr(:current_user, :any, required: true)
  attr(:current_user_id, :any, required: true)
  attr(:work_info_by_id, :map, required: true)
  attr(:following_by_id, :map, required: true)
  # Search match marker(s): substring(s) of the name to wrap in a brand <mark>
  # (string or list, see `VutuvWeb.UI.highlight/2`). nil renders plainly.
  attr(:highlight, :any, default: nil)
  # On a LiveView host (the profile) the follow button fires `phx-click`
  # instead of a CSRF link, so the row toggles with no reload. Dead-page
  # callers (search) leave it false.
  attr(:live?, :boolean, default: false)

  def user_row(assigns) do
    ~H"""
    <li class="flex items-center gap-3">
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
    </li>
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
  (Berlin) year drops the redundant year and shows only day + month (German
  "28.05.", otherwise "5/28"); any earlier year shows just the year ("2025"),
  since the exact day of a long-dormant account no longer matters. Public for
  a locale-specific unit test.
  """
  def compact_activity_date(%Date{} = date, %Date{} = today) do
    if date.year == today.year do
      case Gettext.get_locale(VutuvWeb.Gettext) do
        "de" -> Calendar.strftime(date, "%d.%m.")
        _ -> Calendar.strftime(date, "%-m/%-d")
      end
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
      />
      <.social_media_group
        :if={@code != []}
        label={@split? && gettext("Code & repositories")}
        accounts={@code}
        social_feed_loading={@social_feed_loading}
      />
    </div>
    """
  end

  # One labeled bucket of social-media accounts: an optional uppercase
  # subheading (`false` = no heading, a lone bucket) above one compact line
  # per account (brand glyph + handle; the provider name is dropped since the
  # icon carries it). The loading spinner rides accounts whose inline social
  # feed (Mastodon, Bluesky) is still being fetched in the background.
  attr(:label, :any, default: false)
  attr(:accounts, :list, required: true)
  attr(:social_feed_loading, :any, required: true)

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
  phone numbers count as private only when typed "Home" (so an unspecified
  e-mail, defaulting to "Other", lands in work). Returns the non-empty groups
  in `[work, private]` order, each `{label, emails, phones}` with e-mails before
  phones (the card's row order). A single bucket renders without a heading.
  """
  def contact_groups(emails, phone_numbers) do
    {work_emails, private_emails} =
      Enum.split_with(emails, fn email -> email.email_type != "Personal" end)

    {private_phones, work_phones} =
      Enum.split_with(phone_numbers, fn number -> number.number_type == "Home" end)

    [{:work, work_emails, work_phones}, {:private, private_emails, private_phones}]
    |> Enum.reject(fn {_label, group_emails, group_phones} ->
      group_emails == [] and group_phones == []
    end)
  end

  @doc "Localized heading for a contact group (see `contact_groups/2`)."
  def contact_group_label(:work), do: gettext("Professional")
  def contact_group_label(:private), do: gettext("Personal")

  @doc """
  Outline glyph (Heroicons, MIT) for a profile detail row, drawn in
  `currentColor` so it inherits the row's colour. Size/tint it via `class`.
  Used by the Contact / Phone Numbers / Addresses / General Info section
  layouts to lead each entry with a small semantic icon.
  """
  attr(:name, :string, required: true)
  attr(:class, :any, default: "h-4 w-4")

  def detail_icon(%{name: "map-pin"} = assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24" aria-hidden="true">
      <path stroke-linecap="round" stroke-linejoin="round" d="M15 10.5a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z" />
      <path stroke-linecap="round" stroke-linejoin="round" d="M19.5 10.5c0 7.142-7.5 11.25-7.5 11.25S4.5 17.642 4.5 10.5a7.5 7.5 0 1 1 15 0Z" />
    </svg>
    """
  end

  def detail_icon(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24" aria-hidden="true">
      <path stroke-linecap="round" stroke-linejoin="round" d={detail_icon_path(@name)} />
    </svg>
    """
  end

  defp detail_icon_path("user"),
    do:
      "M15.75 6a3.75 3.75 0 1 1-7.5 0 3.75 3.75 0 0 1 7.5 0ZM4.501 20.118a7.5 7.5 0 0 1 14.998 0A17.933 17.933 0 0 1 12 21.75c-2.676 0-5.216-.584-7.499-1.632Z"

  defp detail_icon_path("cake"),
    do:
      "M12 8.25v-1.5m0 1.5c-1.355 0-2.697.056-4.024.166C6.845 8.51 6 9.473 6 10.608v2.513m6-4.871c1.355 0 2.697.056 4.024.166C17.155 8.51 18 9.473 18 10.608v2.513M15 8.25v-1.5m-6 1.5v-1.5m12 9.75-1.5.75a3.354 3.354 0 0 1-3 0 3.354 3.354 0 0 0-3 0 3.354 3.354 0 0 1-3 0 3.354 3.354 0 0 0-3 0 3.354 3.354 0 0 1-3 0L3 16.5m15-3.379a48.474 48.474 0 0 0-6-.371c-2.032 0-4.034.126-6 .371m12 0c.39.049.777.102 1.163.16 1.07.16 1.837 1.094 1.837 2.175v5.169c0 .621-.504 1.125-1.125 1.125H4.125A1.125 1.125 0 0 1 3 20.625v-5.17c0-1.08.768-2.014 1.837-2.174A47.78 47.78 0 0 1 6 13.12"

  defp detail_icon_path("envelope"),
    do:
      "M21.75 6.75v10.5a2.25 2.25 0 0 1-2.25 2.25h-15a2.25 2.25 0 0 1-2.25-2.25V6.75m19.5 0A2.25 2.25 0 0 0 19.5 4.5h-15a2.25 2.25 0 0 0-2.25 2.25m19.5 0v.243a2.25 2.25 0 0 1-1.07 1.916l-7.5 4.615a2.25 2.25 0 0 1-2.36 0L3.32 8.91a2.25 2.25 0 0 1-1.07-1.916V6.75"

  defp detail_icon_path("phone"),
    do:
      "M2.25 6.75c0 8.284 6.716 15 15 15h2.25a2.25 2.25 0 0 0 2.25-2.25v-1.372c0-.516-.351-.966-.852-1.091l-4.423-1.106c-.44-.11-.902.055-1.173.417l-.97 1.293c-.282.376-.769.542-1.21.38a12.035 12.035 0 0 1-7.143-7.143c-.162-.441.004-.928.38-1.21l1.293-.97c.363-.271.527-.734.417-1.173L6.963 3.102a1.125 1.125 0 0 0-1.091-.852H4.5A2.25 2.25 0 0 0 2.25 4.5v2.25Z"

  defp detail_icon_path("lock"),
    do:
      "M16.5 10.5V6.75a4.5 4.5 0 1 0-9 0v3.75m-.75 11.25h10.5a2.25 2.25 0 0 0 2.25-2.25v-6.75a2.25 2.25 0 0 0-2.25-2.25H6.75a2.25 2.25 0 0 0-2.25 2.25v6.75a2.25 2.25 0 0 0 2.25 2.25Z"
end
