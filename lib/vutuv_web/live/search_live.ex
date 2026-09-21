defmodule VutuvWeb.SearchLive do
  @moduledoc """
  Search-as-you-type. Results stream in once the query reaches three letters
  (`Vutuv.Search.instant/2`) and narrow with every keystroke; `?q=` (plus the
  `scope` and `exact` filters) is kept in sync via `push_patch` so a search
  stays shareable and reloadable. Exact name matches and phonetically similar
  ones render as clearly separated groups.

  Filters: scope chips (all / people / organizations / tags / posts) and an
  "exact matches only" toggle. **"All" is a preview**: the first few of every
  kind, each with a link into its full list, and a chosen kind is paged
  (`?page=`). People are found by name and also by the employers and schools
  on their CVs, each such row naming the entry that matched. An organization
  row's "N people" narrows the search to the people its page lists (`?org=`,
  current ones first), which pins the scope to people the way `ort:` does.
  Power users get operators instead, parsed by
  `Vutuv.Search.parse/2`: `vorname:`/`nachname:` (aliases `first:`/`last:`),
  `@handle`, double quotes for exact-only, and the combinable people filters
  `tag:`/`skill:` (has the tag) and `ort:`/`stadt:`/`city:` (has an address
  in the city) - "müller tag:php", "müller ort:koblenz".

  A query is recorded for the search history only after it settles (no
  keystroke for two seconds), so typing "meier" stores one query, not five.

  Two things people paste in here are not queries at all, and both get named
  and answered instead of searched: an `@name@server` address, which is offered
  the follow (issue #1160), and the address of a **post** on another network,
  which is offered the lookup that used to live at `/system/fediverse/lookup`
  alone (issue #1211). Recognising either is pure string work, so a keystroke
  never becomes an outbound request; both acts behind them are signed requests
  in the member's name against their hourly budget, so each happens on an
  explicit submit or click and never while they type, and neither button is
  offered to a member the gate would refuse. The follow is *sent from here* and
  lands the member on `/settings/fediverse/following` with it done — carrying
  the address over for them to press "Follow" a second time was the same click
  twice.
  """
  use VutuvWeb, :live_view

  import VutuvWeb.FediverseComponents,
    only: [
      follow_message: 1,
      follow_refusal_panel: 1,
      lookup_refusal_link: 1,
      lookup_refusal_message: 1,
      lookup_refusal_text: 1,
      refusal_message: 1
    ]

  import VutuvWeb.OrganizationComponents, only: [kind_badge: 1, organization_row: 1]
  import VutuvWeb.SavedSearchComponents

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.RemoteFollow
  alias Vutuv.Organizations
  alias Vutuv.Organizations.Organization
  alias Vutuv.Posts
  alias Vutuv.Profiles.Education
  alias Vutuv.Profiles.WorkExperience
  alias Vutuv.Search
  alias Vutuv.SearchText
  alias VutuvWeb.PostTeaser
  alias VutuvWeb.UserHelpers
  alias VutuvWeb.UserHTML
  alias VutuvWeb.WorkExperienceHTML

  @impl true
  def mount(_params, _session, socket) do
    current_user = socket.assigns[:current_user]

    {:ok,
     socket
     |> assign(:page_title, gettext("Search"))
     |> assign(:current_user_id, current_user && current_user.id)
     |> assign(:show_save?, false)
     |> assign(:saved?, false)
     # Whether this member could look a post up at all, asked once here rather
     # than per keystroke: it reads their federation state, and the answer is
     # the same for every query they type. `look_up_post/2` asks again at the
     # click, so participation ending in another tab is still refused.
     |> assign(:lookup_refusal, current_user && Fediverse.lookup_refusal(current_user))
     # The follow's twin of the same question (`follow_refusal/1` tells the four
     # situations apart where `federated?/1` collapses them). Without it the
     # card would offer a live button to somebody who cannot sign a Follow at
     # all, and answer their click with a page change instead of a sentence.
     |> assign(:follow_refusal, current_user && Fediverse.follow_refusal(current_user))
     |> assign(:remote_follow_error, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    q = params["q"] || ""
    scope = parse_scope(params["scope"])
    exact = params["exact"] == "1"
    page = Vutuv.Pages.page_param(params)
    org = public_organization(params["org"], socket.assigns[:org])

    # With an organization chosen the page lists its people and nothing else,
    # so the general search is not run at all.
    results =
      if is_nil(org),
        do:
          Search.page(q,
            scope: scope,
            exact: exact,
            page: page,
            viewer: socket.assigns[:current_user]
          )

    address = remote_address(q)
    post_url = remote_post_url(q)

    {:noreply,
     socket
     |> assign(:q, q)
     |> assign(:scope, scope)
     |> assign(:exact, exact)
     |> assign(:org, org)
     |> assign(:page_query, pager_query(q, scope, exact, org))
     # A new query invalidates any open/confirmed save panel.
     |> assign(:show_save?, false)
     |> assign(:saved?, false)
     |> assign(:saveable?, saveable?(results))
     # Operators in the query override the scope chips; highlight what the
     # search actually did and disable the chips that can do nothing (#846).
     # A chosen organization pins the scope to people the same way.
     |> assign(:effective_scope, effective_scope(results, org, scope))
     |> assign(:scope_pinned?, org != nil or (results != nil and results.parsed.scope_pinned?))
     |> assign(:results, results)
     |> assign(:remote_address, address)
     |> assign(:remote_post_url, post_url)
     # Both refusals belong to what they were about and die with it, so the card
     # is never still shouting about an address the member has since corrected.
     |> assign(:remote_follow_error, kept_follow_error(socket, address))
     # A refusal belongs to the address it was about: it survives the patch the
     # debounced keystroke sends after a submit, and dies the moment the pasted
     # address changes, so the card is never still shouting about a URL the
     # member has since corrected.
     |> assign(:remote_post_error, kept_post_error(socket, post_url))
     |> assign_needles(results)
     |> assign_people(results)
     |> assign_org_people(org, page)}
  end

  defp effective_scope(_results, %Organization{}, _scope), do: :people
  defp effective_scope(%{parsed: parsed}, nil, _scope), do: parsed.scope
  defp effective_scope(nil, nil, scope), do: scope

  # Only a page every visitor may open: a pending or frozen one shows its name
  # nowhere else, so an old `?org=` link must not list its people here either.
  # Anything else simply is no filter. Typing inside the filter patches the URL
  # on every keystroke, so the organization already loaded is kept.
  defp public_organization(slug, %Organization{slug: slug} = loaded), do: loaded

  defp public_organization(slug, _loaded) when is_binary(slug) and slug != "" do
    case Organizations.get_organization_by_slug(slug) do
      %Organization{} = org -> if Organizations.public_visible?(org), do: org
      nil -> nil
    end
  end

  defp public_organization(_slug, _loaded), do: nil

  defp kept_post_error(socket, post_url) do
    if post_url && post_url == socket.assigns[:remote_post_url],
      do: socket.assigns[:remote_post_error]
  end

  defp kept_follow_error(socket, address) do
    if address && address == socket.assigns[:remote_address],
      do: socket.assigns[:remote_follow_error]
  end

  # A full `@name@server` typed into the search box is not a vutuv query at all
  # — it is somebody's address on another network, and nothing here will ever
  # match it (issue #1160). So the page names what it is and offers the one
  # thing you can do with it. Nothing is resolved here: this is pure string
  # work, so a search keystroke never becomes an outbound request.
  defp remote_address(q) do
    with true <- Fediverse.enabled?(),
         {:ok, {name, host}} <- RemoteFollow.parse_address(String.trim(q)),
         # Through the context, so "is this our own installation?" is answered
         # the same way here as in the follow gate — otherwise this card offers
         # to follow an address `follow_remote/2` then refuses.
         false <- Fediverse.own_host?(host) do
      "@#{name}@#{host}"
    else
      _ -> nil
    end
  end

  # The other thing that is an answer rather than a query: the address of a
  # single post out there (issue #1211). Somebody reading a post on Mastodon and
  # wanting to answer it from here has the URL in their clipboard and a search
  # box in front of them, so this is where they paste it — a page under
  # `/system/` is not something anybody finds.
  #
  # Pure string work again, and told apart from the sibling above the way
  # `Fediverse.look_up_post/2` does it: a post URL has one path segment too many
  # for every shape `parse_address/1` accepts. Ours is excluded outright rather
  # than handed on with a "that is a link on this vutuv" — this card offers a
  # fetch from another network and must not open by misreading what was pasted.
  # `https` only, because that is what the fetch speaks.
  defp remote_post_url(q) do
    url = String.trim(q)

    with true <- Fediverse.enabled?(),
         %URI{scheme: "https", host: host} when is_binary(host) and host != "" <- URI.parse(url),
         false <- Fediverse.own_host?(url),
         {:error, _address} <- RemoteFollow.parse_address(url) do
      url
    else
      _ -> nil
    end
  end

  # What `highlight/2` marks per section. Exact people carry a literal
  # substring of the query in their name; similar (phonetic) matches do not,
  # so they deliberately stay unmarked. Slug and email matches are not part
  # of the rendered name either.
  defp assign_needles(socket, nil) do
    assign(socket, people_needles: [], tag_needle: nil, post_needles: [])
  end

  defp assign_needles(socket, %{parsed: parsed}) do
    people_needles =
      cond do
        parsed.slug -> []
        parsed.first_name || parsed.last_name -> [parsed.first_name, parsed.last_name]
        Search.email?(parsed.text) -> []
        true -> [parsed.text]
      end

    assign(socket,
      people_needles: people_needles,
      tag_needle: parsed.text,
      post_needles: String.split(parsed.text)
    )
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket),
    do: {:noreply, patch_search(socket, SearchText.cap(q))}

  # Enter on a pasted post address means "get me that post", which is the one
  # thing a text search can never do with it, so a submit takes the lookup where
  # a keystroke takes the search. Recomputed from the submitted value rather
  # than read off the assign: `phx-debounce` holds the change event back, so a
  # paste followed straight away by Enter arrives here first.
  def handle_event("submit-search", %{"q" => q}, socket) do
    q = SearchText.cap(q)
    socket = socket |> assign(:q, q) |> assign(:remote_post_url, remote_post_url(q))

    if lookup_offered?(socket),
      do: {:noreply, fetch_pasted_post(socket)},
      else: {:noreply, patch_search(socket, q)}
  end

  def handle_event("look-up-post", _params, socket) do
    if lookup_offered?(socket),
      do: {:noreply, fetch_pasted_post(socket)},
      else: {:noreply, socket}
  end

  def handle_event("follow-remote-address", _params, socket) do
    if follow_offered?(socket),
      do: {:noreply, follow_pasted_address(socket)},
      else: {:noreply, socket}
  end

  def handle_event("toggle_save_search", _params, socket),
    do: {:noreply, update(socket, :show_save?, &(not &1))}

  def handle_event("save_search", %{"notify" => notify}, socket),
    do: {:noreply, save_current_search(socket, notify)}

  defp patch_search(socket, q) do
    %{scope: scope, exact: exact, org: org} = socket.assigns
    push_patch(socket, to: search_path(q, scope, exact, org), replace: true)
  end

  # Whether the button is really there to press: a post address, a member, and
  # nothing standing in the way of signing the request for them.
  defp lookup_offered?(socket) do
    socket.assigns.remote_post_url != nil and socket.assigns.current_user != nil and
      socket.assigns.lookup_refusal == nil
  end

  # The same three questions for the follow: an address, a member, and nothing
  # standing in the way of signing the request in their name.
  defp follow_offered?(socket) do
    socket.assigns.remote_address != nil and socket.assigns.current_user != nil and
      socket.assigns.follow_refusal == nil
  end

  # The one outbound request this page can make, and only ever on an act of the
  # member's. The two answers the detector already rules out are still handled:
  # it and `look_up_post/2` ask the same two questions today, and a `case` that
  # assumed they always will would raise rather than navigate.
  defp fetch_pasted_post(socket) do
    case Fediverse.look_up_post(socket.assigns.current_user, socket.assigns.remote_post_url) do
      # Our copy has a page of its own — the one every remote card's timestamp
      # points at — so the reader lands somewhere they can come back to, with
      # the action bar, the ⋯ menu and the way on to the account.
      {:ok, post} ->
        push_navigate(socket, to: ~p"/system/fediverse/post/#{post.id}")

      {:local, post} ->
        push_navigate(socket, to: Posts.path(post))

      {:account, address} ->
        push_navigate(socket, to: ~p"/settings/fediverse/following?#{[address: address]}")

      {:error, reason} ->
        assign(socket, :remote_post_error, reason)
    end
  end

  # The other outbound request this page can make, and the twin of the one
  # above in every respect: the member's own click, their hourly budget, their
  # signature. It is sent from *here* rather than handed to
  # `/settings/fediverse/following` as a prefilled box — the member asked for
  # the follow once, and arriving on that page is a `GET`, which may not put a
  # signed request on a stranger's server on the strength of a link somebody
  # else wrote.
  #
  # A follow that goes through lands on that page, because the row, its state
  # and the way to take it back are all there. A refusal stays on this card,
  # like the pasted post's: the correction happens in the box above it, and the
  # settings page has nothing to add to "that server did not answer".
  defp follow_pasted_address(socket) do
    case Fediverse.follow_remote(socket.assigns.current_user, socket.assigns.remote_address) do
      {:ok, result} ->
        socket
        |> put_flash(:info, follow_message(result))
        |> push_navigate(to: ~p"/settings/fediverse/following")

      {:error, reason} ->
        assign(socket, :remote_follow_error, reason)
    end
  end

  # Only a people search with a structured operator (tag:/ort:/status:) is worth
  # saving as an alert — a bare free-text or name search never triggers a
  # people alert (issue #935), so the button stays hidden for it.
  defp saveable?(%{parsed: parsed}), do: Search.alertable?(parsed)
  defp saveable?(_results), do: false

  defp save_current_search(socket, notify) do
    query = search_query(socket.assigns.q, socket.assigns.scope, socket.assigns.exact)
    save_search(socket, :people, query, notify)
  end

  # The non-default query params behind both the stored query string and the
  # canonical /search URL: q, a non-default scope, exact and a chosen
  # organization — blanks dropped. The page travels separately, on the pager's
  # links, so any other change starts over on page one.
  defp search_params(q, scope, exact, org \\ nil) do
    [q: q, scope: scope != :all && scope, exact: exact && "1", org: org && org.slug]
    |> Enum.reject(fn {_k, v} -> v in ["", false, nil] end)
  end

  # The stored query string mirrors the /search URL (q + non-default scope +
  # exact), so the sweeper and the "run now" link replay the same search.
  defp search_query(q, scope, exact), do: search_params(q, scope, exact) |> URI.encode_query()

  @scopes ~w(all people organizations tags posts)

  defp parse_scope(scope) when scope in @scopes, do: String.to_existing_atom(scope)
  defp parse_scope(_scope), do: :all

  # The canonical /search URL for a query + filter combination; defaults stay
  # out of the query string so plain searches keep plain URLs.
  defp search_path(q, scope, exact, org \\ nil) do
    params = search_params(q, scope, exact, org)
    if params == [], do: ~p"/search", else: ~p"/search?#{params}"
  end

  # What the pager carries onto every page link, as the string-keyed map it wants.
  defp pager_query(q, scope, exact, org) do
    Map.new(search_params(q, scope, exact, org), fn {key, value} ->
      {Atom.to_string(key), to_string(value)}
    end)
  end

  # The people the page renders, and the page-wide maps `UserHTML.user_row/1`
  # expects for them, built once per query (one query each) and only for those
  # rows. `Search.page/2` has already cut them to this page or to the preview.
  defp assign_people(socket, nil) do
    assign(socket,
      people: %{shown: [], similar: [], main_total: 0, total: 0, capped?: false, page: 1},
      work_info_by_id: %{},
      following_by_id: %{}
    )
  end

  defp assign_people(socket, %{people: people, parsed: parsed}) do
    lines =
      people.cv
      |> Search.matched_entries(parsed.text, parsed.exact?)
      |> Map.new(fn {user_id, entry} -> {user_id, entry_line(entry)} end)

    assign(socket,
      people: Map.put(people, :shown, people.names ++ people.cv),
      work_info_by_id:
        UserHelpers.work_information_map(people.names ++ people.similar, 45)
        |> Map.merge(lines),
      following_by_id:
        UserHelpers.following_map(
          socket.assigns[:current_user],
          people.names ++ people.cv ++ people.similar
        )
    )
  end

  # The line under a person the search found through their CV: the entry that
  # matched, not their current job, which would name a company the query never
  # mentioned. The employer is named the way the profile names it, through
  # `WorkExperience.linked_organization/1`.
  defp entry_line(%WorkExperience{} = job) do
    employer =
      case WorkExperience.linked_organization(job) do
        nil -> job.organization
        page -> page.name
      end

    [job.title, employer]
    |> Enum.reject(&(is_nil(&1) or String.trim(&1) == ""))
    |> Enum.join(" @ ")
    |> with_period(job)
  end

  defp entry_line(%Education{} = education),
    do: (UserHelpers.education_headline(education, 80) || "") |> with_period(education)

  defp with_period(text, entry) do
    case WorkExperienceHTML.entry_period(entry) do
      nil -> text
      period -> text <> " · " <> period
    end
  end

  # One page of the chosen organization's people, current ones first: the
  # organization page's own People list (`Organizations.organization_people_page/2`),
  # narrowed by the name in the box. Each row shows the role the member holds or
  # held there.
  defp assign_org_people(socket, nil, _page), do: assign(socket, :org_people, nil)

  defp assign_org_people(socket, org, requested) do
    query = SearchText.cap(socket.assigns.q)
    per_page = Search.per_page(:people)
    total = Organizations.organization_people_count(org, query: query)
    page = min(requested, Vutuv.Pages.total_pages(total, per_page))

    %{entries: entries} =
      Organizations.organization_people_page(org,
        query: query,
        limit: per_page,
        offset: (page - 1) * per_page
      )

    users = Enum.map(entries, & &1.user)

    groups =
      entries
      |> Enum.chunk_by(& &1.current?)
      |> Enum.map(fn [first | _] = group -> {first.current?, Enum.map(group, & &1.user)} end)

    assign(socket,
      org_people: %{groups: groups, total: total, page: page},
      work_info_by_id: Map.new(entries, &{&1.user.id, &1.title || ""}),
      following_by_id: UserHelpers.following_map(socket.assigns[:current_user], users)
    )
  end

  # The people count in the heading. A list that ran into its cap does not know
  # its total, so it says "more than" rather than printing the cap as a count.
  defp people_total_label(%{capped?: true, total: total}),
    do: gettext("more than %{formatted}", formatted: delimited_count(total))

  defp people_total_label(%{total: total}), do: compact_count(total)

  # A separate placeholder, because `ngettext/4` binds `%{count}` to the raw
  # integer and a formatted number has to travel under another name.
  defp people_count_label(count) do
    ngettext("%{formatted} person", "%{formatted} people", count,
      formatted: delimited_count(count)
    )
  end

  # The link from a kind's preview under "All" into its full list.
  defp all_label(:people, %{capped?: true}), do: gettext("All people")

  defp all_label(:people, %{total: total}),
    do: gettext("All %{formatted} people", formatted: delimited_count(total))

  defp all_label(:organizations, %{total: total}),
    do: gettext("All %{formatted} organizations", formatted: delimited_count(total))

  defp all_label(:tags, %{total: total}),
    do: gettext("All %{formatted} tags", formatted: delimited_count(total))

  defp all_label(:posts, %{total: total}),
    do: gettext("All %{formatted} posts", formatted: delimited_count(total))

  attr(:kind, :atom, required: true)
  attr(:scope, :atom, required: true)
  attr(:more?, :boolean, required: true)
  attr(:label, :string, required: true)
  attr(:patch, :string, required: true)
  attr(:page, :integer, required: true)
  attr(:total, :integer, required: true)
  attr(:per_page, :integer, default: nil)
  attr(:query, :map, required: true)

  # The foot of a kind's card: under "All" the way into its full list when there
  # is more of it, under the kind's own scope its pager.
  defp kind_footer(assigns) do
    ~H"""
    <.link
      :if={@scope == :all and @more?}
      id={"search-#{@kind}-all"}
      patch={@patch}
      class="mt-4 inline-flex min-h-10 items-center text-sm font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
    >
      {@label} ›
    </.link>
    <div :if={@scope == @kind} id="search-pager">
      <.pager
        params={%{"page" => to_string(@page)}}
        total={@total}
        per_page={@per_page}
        path={~p"/search"}
        query={@query}
      />
    </div>
    """
  end

  defp scope_label(:all), do: gettext("All")
  defp scope_label(:people), do: gettext("People")
  defp scope_label(:organizations), do: gettext("Organizations")
  defp scope_label(:tags), do: gettext("Tags")
  defp scope_label(:posts), do: gettext("Posts")

  attr(:scope, :atom, required: true)

  # The scope-aware Search Tips body, rendered by BOTH the empty-query card and
  # the compact results-page disclosure so #887's scope-awareness applies in
  # both places (#861). It shows only the operators that actually work in the
  # active scope: the people operators (first:/last:, city:, status:, @handle)
  # and the phonetic "similar names" note apply on :all/:people; tag: filters
  # people AND posts (#946) so it applies on :all/:people/:posts but is dropped
  # on :tags (which searches tag names directly); the quotes/exact tip is
  # general. On a scope where a whole class of operators is irrelevant the tips
  # explain what this tab does instead of listing dead operators (#887 point 2).
  defp search_tips(assigns) do
    tips = Enum.filter(operator_tips(), &(assigns.scope in &1.scopes))
    assigns = assign(assigns, tips: tips, similar_names?: assigns.scope in [:all, :people])

    ~H"""
    <p class="text-sm text-slate-600 dark:text-slate-300">{tips_intro(@scope)}</p>
    <p :if={@similar_names?} class="mt-2 text-sm text-slate-600 dark:text-slate-300">
      {gettext(
        "Our search will try to match similar names to your search, so don't worry about spelling."
      )}
    </p>
    <%!-- m-0 / font-normal undo the legacy `dl dt`/`dl dd` element defaults
    from components.css so the grid rows line up. The operator examples are
    gettext'd too: every operator has a German and an English key (both always
    work), so each locale shows its own spelling. --%>
    <dl
      :if={@tips != []}
      id="search-syntax"
      class="mt-4 grid gap-x-6 gap-y-2 text-sm sm:grid-cols-[auto_1fr]"
    >
      <%= for tip <- @tips do %>
        <dt class="m-0 font-mono text-slate-700 dark:text-slate-200">{tip.term}</dt>
        <dd class="m-0 font-normal text-slate-600 dark:text-slate-400">{tip.desc}</dd>
      <% end %>
    </dl>
    """
  end

  # The operator rows and the scopes each one works in (derived from
  # Vutuv.Search's people/tags/posts guards). `search_tips/1` filters this by
  # the active scope so no tab shows an operator it cannot honor.
  defp operator_tips do
    [
      %{
        term: gettext("first:stefan"),
        desc: gettext("searches first names only (last: for last names)"),
        scopes: [:all, :people]
      },
      %{
        term: "tag:php",
        desc: gettext("people and posts with this tag, combinable: miller tag:php"),
        scopes: [:all, :people, :posts]
      },
      %{
        term: gettext("city:koblenz"),
        desc: gettext("only people with an address in this city"),
        scopes: [:all, :people]
      },
      %{
        term: "status:looking",
        desc: gettext("only people open to offers (status:open) or looking (status:looking)"),
        scopes: [:all, :people]
      },
      %{term: "@stefan", desc: gettext("searches usernames"), scopes: [:all, :people]},
      %{
        term: ~s("#{gettext("miller")}"),
        desc: gettext("in quotes: exact matches only, no similar names"),
        scopes: [:all, :people, :tags, :posts]
      }
    ] ++ fediverse_tips()
  end

  # What the box does with an address from another network — neither of which is
  # a query, and neither of which anybody guesses is offered here. Dropped
  # entirely on an installation that does not federate (an intranet), where both
  # cards are unreachable and the rows would advertise nothing.
  defp fediverse_tips do
    if Fediverse.enabled?() do
      [
        %{
          term: "@name@server",
          desc: gettext("an address on another network: vutuv offers you the follow"),
          scopes: [:all, :people]
        },
        %{
          term: "https://server/@name/12345",
          desc:
            gettext("the address of a post out there: vutuv fetches it so you can answer it here"),
          scopes: [:all, :posts]
        }
      ]
    else
      []
    end
  end

  # The box takes three kinds of thing now, and the third is the one nobody
  # guesses. It is named in the placeholder because that is the help a member
  # reads *before* typing; the tips below are read after, if at all.
  defp search_placeholder do
    if Fediverse.enabled?(),
      do: gettext("Search for people, organizations, tags, posts, or paste a Fediverse address"),
      else: gettext("Search for people, organizations, tags, or posts")
  end

  # One intro sentence describing what the active scope searches. The generic
  # :all copy is the original two-scope sentence; the narrowed scopes name only
  # what they actually cover, so the tips stop over-promising (#887).
  defp tips_intro(:people),
    do: gettext("Search for people by name, email, username, employer or school.")

  defp tips_intro(:organizations),
    do: gettext("Search for organizations by name, city or another name they go by.")

  defp tips_intro(:tags), do: gettext("Search for tags by name.")
  defp tips_intro(:posts), do: gettext("Search for words in public posts.")

  defp tips_intro(_all),
    do:
      gettext(
        "You can search for a name, email, employer, school, organization or tag, or for words in public posts."
      )

  attr(:id, :string, required: true)
  attr(:patch, :string, required: true)
  attr(:active, :boolean, required: true)
  attr(:disabled, :boolean, default: false)
  attr(:title, :string, default: nil)
  slot(:inner_block, required: true)

  # A disabled chip is a static span: with a people operator in the query the
  # scope is pinned, so a link that changes nothing would just look broken
  # (#846).
  defp filter_chip(%{disabled: true} = assigns) do
    ~H"""
    <span
      id={@id}
      aria-disabled="true"
      title={@title}
      class={[filter_chip_class(false), "cursor-not-allowed opacity-40"]}
    >
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp filter_chip(assigns) do
    ~H"""
    <.link
      id={@id}
      patch={@patch}
      class={filter_chip_class(@active)}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr(:address, :string, default: nil)
  attr(:signed_in?, :boolean, default: false)
  attr(:refusal, :atom, default: nil)
  attr(:error, :any, default: nil)

  # The result row for an address on another network. It sits above the vutuv
  # results because it is the *answer* to what was typed, and it renders for a
  # signed-out visitor too — with the sign-in link instead of the follow button,
  # since the request has to be signed by a member's own key.
  defp remote_address_result(%{address: nil} = assigns) do
    ~H""
  end

  defp remote_address_result(assigns) do
    ~H"""
    <.card id="search-remote-address" class="mt-6">
      <.section_title>{gettext("An account on another network")}</.section_title>
      <p class="mt-2 text-sm leading-relaxed text-slate-700 dark:text-slate-300">
        <span class="font-semibold break-all">{@address}</span>
      </p>
      <p class="mt-1 text-sm leading-relaxed text-slate-600 dark:text-slate-400">
        {gettext(
          "That is an address on Mastodon or one of the other networks, so nobody here carries it. You can follow it from vutuv."
        )}
      </p>
      <%!-- Somebody who cannot sign a Follow at all reads why here, rather than
            pressing a button that was never going to work. Same shape as the
            post card below, and the same panel the following page shows. --%>
      <.follow_refusal_panel
        :if={@signed_in? and @refusal}
        id="search-remote-follow-refusal"
        reason={@refusal}
        class="mt-3"
      />

      <p :if={!@signed_in? or is_nil(@refusal)} class="mt-3">
        <%!-- Full width on a phone, like the other card's: it is this card's
              single call to action, and the standard pill is a small target for
              a thumb. --%>
        <.button
          :if={@signed_in?}
          id="search-remote-follow"
          phx-click="follow-remote-address"
          phx-disable-with={gettext("Following…")}
          class="w-full sm:w-auto"
        >
          {gettext("Follow this account")}
        </.button>
        <.link
          :if={!@signed_in?}
          navigate={~p"/login"}
          id="search-remote-login"
          class="text-sm font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
        >
          {gettext("Sign in to follow this account")} ›
        </.link>
      </p>

      <p
        :if={@error}
        id="search-remote-follow-error"
        role="alert"
        class="mt-2 text-sm font-medium text-red-700 dark:text-red-300"
      >
        {refusal_message(@error)}
      </p>
    </.card>
    """
  end

  attr(:url, :string, default: nil)
  attr(:signed_in?, :boolean, default: false)
  attr(:refusal, :atom, default: nil)
  attr(:error, :any, default: nil)

  # The offer for a pasted post address. It sits above the vutuv results for the
  # same reason the address card does — it is the *answer* to what was pasted —
  # and it always ends in one clear next step: the fetch, the sign-in, or the
  # switch that makes the fetch possible. What it never does is fetch by itself:
  # the request is signed in the member's name and metered against their hourly
  # budget, so it waits for their submit or their click.
  defp remote_post_result(%{url: nil} = assigns) do
    ~H""
  end

  defp remote_post_result(assigns) do
    assigns =
      assign(assigns, :refusal_link, assigns.refusal && lookup_refusal_link(assigns.refusal))

    ~H"""
    <.card id="search-remote-post" class="mt-6">
      <.section_title>{gettext("A post on another network")}</.section_title>
      <p class="mt-2 text-sm leading-relaxed text-slate-700 dark:text-slate-300">
        <span class="font-semibold break-all">{@url}</span>
      </p>
      <p class="mt-1 text-sm leading-relaxed text-slate-600 dark:text-slate-400">
        {gettext(
          "That is a link to somewhere else, not something anybody here wrote. vutuv can fetch the post behind it so you can read it, answer it, like it or repost it from here."
        )}
      </p>

      <p :if={@signed_in? and @refusal} class="mt-3 text-sm leading-relaxed text-slate-600 dark:text-slate-400">
        {lookup_refusal_text(@refusal)}
      </p>

      <p class="mt-3">
        <%!-- Full width on a phone, like the lookup page's own submit: it is
        this card's single call to action, and the standard pill is a small
        target for a thumb. --%>
        <.button
          :if={@signed_in? and is_nil(@refusal)}
          id="search-lookup-post"
          phx-click="look-up-post"
          class="w-full sm:w-auto"
        >
          {gettext("Fetch this post")}
        </.button>
        <.link
          :if={@signed_in? and @refusal_link}
          navigate={@refusal_link.path}
          id="search-lookup-refusal-link"
          class="text-sm font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
        >
          {@refusal_link.label} ›
        </.link>
        <.link
          :if={!@signed_in?}
          navigate={~p"/login"}
          id="search-lookup-login"
          class="text-sm font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
        >
          {gettext("Sign in to fetch this post")} ›
        </.link>
      </p>

      <p
        :if={@error}
        id="search-lookup-error"
        role="alert"
        class="mt-2 text-sm font-medium text-red-700 dark:text-red-300"
      >
        {lookup_refusal_message(@error)}
      </p>
    </.card>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- One centered column (classic search page layout): on wide screens a
    left-pinned narrow column leaves the right half of the canvas dead. --%>
    <div id="search" class="mx-auto max-w-2xl py-8">
      <h1 class="text-2xl font-bold text-slate-800 dark:text-slate-100">{gettext("Search")}</h1>

      <form id="search-form" phx-change="search" phx-submit="submit-search" class="mt-4">
        <input
          type="search"
          name="q"
          value={@q}
          placeholder={search_placeholder()}
          autocomplete="off"
          autofocus
          phx-debounce="250"
          class={[input_class(), "text-base"]}
        />
        <%!-- Return in the search box submits, and this button is what keeps
        that true (issue #1895). A browser submits a form with no submit
        control only while it holds exactly ONE text field — so today it works
        by luck, and the day somebody puts an author filter or a date range
        beside the box, Return goes dead with nothing to say so. That is how
        the feed's "Wörter ausblenden" card lost its save (#1888).

        Hidden rather than drawn: the box already searches as you type, so a
        visible "Search" would offer a second way to do what has just
        happened, and the one thing Return does that typing cannot — fetching
        a pasted post from another network — has its own button on the card
        below. Hidden, not `disabled` or `hidden`: it stays in the tab order,
        which is a keyboard path the form did not have at all before. --%>
        <button type="submit" class="sr-only">{gettext("Search")}</button>
      </form>

      <%!-- The chosen organization, said in words and removable in one tap. It
      keeps the text in the box, which from here on means a name at this
      organization. --%>
      <div :if={@org} id="search-org-filter" class="mt-3 flex">
        <span class="inline-flex min-h-10 max-w-full items-center gap-2 rounded-xl bg-brand-50 py-1 pl-1.5 pr-1 text-sm font-semibold text-brand-800 ring-1 ring-brand-200 dark:bg-brand-800/60 dark:text-brand-100 dark:ring-brand-800">
          <.organization_logo organization={@org} class="h-7 w-7 shrink-0" />
          <span class="truncate">{gettext("Only at %{name}", name: @org.name)}</span>
          <.link
            id="search-org-filter-remove"
            patch={search_path(@q, @scope, @exact)}
            aria-label={gettext("Remove the organization filter")}
            class="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg hover:bg-brand-100 dark:hover:bg-brand-800"
          >
            <span aria-hidden="true">×</span>
          </.link>
        </span>
      </div>

      <div id="search-filters" class="mt-3 flex flex-wrap items-center gap-2">
        <.filter_chip
          :for={scope <- [:all, :people, :organizations, :tags, :posts]}
          id={"search-scope-#{scope}"}
          patch={search_path(@q, scope, @exact)}
          active={@effective_scope == scope}
          disabled={@scope_pinned? and scope != :people}
          title={gettext("Not available while the search uses a people filter.")}
        >
          {scope_label(scope)}
        </.filter_chip>

        <span class="mx-1 hidden h-5 w-px bg-slate-200 sm:block dark:bg-slate-700"></span>

        <%!-- Within an organization the box matches names only, so the toggle
        would have nothing to change. --%>
        <.filter_chip
          id="search-exact-toggle"
          patch={search_path(@q, @scope, !@exact, @org)}
          active={@exact}
          disabled={@org != nil}
        >
          <span :if={@exact}>✓ </span>{gettext("Exact matches only")}
        </.filter_chip>
      </div>

      <p
        :if={@scope_pinned? and is_nil(@org)}
        id="search-scope-pinned-hint"
        class="mt-2 text-xs text-slate-600 dark:text-slate-400"
      >
        {gettext("Your search uses a people-only filter such as city: or status:, so it only finds people.")}
      </p>

      <p :if={@org} id="search-org-hint" class="mt-2 text-xs text-slate-600 dark:text-slate-400">
        {gettext("Limited to people at %{name}, so only people are shown.", name: @org.name)}
      </p>

      <p
        :if={@results == nil and is_nil(@org) and String.trim(@q) != ""}
        id="search-hint"
        class="mt-3 text-sm text-slate-600 dark:text-slate-400"
      >
        {gettext("Results appear once you have typed at least three letters.")}
      </p>

      <.remote_address_result
        address={@remote_address}
        signed_in?={@current_user_id != nil}
        refusal={@follow_refusal}
        error={@remote_follow_error}
      />

      <.remote_post_result
        url={@remote_post_url}
        signed_in?={@current_user_id != nil}
        refusal={@lookup_refusal}
        error={@remote_post_error}
      />

      <.card :if={@q == "" and is_nil(@org)} id="search-tips-empty" class="mt-6">
        <.section_title>{gettext("Search Tips")}</.section_title>
        <div class="mt-3">
          <.search_tips scope={@effective_scope} />
        </div>
      </.card>

      <.card :if={@org_people} id="search-org-people" class="mt-6">
        <.section_title>
          {gettext("People at %{name}", name: @org.name)} ({compact_count(@org_people.total)})
        </.section_title>

        <p
          :if={@org_people.total == 0}
          id="search-org-people-empty"
          class="mt-3 mb-0 text-sm text-slate-600 dark:text-slate-400"
        >
          {gettext("Nobody found at %{name}.", name: @org.name)}
        </p>

        <%!-- Current before former, the order the organization page uses. A
        page can hold the tail of one group and the head of the other, so each
        group names itself. --%>
        <div :for={{current?, users} <- @org_people.groups} class="mt-4 first:mt-3">
          <h3
            id={if(current?, do: "search-org-current", else: "search-org-former")}
            class="mb-3 text-xs font-semibold uppercase tracking-wide text-slate-600 dark:text-slate-400"
          >
            {if current?,
              do: gettext("Currently at %{name}", name: @org.name),
              else: gettext("Formerly at %{name}", name: @org.name)}
          </h3>
          <ul class="space-y-4">
            <UserHTML.user_row
              :for={user <- users}
              user={user}
              current_user={@current_user}
              current_user_id={@current_user_id}
              work_info_by_id={@work_info_by_id}
              following_by_id={@following_by_id}
              highlight={if(String.trim(@q) != "", do: String.split(@q))}
            />
          </ul>
        </div>

        <div id="search-pager">
          <.pager
            params={%{"page" => to_string(@org_people.page)}}
            total={@org_people.total}
            per_page={Search.per_page(:people)}
            path={~p"/search"}
            query={@page_query}
          />
        </div>
      </.card>

      <div :if={@results} class="mt-6 space-y-6">
        <%!-- Keep the tips reachable while refining a search (#861), but as a
        collapsed one-line disclosure so they cost almost no real estate. It
        renders the SAME scope-aware body as the empty-state card. --%>
        <details
          id="search-tips-results"
          class="group rounded-2xl bg-white px-4 py-3 shadow-sm ring-1 ring-slate-200 dark:bg-slate-900 dark:ring-slate-800"
        >
          <summary class="flex cursor-pointer list-none items-center gap-2 text-sm font-semibold text-slate-600 [&::-webkit-details-marker]:hidden dark:text-slate-300">
            <svg
              class="h-4 w-4 shrink-0 text-slate-500 transition-transform group-open:rotate-90 dark:text-slate-400"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              viewBox="0 0 24 24"
              aria-hidden="true"
            >
              <path stroke-linecap="round" stroke-linejoin="round" d="m9 5 7 7-7 7" />
            </svg>
            {gettext("Search Tips")}
          </summary>
          <div class="mt-3">
            <.search_tips scope={@effective_scope} />
          </div>
        </details>

        <.save_search_control
          :if={@current_user && @saveable?}
          id="people-save-search"
          show?={@show_save?}
          saved?={@saved?}
        />

        <%!-- People: the name matches, then those found through their CV. "All"
        previews a few and links into the list; the people scope pages. --%>
        <.card :if={@people.total > 0} id="search-people">
          <.section_title>
            {gettext("People")} ({people_total_label(@people)})
          </.section_title>

          <ul :if={@people.shown != []} id="search-people-exact" class="mt-4 space-y-4">
            <UserHTML.user_row
              :for={user <- @people.shown}
              user={user}
              current_user={@current_user}
              current_user_id={@current_user_id}
              work_info_by_id={@work_info_by_id}
              following_by_id={@following_by_id}
              highlight={@people_needles}
            />
          </ul>

          <div
            :if={@people.similar != []}
            id="search-people-similar"
            class={[
              "mt-5",
              @people.shown != [] && "border-t border-slate-100 pt-4 dark:border-slate-800"
            ]}
          >
            <h3 class="text-sm font-semibold text-slate-600 dark:text-slate-400">
              {gettext("Similar names")}
            </h3>
            <p class="mt-0.5 text-xs text-slate-600 dark:text-slate-400">
              {gettext("Not an exact match, but sounds like your search.")}
            </p>
            <ul class="mt-3 space-y-4">
              <UserHTML.user_row
                :for={user <- @people.similar}
                user={user}
                current_user={@current_user}
                current_user_id={@current_user_id}
                work_info_by_id={@work_info_by_id}
                following_by_id={@following_by_id}
              />
            </ul>
          </div>

          <.kind_footer
            kind={:people}
            scope={@effective_scope}
            more?={@people.total > length(@people.shown) + length(@people.similar)}
            label={all_label(:people, @people)}
            patch={search_path(@q, :people, @exact)}
            page={@people.page}
            total={@people.main_total}
            per_page={@people.per_page}
            query={@page_query}
          />

          <%!-- The list ran into its cap, so it is not everybody: say so rather
          than let the last page pass for the end of the matches. --%>
          <p
            :if={@effective_scope == :people and @people.capped?}
            id="search-people-capped"
            class="mt-4 mb-0 text-sm text-slate-600 dark:text-slate-400"
          >
            {gettext("This search matches more people than the list can show. Add a word to narrow it down.")}
          </p>
        </.card>

        <%!-- Organizations: the public pages, as the directory at /organizations
        finds them. "N people" narrows the search to the people each one lists. --%>
        <.card :if={@results.organizations.entries != []} id="search-organizations">
          <.section_title>
            {gettext("Organizations")} ({compact_count(@results.organizations.total)})
          </.section_title>

          <ul class="mt-2 divide-y divide-slate-100 dark:divide-slate-800">
            <.organization_row :for={org <- @results.organizations.entries} organization={org}>
              <.kind_badge kind={org.kind} class="mt-1" />
              <:actions>
                <.link
                  :if={Map.get(@results.organizations.people_counts, org.id, 0) > 0}
                  id={"search-org-people-#{org.slug}"}
                  patch={search_path("", :all, @exact, org)}
                  class="inline-flex min-h-10 shrink-0 items-center rounded-lg px-3 text-sm font-semibold text-brand-700 ring-1 ring-slate-200 hover:bg-brand-50 dark:text-brand-300 dark:ring-slate-700 dark:hover:bg-slate-800"
                >
                  {people_count_label(Map.get(@results.organizations.people_counts, org.id, 0))} ›
                </.link>
              </:actions>
            </.organization_row>
          </ul>

          <.kind_footer
            kind={:organizations}
            scope={@effective_scope}
            more?={@results.organizations.total > length(@results.organizations.entries)}
            label={all_label(:organizations, @results.organizations)}
            patch={search_path(@q, :organizations, @exact)}
            page={@results.organizations.page}
            total={@results.organizations.total}
            per_page={@results.organizations.per_page}
            query={@page_query}
          />
        </.card>

        <.card :if={@results.tags.entries != []} id="search-tags">
          <.section_title>
            {gettext("Tags")} ({compact_count(@results.tags.total)})
          </.section_title>
          <div class="mt-4 flex flex-wrap gap-2">
            <.chip :for={tag <- @results.tags.entries} navigate={~p"/tags/#{tag}"}>
              {highlight(tag.name, @tag_needle)}<span
                :if={Map.get(@results.tags.member_counts, tag.id, 0) > 0}
                class="font-normal"
              > · {compact_count(@results.tags.member_counts[tag.id])}</span>
            </.chip>
          </div>

          <.kind_footer
            kind={:tags}
            scope={@effective_scope}
            more?={@results.tags.total > length(@results.tags.entries)}
            label={all_label(:tags, @results.tags)}
            patch={search_path(@q, :tags, @exact)}
            page={@results.tags.page}
            total={@results.tags.total}
            per_page={@results.tags.per_page}
            query={@page_query}
          />
        </.card>

        <.card :if={@results.posts.entries != []} id="search-posts">
          <.section_title>
            {gettext("Posts")} ({compact_count(@results.posts.total)})
          </.section_title>
          <ul class="mt-4 divide-y divide-slate-100 dark:divide-slate-800">
            <li
              :for={post <- @results.posts.entries}
              class="flex items-start gap-3 py-4 first:pt-0 last:pb-0"
            >
              <%!-- A post is by a member or by an organization (issue #1334):
              an organization wears its logo and has no @handle line beside its
              name, which it may never have claimed. --%>
              <.organization_logo
                :if={Posts.organization_post?(post)}
                organization={post.organization}
                class="h-8 w-8"
              />
              <.avatar
                :if={!Posts.organization_post?(post)}
                user={post.user}
                size="sm"
                shape="circle"
                presence
              />
              <div class="min-w-0">
                <p class="mb-0 text-sm">
                  <.link
                    href={Posts.author_path(post)}
                    class="font-medium text-slate-800 hover:text-brand-700 dark:hover:text-brand-300 dark:text-slate-100"
                  >
                    {UserHelpers.author_name(post)}
                  </.link>
                  <span :if={!Posts.organization_post?(post)} class="text-slate-600 dark:text-slate-400">
                    @{post.user.username}
                  </span>
                  <span class="text-slate-600 dark:text-slate-400">· {post.published_on}</span>
                </p>
                <.link
                  href={Posts.path(post)}
                  class="mt-1 block truncate text-sm text-slate-700 hover:text-brand-700 dark:hover:text-brand-300 dark:text-slate-300"
                >
                  {highlight(PostTeaser.line(post), @post_needles)}
                </.link>
              </div>
            </li>
          </ul>

          <.kind_footer
            kind={:posts}
            scope={@effective_scope}
            more?={@results.posts.total > length(@results.posts.entries)}
            label={all_label(:posts, @results.posts)}
            patch={search_path(@q, :posts, @exact)}
            page={@results.posts.page}
            total={@results.posts.total}
            per_page={@results.posts.per_page}
            query={@page_query}
          />
        </.card>

        <.card :if={
          @people.total == 0 and @results.organizations.entries == [] and
            @results.tags.entries == [] and @results.posts.entries == []
        }>
          <p id="search-empty" class="mb-0 text-center font-semibold text-slate-600 dark:text-slate-400">
            {gettext("No results for \"%{query}\"", query: @results.query)}
          </p>
        </.card>
      </div>
    </div>
    """
  end
end
