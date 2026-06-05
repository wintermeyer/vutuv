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
        <p class="truncate text-slate-400">{Map.get(@work_info_by_id, @user.id, "")}</p>
      </div>
      <%= if @current_user && not same_user?(@current_user, @user) do %>
        <%= case Map.get(@following_by_id, @user.id) do %>
          <% connection_id when is_integer(connection_id) -> %>
            <%= button to: ~p"/connections/#{connection_id}", method: :delete,
                  class: "ml-auto text-sm font-semibold text-slate-400 hover:text-slate-600" do %>
              {gettext("Following")}
            <% end %>
          <% _ -> %>
            <%= button to: ~p"/connections?#{[connection: %{follower_id: @current_user_id, followee_id: @user.id}]}", method: :post,
                  class: "ml-auto text-sm font-semibold text-brand-600 hover:text-brand-700" do %>
              {gettext("Follow")}
            <% end %>
        <% end %>
      <% end %>
    </li>
    """
  end
end
