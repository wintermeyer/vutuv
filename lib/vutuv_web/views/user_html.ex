defmodule VutuvWeb.UserHTML do
  @moduledoc false
  use VutuvWeb, :html
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
      <.link href={~p"/users/#{@user}"} class="shrink-0">
        <.avatar user={@user} size="sm" alt={"Avatar of #{full_name(@user)}"} />
      </.link>
      <div class="min-w-0 text-sm">
        <.link href={~p"/users/#{@user}"} class="block truncate font-medium text-slate-800 hover:text-brand-700 dark:text-slate-100">{full_name(@user)}</.link>
        <%!-- Always render a line (non-breaking space when empty) so rows keep a
        uniform height and the side-by-side follower/following cards stay aligned.
        Pin text-sm + mb-0 so the legacy global `p` default (15px font, 15px bottom
        margin) doesn't enlarge the line or wedge dead space under it, which would
        push the avatar off-centre against the name/work-line group. --%>
        <p class="mb-0 truncate text-sm text-slate-400">{work_line(@work_info_by_id, @user.id)}</p>
      </div>
      <%= if @current_user && not same_user?(@current_user, @user) do %>
        <%= case Map.get(@following_by_id, @user.id) do %>
          <% connection_id when is_integer(connection_id) -> %>
            <%= button to: ~p"/connections/#{connection_id}", method: :delete,
                  class: "ml-auto self-start text-sm font-semibold text-slate-400 hover:text-slate-600" do %>
              {gettext("Following")}
            <% end %>
          <% _ -> %>
            <%= button to: ~p"/connections?#{[connection: %{follower_id: @current_user_id, followee_id: @user.id}]}", method: :post,
                  class: "ml-auto self-start text-sm font-semibold text-brand-600 hover:text-brand-700" do %>
              {gettext("Follow")}
            <% end %>
        <% end %>
      <% end %>
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
end
