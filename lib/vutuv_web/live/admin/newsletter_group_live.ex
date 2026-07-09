defmodule VutuvWeb.Admin.NewsletterGroupLive do
  @moduledoc """
  The newsletter audience builder. Admins play with filters (language, country,
  age, tag) and subtract other groups, watch the matching-member count and a
  live preview list of profiles update live, then freeze the selection into a
  fixed group (`Vutuv.Newsletters`).

  Lives in the `:admin` live_session (`on_mount :require_admin`): `:index` lists
  groups, `:new`/`:edit` are the builder form, `:show` lists a group's members.
  """

  use VutuvWeb, :live_view

  alias Vutuv.Newsletters
  alias Vutuv.Newsletters.NewsletterGroup
  alias VutuvWeb.UserHelpers

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:country_options, Newsletters.country_options())
     |> assign(:groups, Newsletters.list_groups())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, gettext("Newsletter audiences"))
    |> assign(:groups, Newsletters.list_groups())
  end

  defp apply_action(socket, :new, _params) do
    base = %NewsletterGroup{name: default_name()}
    socket |> init_curation(base) |> prepare_form(base, %{}, gettext("New audience"))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    with_group(socket, id, fn group ->
      base = %{group | tag_name: group.tag && group.tag.name}
      socket |> init_curation(base) |> prepare_form(base, %{}, gettext("Edit audience"))
    end)
  end

  defp apply_action(socket, :show, %{"id" => id} = params) do
    with_group(socket, id, fn group ->
      socket
      |> assign(:page_title, group.name)
      |> assign(:group, group)
      |> assign(:member_count, Newsletters.group_member_count(group))
      |> assign(:members, Newsletters.list_group_members(group, params))
      |> assign(:params, params)
    end)
  end

  defp with_group(socket, id, fun) do
    case Newsletters.get_group(id) do
      nil ->
        socket
        |> put_flash(:error, gettext("That audience could not be found."))
        |> push_navigate(to: ~p"/admin/newsletter_groups")

      group ->
        fun.(group)
    end
  end

  # The per-account curation state (which survives filter changes and paging):
  # the build mode, the manual include/exclude lists, the member search, and the
  # list page.
  defp init_curation(socket, base) do
    socket
    |> assign(:mode, initial_mode(base))
    |> assign(:included_user_ids, base.included_user_ids || [])
    |> assign(:excluded_user_ids, base.excluded_user_ids || [])
    |> assign(:member_search, "")
    |> assign(:list_page, 1)
  end

  # An existing group reopens in the mode it was built in: a pure hand-picked
  # allowlist (specific accounts, no filters) in `:accounts`, everything else in
  # `:filters`. A brand-new group starts in `:filters` (the default builder).
  defp initial_mode(%NewsletterGroup{} = base) do
    if (base.included_user_ids || []) != [] and no_filters?(base),
      do: :accounts,
      else: :filters
  end

  defp no_filters?(%NewsletterGroup{} = base) do
    Enum.all?(
      [base.country, base.min_age, base.max_age, base.tag_id, base.username],
      &is_nil/1
    ) and base.locales == [] and base.included_group_ids == [] and base.excluded_group_ids == []
  end

  # A ready-to-use, editable default name carrying the moment it was opened
  # (Berlin wall-clock time, matching the rest of the app).
  defp default_name do
    gettext("Audience %{stamp}",
      stamp: Calendar.strftime(Vutuv.BerlinTime.now(), "%Y-%m-%d %H:%M")
    )
  end

  # Builds the form + the live count/list for the given base struct and params.
  defp prepare_form(socket, base, params, title) do
    changeset = NewsletterGroup.changeset(base, params)
    {filter_criteria, tag, max_size} = parse(params, base)

    socket
    |> assign(:page_title, title)
    |> assign(:base, base)
    |> assign(:filter_criteria, filter_criteria)
    |> assign(:max_size, max_size)
    |> put_changeset(changeset)
    |> assign(:tag, tag)
    |> assign(:tag_typed?, typed?(params, base))
    |> recompute()
  end

  # Show the error banner only when the form is actually invalid: form_error/1
  # renders whenever `:action` is set, so a valid live preview (the common case
  # while tweaking filters) must leave it unset — otherwise every filter change
  # flashes a spurious "check your inputs".
  defp flag_errors(changeset) do
    if changeset.valid?, do: changeset, else: Map.put(changeset, :action, :validate)
  end

  # Keep @changeset (for the error banner) and @form (the to_form binding) in step.
  defp put_changeset(socket, changeset) do
    socket
    |> assign(:changeset, changeset)
    |> assign(:form, to_form(changeset, as: :newsletter_group))
  end

  @impl true
  def handle_event("preview", params, socket) do
    base = socket.assigns.base
    np = params["newsletter_group"] || %{}
    changeset = base |> NewsletterGroup.changeset(np) |> flag_errors()
    {filter_criteria, tag, max_size} = parse(np, base)

    {:noreply,
     socket
     |> assign(:filter_criteria, filter_criteria)
     |> assign(:max_size, max_size)
     |> assign(:member_search, params["member_search"] || "")
     |> assign(:list_page, 1)
     |> put_changeset(changeset)
     |> assign(:tag, tag)
     |> assign(:tag_typed?, typed?(np, base))
     |> recompute()}
  end

  def handle_event("save", %{"newsletter_group" => params}, socket) do
    params = finalize_params(params, socket.assigns)

    result =
      case socket.assigns.live_action do
        :new -> Newsletters.create_group(params)
        :edit -> Newsletters.update_group(socket.assigns.base, params)
      end

    case result do
      {:ok, group} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Audience \"%{name}\" saved (%{count} members).",
             name: group.name,
             count: delimited_count(group.member_count)
           )
         )
         |> push_navigate(to: ~p"/admin/newsletter_groups")}

      {:error, changeset} ->
        {:noreply, put_changeset(socket, Map.put(changeset, :action, :insert))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Newsletters.get_group(id) do
      nil -> {:noreply, socket}
      group -> {:ok, _} = Newsletters.delete_group(group)
    end

    {:noreply,
     socket
     |> put_flash(:info, gettext("Audience deleted."))
     |> push_navigate(to: ~p"/admin/newsletter_groups")}
  end

  def handle_event("list_page", %{"page" => page}, socket) do
    page = (to_int(page) || 1) |> max(1) |> min(list_pages(socket.assigns.list_total))
    {:noreply, socket |> assign(:list_page, page) |> assign_list()}
  end

  # Tick/untick an account: ticked (in group) -> exclude it; unticked -> include it.
  def handle_event("toggle_member", %{"id" => id, "checked" => checked}, socket) do
    {included, excluded} =
      if checked == "true" do
        {List.delete(socket.assigns.included_user_ids, id),
         uniq_prepend(socket.assigns.excluded_user_ids, id)}
      else
        {uniq_prepend(socket.assigns.included_user_ids, id),
         List.delete(socket.assigns.excluded_user_ids, id)}
      end

    {:noreply,
     socket
     |> assign(:included_user_ids, included)
     |> assign(:excluded_user_ids, excluded)
     |> recompute()}
  end

  # Undo a manual exclusion (the chip's ✕): drop it from the excluded list.
  def handle_event("restore_member", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:excluded_user_ids, List.delete(socket.assigns.excluded_user_ids, id))
     |> recompute()}
  end

  # Switch between the filter builder and the hand-picked-accounts allowlist.
  # Entering accounts mode drops any exclusions: an allowlist has no exclusion
  # UI, so they would be invisible dead state (this matches what `finalize_params`
  # already persists on an accounts-mode save).
  def handle_event("set_mode", %{"mode" => mode}, socket) do
    mode = if mode == "accounts", do: :accounts, else: :filters
    excluded = if mode == :accounts, do: [], else: socket.assigns.excluded_user_ids

    {:noreply,
     socket
     |> assign(:mode, mode)
     |> assign(:excluded_user_ids, excluded)
     |> assign(:member_search, "")
     |> assign(:list_page, 1)
     |> recompute()}
  end

  # Accounts mode: add a searched member to the allowlist (and lift any stale
  # exclusion of them).
  def handle_event("add_member", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:included_user_ids, uniq_prepend(socket.assigns.included_user_ids, id))
     |> assign(:excluded_user_ids, List.delete(socket.assigns.excluded_user_ids, id))
     |> recompute()}
  end

  # Accounts mode: drop a member from the allowlist.
  def handle_event("remove_member", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:included_user_ids, List.delete(socket.assigns.included_user_ids, id))
     |> recompute()}
  end

  def handle_event("select_all", _params, socket), do: {:noreply, bulk_select(socket, true)}
  def handle_event("unselect_all", _params, socket), do: {:noreply, bulk_select(socket, false)}

  # Select/unselect every member of the current view (the whole audience, or all
  # search matches — not just the visible page).
  defp bulk_select(socket, select?) do
    target = current_view_ids(socket)
    included = socket.assigns.included_user_ids
    excluded = socket.assigns.excluded_user_ids

    {included, excluded} =
      if select? do
        {Enum.uniq(included ++ target), excluded -- target}
      else
        {included -- target, Enum.uniq(excluded ++ target)}
      end

    socket
    |> assign(:included_user_ids, included)
    |> assign(:excluded_user_ids, excluded)
    |> recompute()
  end

  # The ids select-all/unselect-all act on: all search matches when searching,
  # otherwise everything the filters/groups match *ignoring* the per-account
  # overrides — so "select all" can still restore everyone after "unselect all".
  defp current_view_ids(socket) do
    if socket.assigns.member_search in [nil, ""] do
      base = %{socket.assigns.criteria | included_user_ids: [], excluded_user_ids: []}
      Newsletters.audience_user_ids(base)
    else
      Newsletters.search_member_ids(socket.assigns.member_search)
    end
  end

  defp uniq_prepend(list, id), do: if(id in list, do: list, else: [id | list])

  # Parses raw form params into a criteria map for the live count, plus the
  # resolved tag and the size cap.
  defp parse(params, base) do
    tag = Newsletters.find_tag(tag_name(params, base))

    criteria = %{
      locales:
        params
        |> Map.get("locales", base.locales)
        |> List.wrap()
        |> Enum.filter(&(&1 in NewsletterGroup.locales())),
      country: blank_nil(Map.get(params, "country", base.country)),
      min_age: to_int(Map.get(params, "min_age", base.min_age)),
      max_age: to_int(Map.get(params, "max_age", base.max_age)),
      tag_id: tag && tag.id,
      username: blank_nil(Map.get(params, "username", base.username)),
      included_group_ids: id_list(params, "included_group_ids", base.included_group_ids),
      excluded_group_ids: id_list(params, "excluded_group_ids", base.excluded_group_ids)
    }

    {criteria, tag, to_int(Map.get(params, "max_size", base.max_size))}
  end

  defp id_list(params, key, default) do
    params |> Map.get(key, default) |> List.wrap() |> Enum.reject(&(&1 in [nil, ""]))
  end

  # Merge the filter criteria with the manual include/exclude lists, recompute
  # the count, then the displayed member list. In accounts mode the filters and
  # the size cap are ignored: the audience is exactly the chosen accounts.
  defp recompute(socket) do
    assigns = socket.assigns
    filters = if assigns.mode == :accounts, do: %{}, else: assigns.filter_criteria

    criteria =
      Map.merge(filters, %{
        included_user_ids: assigns.included_user_ids,
        excluded_user_ids: assigns.excluded_user_ids
      })

    # An empty allowlist is *nobody* (0), not everyone: a criteria map with no
    # positive selector matches everyone by design, which is right for the
    # filter builder but wrong for a hand-picked list that just hasn't been
    # filled yet.
    match =
      if assigns.mode == :accounts and assigns.included_user_ids == [],
        do: 0,
        else: Newsletters.audience_count(criteria)

    cap = if assigns.mode == :accounts, do: nil, else: assigns.max_size

    effective = if is_integer(cap) and cap < match, do: cap, else: match

    socket
    |> assign(:criteria, criteria)
    |> assign(:match_count, match)
    |> assign(:effective_count, effective)
    |> assign_mode_lists(assigns)
    |> assign_list()
  end

  # The per-mode member lists: only the one the active mode renders is fetched,
  # so a filter tweak never resolves the (unused) chosen-accounts list and an
  # account toggle never resolves the (unused) "Removed" chips.
  defp assign_mode_lists(socket, %{mode: :accounts} = assigns) do
    socket
    |> assign(:included_users, Newsletters.users_by_ids(assigns.included_user_ids))
    |> assign(:excluded_users, [])
    |> assign(:excluded_extra, 0)
  end

  defp assign_mode_lists(socket, assigns) do
    socket
    |> assign(:included_users, [])
    |> assign_excluded_chips(assigns.excluded_user_ids)
  end

  # On save, fold the curation lists into the params. In accounts mode the group
  # is persisted as a pure allowlist: every filter field is reset (the inputs are
  # hidden in this mode, so a converted group must not keep matching by filter)
  # and only the chosen accounts remain.
  defp finalize_params(params, %{mode: :accounts} = assigns) do
    Map.merge(params, %{
      "locales" => [],
      "country" => "",
      "min_age" => nil,
      "max_age" => nil,
      "max_size" => nil,
      "random_sample" => "false",
      "username" => "",
      "tag_name" => "",
      "included_group_ids" => [],
      "excluded_group_ids" => [],
      "included_user_ids" => assigns.included_user_ids,
      "excluded_user_ids" => []
    })
  end

  defp finalize_params(params, assigns) do
    Map.merge(params, %{
      "included_user_ids" => assigns.included_user_ids,
      "excluded_user_ids" => assigns.excluded_user_ids
    })
  end

  # The "Removed" chips, capped so a bulk unselect-all can't render thousands.
  @chip_cap 12
  defp assign_excluded_chips(socket, ids) do
    socket
    |> assign(:excluded_users, Newsletters.users_by_ids(Enum.take(ids, @chip_cap)))
    |> assign(:excluded_extra, max(length(ids) - @chip_cap, 0))
  end

  # The curation list. When searching, the eligible members matching the search
  # (so any account can be found to add) in either mode. When not searching:
  # the filter audience in filters mode; in accounts mode the chosen allowlist
  # is rendered from `@included_users` instead, so no preview query runs. Each
  # row's tick/added state comes from `members_checked` — in filters mode the
  # ids actually in the audience, in accounts mode the allowlist itself.
  defp assign_list(socket) do
    assigns = socket.assigns
    per_page = Newsletters.preview_limit()
    searching? = assigns.member_search not in [nil, ""]

    {rows, total} =
      cond do
        searching? ->
          {Newsletters.search_members(assigns.member_search,
             page: assigns.list_page,
             per_page: per_page
           ), Newsletters.search_members_count(assigns.member_search)}

        assigns.mode == :accounts ->
          {[], 0}

        true ->
          {Newsletters.audience_preview(assigns.criteria,
             page: assigns.list_page,
             per_page: per_page
           ), assigns.match_count}
      end

    checked =
      if assigns.mode == :accounts do
        MapSet.new(assigns.included_user_ids)
      else
        MapSet.new(Newsletters.audience_member_ids(assigns.criteria, Enum.map(rows, & &1.id)))
      end

    socket
    |> assign(:members, rows)
    |> assign(:members_checked, checked)
    |> assign(:list_total, total)
  end

  defp list_pages(total) do
    per_page = Newsletters.preview_limit()
    max(div(total + per_page - 1, per_page), 1)
  end

  defp tag_name(params, base), do: Map.get(params, "tag_name", base.tag_name)
  defp typed?(params, base), do: String.trim(tag_name(params, base) || "") != ""

  defp blank_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp blank_nil(value), do: value

  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp to_int(_value), do: nil

  # A one-line description of a group's filters, for the index.
  defp summary(group) do
    [
      locales_summary(group.locales),
      group.country,
      age_summary(group.min_age, group.max_age),
      group.tag && gettext("tag: %{name}", name: group.tag.name),
      group.username && "@#{group.username}",
      group.max_size && gettext("max %{count}", count: group.max_size),
      inclusions_summary(group.included_group_ids),
      exclusions_summary(group.excluded_group_ids),
      accounts_summary("+", group.included_user_ids),
      accounts_summary("−", group.excluded_user_ids)
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> gettext("all members")
      parts -> Enum.join(parts, " · ")
    end
  end

  defp locales_summary([]), do: nil
  defp locales_summary(locales), do: Enum.join(locales, "/")

  defp age_summary(nil, nil), do: nil
  defp age_summary(min, nil), do: "#{min}+"
  defp age_summary(nil, max), do: "≤#{max}"
  defp age_summary(min, max), do: "#{min}-#{max}"

  defp inclusions_summary([]), do: nil

  defp inclusions_summary(ids),
    do: ngettext("plus 1 group", "plus %{count} groups", length(ids))

  defp exclusions_summary([]), do: nil

  defp exclusions_summary(ids),
    do: ngettext("minus 1 group", "minus %{count} groups", length(ids))

  defp accounts_summary(_sign, []), do: nil

  defp accounts_summary(sign, ids),
    do: "#{sign}#{compact_count(length(ids))} " <> gettext("accounts")

  @impl true
  def render(%{live_action: :index} = assigns), do: render_index(assigns)
  def render(%{live_action: :show} = assigns), do: render_show(assigns)
  def render(assigns), do: render_form(assigns)

  # A profile link showing a member's avatar, name and @handle — the one row of
  # member markup, reused by the show-page grid, the filter preview and the two
  # account pickers. `class` styles the link itself (full-width clickable row in
  # the grid; a compact cell beside an action button in the pickers).
  attr(:user, :any, required: true)
  attr(:class, :string, default: "flex min-w-0 items-center gap-2")

  defp member_link(assigns) do
    ~H"""
    <.link navigate={~p"/#{@user}"} class={@class}>
      <.avatar user={@user} size="xs" />
      <span class="min-w-0">
        <span class="block truncate text-sm font-medium text-slate-800 dark:text-slate-100">
          {UserHelpers.full_name(@user)}
        </span>
        <span class="block truncate text-xs text-slate-600 dark:text-slate-400">@{@user.username}</span>
      </span>
    </.link>
    """
  end

  # A grid of members, each linking to their profile. Shared by the builder
  # preview and the show page.
  attr(:users, :list, required: true)

  defp member_grid(assigns) do
    ~H"""
    <ul class="grid gap-1 sm:grid-cols-2 lg:grid-cols-3">
      <li :for={user <- @users}>
        <.member_link
          user={user}
          class="flex items-center gap-2 rounded-lg p-2 hover:bg-slate-50 dark:hover:bg-slate-800"
        />
      </li>
    </ul>
    """
  end

  defp render_index(assigns) do
    ~H"""
    <.page_header title={gettext("Newsletter audiences")} crumbs={[{gettext("Admin"), ~p"/admin"}, {gettext("Newsletters"), ~p"/admin/newsletters"}, gettext("Audiences")]} />

    <div class="card-list">
      <section class="card">
        <div class="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1>{gettext("Audiences")}</h1>
            <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">
              {gettext("Build a fixed group from filters, then send a newsletter to it. Subtract another group to do a test run, then send to the rest.")}
            </p>
          </div>
          <.link navigate={~p"/admin/newsletter_groups/new"} class="button" id="new-audience">
            {gettext("New audience")}
          </.link>
        </div>

        <p :if={@groups == []} class="card__empty">{gettext("No audiences yet.")}</p>

        <div :if={@groups != []} class="card__tablewrap">
          <table class="pure-table">
            <thead>
              <tr>
                <th>{gettext("Name")}</th>
                <th>{gettext("Filters")}</th>
                <th>{gettext("Members")}</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={group <- @groups} id={"group-#{group.id}"}>
                <td>
                  <.link
                    navigate={~p"/admin/newsletter_groups/#{group.id}"}
                    class="font-semibold text-brand-700 hover:text-brand-800 dark:text-brand-300"
                  >
                    {group.name}
                  </.link>
                </td>
                <td class="text-sm text-slate-600 dark:text-slate-400">{summary(group)}</td>
                <td>{compact_count(group.member_count)}</td>
                <td class="text-right">
                  <.link
                    navigate={~p"/admin/newsletter_groups/#{group.id}/edit"}
                    class="font-semibold text-brand-600 hover:text-brand-700"
                  >
                    {gettext("Edit")}
                  </.link>
                  <button
                    type="button"
                    phx-click="delete"
                    phx-value-id={group.id}
                    data-confirm={gettext("Delete this audience?")}
                    class="ml-3 font-semibold text-rose-600 hover:text-rose-700"
                  >
                    {gettext("Delete")}
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </div>
    """
  end

  defp render_show(assigns) do
    ~H"""
    <.page_header
      title={@group.name}
      crumbs={[{gettext("Admin"), ~p"/admin"}, {gettext("Newsletters"), ~p"/admin/newsletters"}, {gettext("Audiences"), ~p"/admin/newsletter_groups"}, @group.name]}
    />

    <div class="card-list">
      <section class="card">
        <div class="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1>{@group.name}</h1>
            <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">{summary(@group)}</p>
          </div>
          <div class="flex items-center gap-3">
            <.link
              navigate={~p"/admin/newsletter_groups/#{@group.id}/edit"}
              class="button button--secondary"
            >
              {gettext("Edit")}
            </.link>
            <button
              type="button"
              phx-click="delete"
              phx-value-id={@group.id}
              data-confirm={gettext("Delete this audience?")}
              class="font-semibold text-rose-600 hover:text-rose-700"
            >
              {gettext("Delete")}
            </button>
          </div>
        </div>
      </section>

      <section class="card">
        <h1 class="flex items-center gap-2">
          {gettext("Members")}
          <.count_badge count={@member_count} />
        </h1>
        <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">
          {gettext("The frozen snapshot saved with this audience. Click a name to open the profile.")}
        </p>

        <p :if={@members == []} class="card__empty">{gettext("This audience has no members.")}</p>

        <div :if={@members != []} class="mt-3">
          <.member_grid users={@members} />
        </div>

        <.pager params={@params} total={@member_count} per_page={Newsletters.members_per_page()} />
      </section>
    </div>
    """
  end

  defp render_form(assigns) do
    ~H"""
    <.page_header
      title={@page_title}
      crumbs={[{gettext("Admin"), ~p"/admin"}, {gettext("Newsletters"), ~p"/admin/newsletters"}, {gettext("Audiences"), ~p"/admin/newsletter_groups"}, @page_title]}
    />

    <div class="card-list">
      <section class="card">
        <.form
          for={@form}
          phx-change="preview"
          phx-submit="save"
          id="group-form"
          class="space-y-5"
        >
          <.form_error changeset={@changeset} />

          <div>
            <label for="group_name" class="block text-sm font-semibold text-slate-700 dark:text-slate-200">
              {gettext("Audience name")}
            </label>
            <input
              type="text"
              name="newsletter_group[name]"
              id="group_name"
              value={@form[:name].value}
              class={input_class()}
              phx-debounce="300"
            />
          </div>

          <div>
            <span class="block text-sm font-semibold text-slate-700 dark:text-slate-200">
              {gettext("How to build this audience")}
            </span>
            <div
              class="mt-2 inline-flex rounded-lg border border-slate-300 p-1 dark:border-slate-700"
              role="group"
            >
              <button
                type="button"
                id="mode-filters"
                phx-click="set_mode"
                phx-value-mode="filters"
                class={mode_tab_class(@mode == :filters)}
              >
                {gettext("From filters")}
              </button>
              <button
                type="button"
                id="mode-accounts"
                phx-click="set_mode"
                phx-value-mode="accounts"
                class={mode_tab_class(@mode == :accounts)}
              >
                {gettext("Specific accounts")}
              </button>
            </div>
            <p class="mt-1 text-xs text-slate-600 dark:text-slate-400">
              {gettext("Pick members from filters, or hand-pick specific accounts (e.g. a small group of testers).")}
            </p>
          </div>

          <div :if={@mode == :filters} class="space-y-5">
            <div class="grid gap-5 sm:grid-cols-2">
              <div>
                <span class="block text-sm font-semibold text-slate-700 dark:text-slate-200">
                  {gettext("Language")}
                </span>
              <input type="hidden" name="newsletter_group[locales][]" value="" />
              <div class="mt-2 flex flex-wrap gap-4">
                <label :for={loc <- NewsletterGroup.locales()} class="inline-flex items-center gap-2 text-sm">
                  <input
                    type="checkbox"
                    name="newsletter_group[locales][]"
                    value={loc}
                    checked={loc in (@form[:locales].value || [])}
                    class={checkbox_class()}
                  />
                  {loc}
                </label>
              </div>
            </div>

            <div>
              <label for="group_country" class="block text-sm font-semibold text-slate-700 dark:text-slate-200">
                {gettext("Country")}
              </label>
              <select name="newsletter_group[country]" id="group_country" class={input_class()}>
                <option value="">{gettext("Any country")}</option>
                <option :for={c <- @country_options} value={c} selected={c == @form[:country].value}>{c}</option>
              </select>
            </div>

            <div>
              <label for="group_min_age" class="block text-sm font-semibold text-slate-700 dark:text-slate-200">
                {gettext("Minimum age")}
              </label>
              <input
                type="number"
                name="newsletter_group[min_age]"
                id="group_min_age"
                min="0"
                value={@form[:min_age].value}
                class={input_class()}
                phx-debounce="300"
              />
            </div>

            <div>
              <label for="group_max_age" class="block text-sm font-semibold text-slate-700 dark:text-slate-200">
                {gettext("Maximum age")}
              </label>
              <input
                type="number"
                name="newsletter_group[max_age]"
                id="group_max_age"
                min="0"
                value={@form[:max_age].value}
                class={input_class()}
                phx-debounce="300"
              />
            </div>

            <div>
              <label for="group_tag" class="block text-sm font-semibold text-slate-700 dark:text-slate-200">
                {gettext("Tag")}
              </label>
              <input
                type="text"
                name="newsletter_group[tag_name]"
                id="group_tag"
                value={@form[:tag_name].value}
                placeholder={gettext("exact tag name")}
                class={input_class()}
                phx-debounce="300"
              />
              <p :if={@tag} class="mt-1 text-xs font-normal text-emerald-700 dark:text-emerald-400">
                {gettext("Tag found: %{name}", name: @tag.name)}
              </p>
              <p :if={@tag_typed? and is_nil(@tag)} class="mt-1 text-xs font-normal text-rose-600">
                {gettext("No tag with that name.")}
              </p>
            </div>

            <div>
              <label for="group_username" class="block text-sm font-semibold text-slate-700 dark:text-slate-200">
                {gettext("Username")}
              </label>
              <input
                type="text"
                name="newsletter_group[username]"
                id="group_username"
                value={@form[:username].value}
                placeholder={gettext("e.g. stefan* or *meyer")}
                class={input_class()}
                phx-debounce="300"
              />
              <p class="mt-1 text-xs font-normal text-slate-600 dark:text-slate-400">
                {gettext("Use * as a wildcard; a plain text matches anywhere in the handle.")}
              </p>
            </div>

            <div>
              <label for="group_max_size" class="block text-sm font-semibold text-slate-700 dark:text-slate-200">
                {gettext("Cap group size (optional)")}
              </label>
              <input
                type="number"
                name="newsletter_group[max_size]"
                id="group_max_size"
                min="1"
                value={@form[:max_size].value}
                placeholder={gettext("e.g. 100 for a test run")}
                class={input_class()}
                phx-debounce="300"
              />
              <label class="mt-2 flex items-start gap-2 text-sm font-normal text-slate-700 dark:text-slate-200">
                <input type="hidden" name="newsletter_group[random_sample]" value="false" />
                <input
                  type="checkbox"
                  name="newsletter_group[random_sample]"
                  id="group_random"
                  value="true"
                  checked={@form[:random_sample].value in [true, "true"]}
                  class={checkbox_class()}
                />
                <span>
                  {gettext("Pick capped members at random")}
                  <span class="block text-xs text-slate-600 dark:text-slate-400">
                    {gettext("Off: take the oldest members first (by join date).")}
                  </span>
                </span>
              </label>
            </div>
          </div>

          <div :if={other_groups(@groups, @base) != []} class="grid gap-5 sm:grid-cols-2">
            <div>
              <span class="block text-sm font-semibold text-slate-700 dark:text-slate-200">
                {gettext("Add these audiences")}
              </span>
              <p class="text-xs text-slate-600 dark:text-slate-400">
                {gettext("Their members are added to this one (union).")}
              </p>
              <input type="hidden" name="newsletter_group[included_group_ids][]" value="" />
              <div class="mt-2 space-y-1">
                <label
                  :for={g <- other_groups(@groups, @base)}
                  class="flex items-center gap-2 text-sm"
                >
                  <input
                    type="checkbox"
                    name="newsletter_group[included_group_ids][]"
                    value={g.id}
                    checked={g.id in (@form[:included_group_ids].value || [])}
                    class={checkbox_class()}
                  />
                  {g.name} <span class="text-slate-600 dark:text-slate-400">({compact_count(g.member_count)})</span>
                </label>
              </div>
            </div>

            <div>
              <span class="block text-sm font-semibold text-slate-700 dark:text-slate-200">
                {gettext("Subtract these audiences")}
              </span>
              <p class="text-xs text-slate-600 dark:text-slate-400">
                {gettext("Their members are removed from this one (e.g. exclude the test group to send to \"the rest\").")}
              </p>
              <input type="hidden" name="newsletter_group[excluded_group_ids][]" value="" />
              <div class="mt-2 space-y-1">
                <label
                  :for={g <- other_groups(@groups, @base)}
                  class="flex items-center gap-2 text-sm"
                >
                  <input
                    type="checkbox"
                    name="newsletter_group[excluded_group_ids][]"
                    value={g.id}
                    checked={g.id in (@form[:excluded_group_ids].value || [])}
                    class={checkbox_class()}
                  />
                  {g.name} <span class="text-slate-600 dark:text-slate-400">({compact_count(g.member_count)})</span>
                </label>
              </div>
            </div>
          </div>

          <div class="rounded-lg bg-brand-50 p-4 dark:bg-brand-900/30">
            <p class="text-sm text-slate-700 dark:text-slate-200">
              {gettext("Members matching")}:
              <strong class="text-lg" id="match-count">{delimited_count(@match_count)}</strong>
            </p>
            <p :if={@effective_count != @match_count} class="mt-1 text-sm text-slate-700 dark:text-slate-200">
              {gettext("This audience will be capped to")}:
              <strong id="effective-count">{delimited_count(@effective_count)}</strong>
            </p>
          </div>

          <div id="audience-preview" class="space-y-3">
            <div>
              <label
                for="member_search"
                class="block text-sm font-semibold text-slate-700 dark:text-slate-200"
              >
                {gettext("Choose specific accounts")}
              </label>
              <p class="text-xs text-slate-600 dark:text-slate-400">
                {gettext("Tick to include an account, untick to exclude it. Search by @handle to find anyone.")}
              </p>
              <input
                type="text"
                name="member_search"
                id="member_search"
                value={@member_search}
                placeholder={gettext("search by @handle…")}
                class={[input_class(), "mt-1"]}
                phx-debounce="300"
              />
            </div>

            <div :if={@excluded_users != []} class="flex flex-wrap items-center gap-2">
              <span class="text-sm text-slate-600 dark:text-slate-400">{gettext("Removed:")}</span>
              <button
                :for={u <- @excluded_users}
                type="button"
                phx-click="restore_member"
                phx-value-id={u.id}
                title={gettext("Undo")}
                class="inline-flex items-center gap-1 rounded-full bg-rose-100 px-2 py-0.5 text-xs font-medium text-rose-700 hover:bg-rose-200 dark:bg-rose-900/40 dark:text-rose-200"
              >
                @{u.username} ✕
              </button>
              <span :if={@excluded_extra > 0} class="text-xs text-slate-600 dark:text-slate-400">
                {gettext("+%{count} more", count: compact_count(@excluded_extra))}
              </span>
            </div>

            <div class="flex flex-wrap items-center gap-3">
              <button type="button" phx-click="select_all" class={preview_nav_class()}>
                {gettext("Select all")}
              </button>
              <button type="button" phx-click="unselect_all" class={preview_nav_class()}>
                {gettext("Unselect all")}
              </button>
              <span class="text-xs text-slate-600 dark:text-slate-400">
                {gettext("applies to the whole list, not just this page")}
              </span>
            </div>

            <.list_pager
              label={
                if @member_search in [nil, ""],
                  do: gettext("Preview"),
                  else: gettext("Search results")
              }
              page={@list_page}
              total={@list_total}
            />

            <p :if={@members == []} class="card__empty">{gettext("No members.")}</p>

            <ul :if={@members != []} class="grid gap-1 sm:grid-cols-2 lg:grid-cols-3">
              <li
                :for={user <- @members}
                class="flex items-center gap-2 rounded-lg p-2 hover:bg-slate-50 dark:hover:bg-slate-800"
              >
                <button
                  type="button"
                  phx-click="toggle_member"
                  phx-value-id={user.id}
                  phx-value-checked={to_string(user.id in @members_checked)}
                  role="checkbox"
                  aria-checked={to_string(user.id in @members_checked)}
                  title={gettext("In this audience")}
                  class={[
                    "flex h-5 w-5 shrink-0 items-center justify-center rounded border text-xs leading-none",
                    if(user.id in @members_checked,
                      do: "border-brand-600 bg-brand-600 text-white",
                      else: "border-slate-300 dark:border-slate-600"
                    )
                  ]}
                >
                  <span :if={user.id in @members_checked}>✓</span>
                </button>
                <.member_link user={user} />
              </li>
            </ul>
          </div>
          </div>

          <div :if={@mode == :accounts} class="space-y-4">
            <div class="rounded-lg bg-brand-50 p-4 dark:bg-brand-900/30">
              <p class="text-sm text-slate-700 dark:text-slate-200">
                {gettext("Accounts in this audience")}:
                <strong class="text-lg" id="account-count">{delimited_count(@match_count)}</strong>
              </p>
              <p class="mt-1 text-xs text-slate-600 dark:text-slate-400">
                {gettext("Only these accounts get the newsletter. Search for members below and add them one by one.")}
              </p>
            </div>

            <div>
              <label
                for="account_search"
                class="block text-sm font-semibold text-slate-700 dark:text-slate-200"
              >
                {gettext("Find accounts to add")}
              </label>
              <input
                type="text"
                name="member_search"
                id="account_search"
                value={@member_search}
                placeholder={gettext("search by @handle…")}
                class={[input_class(), "mt-1"]}
                phx-debounce="300"
              />
            </div>

            <div :if={@member_search in [nil, ""]} id="chosen-accounts">
              <p class="text-sm font-semibold text-slate-700 dark:text-slate-200">
                {gettext("Chosen accounts")}
              </p>
              <p :if={@included_users == []} class="card__empty">
                {gettext("No accounts yet. Search above to add some.")}
              </p>
              <ul :if={@included_users != []} class="grid gap-1 sm:grid-cols-2 lg:grid-cols-3">
                <li
                  :for={user <- @included_users}
                  class="flex items-center gap-2 rounded-lg p-2 hover:bg-slate-50 dark:hover:bg-slate-800"
                >
                  <button
                    type="button"
                    phx-click="remove_member"
                    phx-value-id={user.id}
                    title={gettext("Remove from audience")}
                    class="flex h-5 w-5 shrink-0 items-center justify-center rounded-full bg-rose-100 text-xs leading-none text-rose-700 hover:bg-rose-200 dark:bg-rose-900/40 dark:text-rose-200"
                  >
                    ✕
                  </button>
                  <.member_link user={user} />
                </li>
              </ul>
            </div>

            <div :if={@member_search not in [nil, ""]} id="account-search-results" class="space-y-3">
              <.list_pager label={gettext("Search results")} page={@list_page} total={@list_total} />

              <p :if={@members == []} class="card__empty">{gettext("No members.")}</p>

              <ul :if={@members != []} class="grid gap-1 sm:grid-cols-2 lg:grid-cols-3">
                <li
                  :for={user <- @members}
                  class="flex items-center gap-2 rounded-lg p-2 hover:bg-slate-50 dark:hover:bg-slate-800"
                >
                  <%= if user.id in @members_checked do %>
                    <button
                      type="button"
                      phx-click="remove_member"
                      phx-value-id={user.id}
                      class="shrink-0 rounded-full bg-brand-600 px-2 py-0.5 text-xs font-semibold text-white"
                    >
                      {gettext("Added")} ✓
                    </button>
                  <% else %>
                    <button
                      type="button"
                      phx-click="add_member"
                      phx-value-id={user.id}
                      class="shrink-0 rounded-full bg-slate-100 px-2 py-0.5 text-xs font-semibold text-slate-700 hover:bg-slate-200 dark:bg-slate-800 dark:text-slate-200 dark:hover:bg-slate-700"
                    >
                      {gettext("Add to audience")}
                    </button>
                  <% end %>
                  <.member_link user={user} />
                </li>
              </ul>
            </div>
          </div>

          <div class="flex items-center gap-4">
            <.button type="submit">{gettext("Save audience")}</.button>
            <.link
              navigate={~p"/admin/newsletter_groups"}
              class="text-sm font-semibold text-slate-600 hover:text-slate-800 dark:text-slate-400 dark:hover:text-slate-200"
            >
              {gettext("Cancel")}
            </.link>
          </div>
        </.form>
      </section>
    </div>
    """
  end

  # The groups offered to add/subtract: every saved group except the one being edited.
  defp other_groups(groups, %NewsletterGroup{id: nil}), do: groups
  defp other_groups(groups, %NewsletterGroup{id: id}), do: Enum.reject(groups, &(&1.id == id))

  defp preview_nav_class do
    "rounded-lg bg-slate-100 px-3 py-1.5 text-sm font-semibold text-slate-700 hover:bg-slate-200 " <>
      "disabled:cursor-not-allowed disabled:opacity-40 dark:bg-slate-800 dark:text-slate-200 dark:hover:bg-slate-700"
  end

  # The "page X of Y, Z total" heading + Previous/Next controls shared by the
  # filters-mode preview and the accounts-mode search results.
  attr(:label, :string, required: true)
  attr(:page, :integer, required: true)
  attr(:total, :integer, required: true)

  defp list_pager(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center justify-between gap-2">
      <p class="text-sm font-semibold text-slate-700 dark:text-slate-200">
        {@label}
        <span class="font-normal text-slate-600 dark:text-slate-400">
          ({gettext("page %{page} of %{pages}, %{total} total",
            page: @page,
            pages: list_pages(@total),
            total: delimited_count(@total)
          )})
        </span>
      </p>
      <div :if={list_pages(@total) > 1} class="flex items-center gap-2">
        <button
          type="button"
          phx-click="list_page"
          phx-value-page={@page - 1}
          disabled={@page <= 1}
          class={preview_nav_class()}
        >
          {gettext("Previous")}
        </button>
        <button
          type="button"
          phx-click="list_page"
          phx-value-page={@page + 1}
          disabled={@page >= list_pages(@total)}
          class={preview_nav_class()}
        >
          {gettext("Next")}
        </button>
      </div>
    </div>
    """
  end

  # The segmented build-mode tab: brand-filled when active, quiet otherwise.
  defp mode_tab_class(true),
    do: "rounded-md px-3 py-1.5 text-sm font-semibold bg-brand-600 text-white"

  defp mode_tab_class(false),
    do:
      "rounded-md px-3 py-1.5 text-sm font-semibold text-slate-600 hover:text-slate-800 dark:text-slate-300 dark:hover:text-slate-100"
end
