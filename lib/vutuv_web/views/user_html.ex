defmodule VutuvWeb.UserHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.PostComponents, only: [post_card: 1]
  import VutuvWeb.UserHelpers

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

  def user_row(assigns) do
    ~H"""
    <li class="flex items-center gap-3">
      <.link href={~p"/#{@user}"} class="shrink-0">
        <.avatar user={@user} size="sm" alt={"Avatar of #{full_name(@user)}"} />
      </.link>
      <div class="min-w-0 text-sm">
        <.link href={~p"/#{@user}"} class="block truncate font-medium text-slate-800 hover:text-brand-700 dark:text-slate-100">{full_name(@user)}</.link>
        <%!-- Always render a line (non-breaking space when empty) so rows keep a
        uniform height and the side-by-side follower/following cards stay aligned.
        Pin text-sm + mb-0 so the legacy global `p` default (15px font, 15px bottom
        margin) doesn't enlarge the line or wedge dead space under it, which would
        push the avatar off-centre against the name/work-line group. --%>
        <p class="mb-0 truncate text-sm text-slate-400">{work_line(@work_info_by_id, @user.id)}</p>
      </div>
      <.follow_button
        :if={@current_user && not same_user?(@current_user, @user)}
        variant="text"
        follower_id={@current_user_id}
        followee_id={@user.id}
        connection_id={Map.get(@following_by_id, @user.id)}
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

    if joined.year == Date.utc_today().year do
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
    <p class={["flex items-center gap-1.5 text-sm text-slate-400 dark:text-slate-500", @class]}>
      <svg class="h-4 w-4 shrink-0" fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24">
        <path stroke-linecap="round" stroke-linejoin="round" d="M6.75 3v2.25M17.25 3v2.25M3 18.75V7.5a2.25 2.25 0 0 1 2.25-2.25h13.5A2.25 2.25 0 0 1 21 7.5v11.25m-18 0A2.25 2.25 0 0 0 5.25 21h13.5A2.25 2.25 0 0 0 21 18.75m-18 0v-7.5A2.25 2.25 0 0 1 5.25 9h13.5A2.25 2.25 0 0 1 21 11.25v7.5" />
      </svg>
      {@value}
    </p>
    """
  end

  defp month_name(1), do: gettext("January")
  defp month_name(2), do: gettext("February")
  defp month_name(3), do: gettext("March")
  defp month_name(4), do: gettext("April")
  defp month_name(5), do: gettext("May")
  defp month_name(6), do: gettext("June")
  defp month_name(7), do: gettext("July")
  defp month_name(8), do: gettext("August")
  defp month_name(9), do: gettext("September")
  defp month_name(10), do: gettext("October")
  defp month_name(11), do: gettext("November")
  defp month_name(12), do: gettext("December")
end
