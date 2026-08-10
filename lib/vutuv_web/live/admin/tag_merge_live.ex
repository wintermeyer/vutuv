defmodule VutuvWeb.Admin.TagMergeLive do
  @moduledoc """
  The tag merge screen (`/admin/tag_merges`, issue #1338): fold several tags for
  one topic into one page.

  **The screen collects a set, not a pair.** A topic is spread over `rails`,
  `rubyonrails`, `Ruby on Rails` and `ROR`, and gathering those takes several
  searches: "rails" cannot turn up `ROR`, and it does turn up `grails`, which is
  a different topic. So a search **adds** to a list, every entry can be taken
  back out with one click, and only then is one of them picked to survive. Its
  first shape asked for one tag to absorb and one to keep, which made the
  reviewer restart the whole thing whenever a search brought back the wrong
  neighbour.

  Once the list stands, the screen says what the merge would move **before**
  anything happens: how many profiles, posts, follows and job postings change
  hands, and how many rows are dropped because their owner already carries the
  surviving tag. Those counts are the ones the sequence really produces
  (`Merge.preview_many/2`), not the sum of the pairs. That preview is the point
  of the page: absorbing a tag moves rows people put there deliberately.

  Each absorbed tag becomes its own recorded merge, so one of them can be taken
  back without undoing the rest, and a tag the merge refuses is named with its
  reason instead of being quietly skipped.

  Everything here is reversible. The merge history below the form lists what was
  done, by whom, and offers "Revert" on each entry, which puts every row back
  where it was, restores the rows that had to go, and unfiles the alias.

  Two smaller tools share the screen because they are the same subject: filing a
  name as an alternative *before* anyone types it (so `ROR` never becomes a page
  of its own), and marking a pair as deliberately distinct, which refuses the
  merge and keeps an assisted pass from proposing it again.

  Lives in the `:admin` live_session (`on_mount :require_admin`, see the router)
  so the dead `:admin` pipeline 403s the disconnected render and the on_mount
  guards the socket.
  """

  use VutuvWeb, :live_view

  alias Vutuv.Repo
  alias Vutuv.Tags
  alias Vutuv.Tags.Assistant
  alias Vutuv.Tags.Merge
  alias Vutuv.Tags.Tag

  # Enough to recognise the tag you meant; an admin who sees too many narrows
  # the query rather than scrolling a picker.
  @results_limit 12

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Merge tags"))
     # The tags collected so far, and which of them survives. A topic is spread
     # over a *set* of spellings, so the screen collects a set.
     |> assign(:basket, [])
     |> assign(:keeper_id, nil)
     |> assign(:query, "")
     |> assign(:results, [])
     |> assign(:alias_name, "")
     |> load_preview()
     |> load_history()
     |> load_queue()}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(:query, q) |> assign(:results, search(q, socket.assigns.basket))}
  end

  # Collecting the spellings of one topic takes several searches — "rails" can
  # never turn up "ROR" — so a result is **added** to the list rather than
  # replacing a slot.
  def handle_event("add", %{"id" => id}, socket) do
    case Repo.get(Tag, id) do
      nil ->
        {:noreply, socket}

      tag ->
        basket = socket.assigns.basket ++ [tag]

        {:noreply,
         socket
         |> assign(:basket, basket)
         |> assign(:keeper_id, socket.assigns.keeper_id || tag.id)
         |> assign(:results, search(socket.assigns.query, basket))
         |> load_preview()}
    end
  end

  # A search for "rails" also finds "grails", which is a different topic. Taking
  # one back out has to be as easy as putting it in, or the reviewer starts the
  # whole list again.
  def handle_event("remove", %{"id" => id}, socket) do
    basket = Enum.reject(socket.assigns.basket, &(&1.id == id))

    {:noreply,
     socket
     |> assign(:basket, basket)
     |> assign(:keeper_id, keeper_after_removal(socket.assigns.keeper_id, id, basket))
     |> assign(:results, search(socket.assigns.query, basket))
     |> load_preview()}
  end

  def handle_event("clear-basket", _params, socket) do
    {:noreply,
     socket
     |> assign(:basket, [])
     |> assign(:keeper_id, nil)
     |> assign(:results, search(socket.assigns.query, []))
     |> load_preview()}
  end

  # Which of the collected spellings survives is the decision this screen is
  # for, and it is made after seeing them all side by side with their counts.
  def handle_event("keep", %{"id" => id}, socket) do
    {:noreply, socket |> assign(:keeper_id, id) |> load_preview()}
  end

  def handle_event("merge", _params, socket) do
    %{keeper: keeper, absorbed: absorbed} = split_basket(socket.assigns)

    result = Merge.merge_all(absorbed, keeper, actor: socket.assigns.current_user)
    Enum.each(result.merged, &Assistant.drop_pair(Repo.get(Tag, &1.absorbed_tag_id), keeper))

    socket =
      Enum.reduce(result.failed, socket, fn {tag, reason}, acc ->
        put_flash(acc, :error, "#{tag.name}: #{refusal(reason)}")
      end)

    {:noreply,
     socket
     |> put_flash(
       :info,
       ngettext(
         "%{count} tag is now an alternative name for %{canonical}.",
         "%{count} tags are now alternative names for %{canonical}.",
         length(result.merged),
         canonical: keeper.name
       )
     )
     |> assign(:basket, [Repo.get(Tag, keeper.id)])
     |> assign(:keeper_id, keeper.id)
     |> load_preview()
     |> load_history()
     |> load_queue()}
  end

  # Only meaningful for exactly two: "these are different topics" is a statement
  # about a pair, and a list of five would mean ten of them.
  def handle_event("mark-distinct", _params, socket) do
    [a, b] = socket.assigns.basket
    {:ok, _} = Merge.mark_distinct(a, b, actor: socket.assigns.current_user)
    Assistant.drop_pair(a, b)

    {:noreply,
     socket
     |> put_flash(
       :info,
       gettext("%{a} and %{b} are recorded as different topics.", a: a.name, b: b.name)
     )
     |> assign(:basket, [])
     |> assign(:keeper_id, nil)
     |> load_preview()
     |> load_queue()}
  end

  def handle_event("revert", %{"id" => id}, socket) do
    case Merge.get_merge(id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("That merge is no longer on record."))}

      merge ->
        case Merge.revert(merge) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("The merge was reverted."))
             |> reload_basket()
             |> load_preview()
             |> load_history()}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, refusal(reason))}
        end
    end
  end

  # The assisted pass (issue #1338): generate proposals, judge them with the
  # local model where it is available, and put them in the queue below. Never a
  # runtime path — it happens because an admin asked for it.
  def handle_event("scan", _params, socket) do
    report = Assistant.scan()

    {:noreply,
     socket
     |> put_flash(
       :info,
       gettext(
         "%{written} proposals, %{judged} of them judged by the model. %{dropped} more were found than the queue holds.",
         written: report.written,
         judged: report.judged,
         dropped: report.dropped
       )
     )
     |> load_queue()}
  end

  # Approving a proposal is the ordinary merge, so it goes through the same
  # review: the pair lands in the list above, where it can be corrected, added
  # to and previewed. A one-click merge from a queue row is exactly the
  # unreviewed merge this feature exists to avoid.
  def handle_event("review", %{"id" => id}, socket) do
    case Assistant.get_candidate(id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("That proposal is gone."))}

      candidate ->
        {absorbed, canonical} = sides(candidate)

        {:noreply,
         socket
         |> assign(:basket, [canonical, absorbed])
         |> assign(:keeper_id, canonical.id)
         |> load_preview()}
    end
  end

  def handle_event("reject", %{"id" => id}, socket) do
    case Assistant.get_candidate(id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("That proposal is gone."))}

      candidate ->
        {:ok, _} =
          Merge.mark_distinct(candidate.tag_a, candidate.tag_b,
            actor: socket.assigns.current_user
          )

        {:ok, _} = Assistant.drop(candidate)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Recorded as different topics."))
         |> load_queue()}
    end
  end

  def handle_event("alias-name", %{"name" => name}, socket) do
    {:noreply, assign(socket, :alias_name, name)}
  end

  def handle_event("add-alias", %{"name" => name}, socket) do
    case Merge.add_alias(socket.assigns.keeper, name) do
      {:ok, _tag} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Added %{name} as an alternative name.", name: name))
         |> assign(:alias_name, "")
         |> load_preview()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, changeset_message(changeset))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, refusal(reason))}
    end
  end

  def handle_event("remove-alias", %{"id" => id}, socket) do
    case id |> then(&Repo.get(Tag, &1)) |> Merge.remove_alias() do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, gettext("Removed.")) |> load_preview()}
      {:error, reason} -> {:noreply, put_flash(socket, :error, refusal(reason))}
    end
  end

  # Each result carries the number of profiles carrying it, batched into one
  # query for the whole list: with three spellings of one topic on screen, that
  # number is usually what decides which of them should survive. Anything
  # already collected drops out, so the list only ever offers something new.
  defp search(query, basket) do
    case String.trim(to_string(query)) do
      "" ->
        []

      q ->
        collected = MapSet.new(basket, & &1.id)

        tags =
          q
          |> Tags.admin_search(limit: @results_limit)
          |> Repo.all()
          |> Enum.reject(&MapSet.member?(collected, &1.id))

        counts = Tags.member_counts(Enum.map(tags, & &1.id))

        Enum.map(tags, &%{tag: &1, members: Map.get(counts, &1.id, 0)})
    end
  end

  # A merge or a revert changes the rows the list is showing, so it is re-read
  # rather than left holding what the tags looked like before.
  defp reload_basket(socket) do
    basket = socket.assigns.basket |> Enum.map(&Repo.get(Tag, &1.id)) |> Enum.reject(&is_nil/1)
    assign(socket, :basket, basket)
  end

  # The collected tags split into the one that survives and the ones absorbed.
  defp split_basket(%{basket: basket, keeper_id: keeper_id}) do
    keeper = Enum.find(basket, &(&1.id == keeper_id))
    %{keeper: keeper, absorbed: Enum.reject(basket, &(&1.id == keeper_id))}
  end

  # Removing the tag that was set to survive must not leave the list without a
  # keeper: the next one takes over rather than the screen going blank.
  defp keeper_after_removal(keeper_id, keeper_id, [next | _]), do: next.id
  defp keeper_after_removal(keeper_id, keeper_id, []), do: nil
  defp keeper_after_removal(keeper_id, _removed_id, _basket), do: keeper_id

  # The preview is recomputed on every pick, so what the screen shows is always
  # the answer for the pair currently named — including the refusal, which is
  # shown in place of the button rather than only after pressing it.
  defp load_preview(socket) do
    %{keeper: keeper, absorbed: absorbed} = split_basket(socket.assigns)

    preview = keeper && absorbed != [] && Merge.preview_many(absorbed, keeper)

    socket
    |> assign(:keeper, keeper)
    |> assign(:preview, preview || nil)
    |> assign(:aliases, keeper && Tag.aliases_of(keeper))
    |> assign(:members, Tags.member_counts(Enum.map(socket.assigns.basket, & &1.id)))
  end

  defp load_history(socket), do: assign(socket, :history, Merge.history())

  defp load_queue(socket) do
    socket
    |> assign(:queue, Assistant.queue())
    |> assign(:queue_size, Assistant.queue_size())
  end

  # Which of a proposal's two tags is absorbed: the model's suggestion decides
  # when there is one, otherwise the pair is handed over as it stands and the
  # admin picks. Never guessed from the counts — "the smaller one loses" is a
  # judgement, and this screen's whole point is that a human makes it.
  defp sides(candidate) do
    case candidate.suggested_canonical_id do
      nil -> {candidate.tag_a, candidate.tag_b}
      id when id == candidate.tag_a.id -> {candidate.tag_b, candidate.tag_a}
      _ -> {candidate.tag_a, candidate.tag_b}
    end
  end

  # Why a merge is refused, in the reviewer's words rather than the code's.
  defp refusal(:same_tag), do: gettext("A tag cannot absorb itself.")

  defp refusal(:honor_tag),
    do: gettext("Honor tags are granted, not spelled. They are never merged.")

  defp refusal(:already_merged),
    do: gettext("That tag is already an alternative name. Revert its merge first.")

  defp refusal(:target_is_alias),
    do: gettext("The surviving tag is itself an alternative name. Pick its topic instead.")

  defp refusal(:marked_distinct),
    do: gettext("These two are recorded as different topics.")

  defp refusal(:punctuation_only_difference),
    do:
      gettext(
        "These names differ only in characters the slug drops (like + or #), which is how C, C++ and C# tell each other apart. They are not merged."
      )

  defp refusal(:name_taken),
    do: gettext("That name is already a tag. Merge it instead, so its entries come along.")

  defp refusal(:from_merge),
    do: gettext("This name came from a merge. Revert that merge to take it back.")

  defp refusal(:not_an_alias), do: gettext("That tag is not an alternative name.")
  defp refusal(:already_reverted), do: gettext("That merge was already reverted.")
  defp refusal(_other), do: gettext("That did not work.")

  defp changeset_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.map_join(" ", fn {field, messages} -> "#{field}: #{Enum.join(messages, ", ")}" end)
  end

  defp total(nil), do: 0
  defp total(counts), do: counts |> Map.values() |> Enum.sum()

  # "N profiles", the one phrase the picker rows and the worked example share —
  # so the example is written in the same words the real rows use, and the
  # number goes through the formatter like every other count in the app
  # (`ngettext` binds %{count} to the raw integer, hence the second placeholder).
  defp profile_count(members) do
    ngettext("%{formatted} profile", "%{formatted} profiles", members,
      formatted: delimited_count(members)
    )
  end

  # Which rule found a pair, for the rows the model has not judged (or could
  # not): the reviewer should know whether they are looking at two spellings of
  # one string or at two names that merely share a word.
  defp generator_label("same_key"), do: gettext("the same name, written differently")
  defp generator_label("acronym"), do: gettext("one is the other's initials")
  defp generator_label("token"), do: gettext("one is a word of the other")
  defp generator_label(other), do: other

  # The tables named in a preview, in the words an admin thinks in.
  defp row_label("user_tags"), do: gettext("profiles carrying the tag")
  defp row_label("post_tags"), do: gettext("posts filed under it")
  defp row_label("post_hashtags"), do: gettext("hashtags in post bodies")
  defp row_label("tag_follows"), do: gettext("members following it")
  defp row_label("job_posting_tags"), do: gettext("job postings")
  defp row_label("fediverse_post_tags"), do: gettext("posts from other networks")
  defp row_label("newsletter_groups"), do: gettext("newsletter audiences")
  defp row_label(other), do: other

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header
      title={gettext("Merge tags")}
      crumbs={[
        {gettext("Admin"), ~p"/admin"},
        {gettext("Tags"), ~p"/admin/tags"},
        gettext("Merge tags")
      ]}
    />

    <div class="card-list">
      <section class="card">
        <h1>{gettext("Merge tags")}</h1>
        <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">
          {gettext(
            "One topic sometimes ends up under several tags, so its members and its posts are split over two pages that never show each other. Merging puts them on one page."
          )}
        </p>

        <%!-- What a merge does, on a real pair. An abstract description of this
        left the reader guessing which of the two names disappears, which is the
        one thing the screen has to make obvious. --%>
        <div
          id="merge-example"
          class="mt-4 rounded-lg bg-slate-50 p-4 text-sm dark:bg-slate-800/60"
        >
          <h2 class="card__label">{gettext("An example")}</h2>
          <div class="grid gap-4 sm:grid-cols-2">
            <div>
              <p class="mb-1 font-semibold">{gettext("Today")}</p>
              <ul class="space-y-1 text-slate-600 dark:text-slate-400">
                <li><code>/tags/ruby_on_rails</code> · {profile_count(89)}</li>
                <li><code>/tags/rubyonrails</code> · {profile_count(12)}</li>
              </ul>
            </div>
            <div>
              <p class="mb-1 font-semibold">{gettext("After the merge")}</p>
              <ul class="space-y-1 text-slate-600 dark:text-slate-400">
                <li><code>/tags/ruby_on_rails</code> · {profile_count(101)}</li>
                <li>
                  <code>/tags/rubyonrails</code> {gettext("redirects there for good")}
                </li>
              </ul>
            </div>
          </div>
          <p class="mt-3 text-slate-600 dark:text-slate-400">
            {gettext(
              "\"rubyonrails\" was absorbed: nobody loses a tag, the name goes on working, and it is listed on the remaining page as an alternative name. Anyone typing it from now on gets the one page. Every merge can be undone at the bottom of this page."
            )}
          </p>
        </div>

        <div class="mt-6 grid gap-6 md:grid-cols-2">
          <%!-- Collecting the spellings of a topic takes several searches: a
          search for "rails" can never turn up "ROR", and it does turn up
          "grails", which is a different topic. So the search adds to a list
          rather than filling one of two slots. --%>
          <div>
            <h2 class="card__label">
              <span class="mr-1 text-slate-400 dark:text-slate-500">1.</span>{gettext(
                "Collect the tags that mean one topic"
              )}
            </h2>
            <p class="text-sm text-slate-600 dark:text-slate-400">
              {gettext(
                "Search as often as you like and add what belongs. Abbreviations will not turn up under the full name, so look for them separately."
              )}
            </p>

            <form id="tag-search" phx-change="search" phx-submit="search" class="mt-2">
              <input
                type="text"
                id="q"
                name="q"
                value={@query}
                autocomplete="off"
                placeholder={gettext("Search by name or slug")}
              />
            </form>

            <p :if={@query != "" and @results == []} class="card__empty">
              {gettext("No tag matches that.")}
            </p>

            <ul :if={@results != []} class="mt-2 space-y-1">
              <li :for={result <- @results}>
                <button
                  type="button"
                  id={"add-#{result.tag.id}"}
                  class="w-full rounded-lg px-3 py-2 text-left hover:bg-brand-50 dark:hover:bg-brand-900/40"
                  phx-click="add"
                  phx-value-id={result.tag.id}
                >
                  <span class="block font-semibold text-brand-700 dark:text-brand-200">
                    + {result.tag.name}
                  </span>
                  <span class="block text-xs text-slate-600 dark:text-slate-400">
                    /tags/{result.tag.slug} · {profile_count(result.members)}
                  </span>
                </button>
              </li>
            </ul>
          </div>

          <div>
            <h2 class="card__label">
              <span class="mr-1 text-slate-400 dark:text-slate-500">2.</span>{gettext(
                "Pick the one that stays"
              )}
            </h2>
            <p class="text-sm text-slate-600 dark:text-slate-400">
              {gettext(
                "It keeps its page and its address; every other one becomes an alternative name pointing at it."
              )}
            </p>

            <p :if={@basket == []} class="card__empty">
              {gettext("Nothing collected yet.")}
            </p>

            <ul :if={@basket != []} id="basket" class="mt-2 space-y-1">
              <li
                :for={tag <- @basket}
                id={"basket-#{tag.id}"}
                class={[
                  "flex items-start gap-3 rounded-lg px-3 py-2",
                  tag.id == @keeper_id && "bg-brand-50 dark:bg-brand-900/40"
                ]}
              >
                <label class="flex min-w-0 grow cursor-pointer items-start gap-3">
                  <input
                    type="radio"
                    name="keeper"
                    checked={tag.id == @keeper_id}
                    phx-click="keep"
                    phx-value-id={tag.id}
                    class={checkbox_class()}
                  />
                  <span class="min-w-0">
                    <span class="block font-semibold">{tag.name}</span>
                    <span class="block text-xs text-slate-600 dark:text-slate-400">
                      /tags/{tag.slug} · {profile_count(Map.get(@members, tag.id, 0))}
                    </span>
                  </span>
                </label>
                <button
                  type="button"
                  id={"remove-#{tag.id}"}
                  class="button button--cancel button--small"
                  phx-click="remove"
                  phx-value-id={tag.id}
                  title={gettext("Does not belong here")}
                >
                  ✕
                </button>
              </li>
            </ul>

            <div :if={@basket != []} class="editform__actions mt-3">
              <button
                id="clear-basket"
                type="button"
                class="button button--cancel"
                phx-click="clear-basket"
              >
                {gettext("Start over")}
              </button>
            </div>
          </div>
        </div>
      </section>

      <section :if={@preview} class="card" id="merge-preview">
        <h2 class="card__label">{gettext("What this merge would move")}</h2>

        <%!-- The table answers "how much"; this line answers "what am I about
        to do", which is the question somebody presses the button with. --%>
        <p :if={@preview.mergeable != []} id="merge-sentence" class="text-sm">
          {ngettext(
            "%{names} becomes an alternative name for %{canonical} and %{urls} redirects to /tags/%{slug}.",
            "%{names} become alternative names for %{canonical}, and their addresses redirect to /tags/%{slug}.",
            length(@preview.mergeable),
            names: Enum.map_join(@preview.mergeable, ", ", & &1.name),
            canonical: @preview.canonical.name,
            urls: Enum.map_join(@preview.mergeable, ", ", &("/tags/" <> &1.slug)),
            slug: @preview.canonical.slug
          )}
        </p>

        <%!-- A tag the merge refuses is named with its reason rather than
        quietly left out: the reviewer put it in the list on purpose. --%>
        <ul :if={@preview.refused != []} id="refused" class="mt-3 space-y-1">
          <li :for={{tag, reason} <- @preview.refused} class="alert alert-danger" role="alert">
            <strong>{tag.name}:</strong> {refusal(reason)}
          </li>
        </ul>

        <div :if={@preview.mergeable != []} class="card__tablewrap mt-3">
          <table class="pure-table">
            <thead>
              <tr>
                <th>{gettext("What")}</th>
                <th>{gettext("Moves")}</th>
                <th>{gettext("Dropped as duplicate")}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={{table, _} <- Map.merge(@preview.moved, @preview.dropped)}>
                <td>{row_label(table)}</td>
                <td>{delimited_count(Map.get(@preview.moved, table, 0))}</td>
                <td>{delimited_count(Map.get(@preview.dropped, table, 0))}</td>
              </tr>
              <tr :if={total(@preview.moved) == 0 and total(@preview.dropped) == 0}>
                <td colspan="3">{gettext("Nothing is filed under these tags.")}</td>
              </tr>
            </tbody>
          </table>
        </div>

        <p
          :if={total(@preview.dropped) > 0}
          class="mt-3 text-sm text-slate-600 dark:text-slate-400"
        >
          {gettext(
            "A dropped row belongs to somebody who already carries the surviving tag, so they end up carrying the topic once. Endorsements move to the row that stays."
          )}
        </p>

        <div class="editform__actions mt-4">
          <button
            :if={@preview.mergeable != []}
            id="do-merge"
            type="button"
            class="button"
            phx-click="merge"
          >
            {ngettext(
              "Merge %{count} tag into %{canonical}",
              "Merge %{count} tags into %{canonical}",
              length(@preview.mergeable),
              canonical: @preview.canonical.name
            )}
          </button>
          <%!-- Only for a pair: "these are different topics" is a statement
          about two names, and a list of five would mean ten of them. --%>
          <button
            :if={length(@basket) == 2}
            id="mark-distinct"
            type="button"
            class="button button--cancel"
            phx-click="mark-distinct"
          >
            {gettext("These are different topics")}
          </button>
        </div>
      </section>

      <section :if={@keeper} class="card" id="alias-editor">
        <h2 class="card__label">
          {gettext("Alternative names for %{tag}", tag: @keeper.name)}
        </h2>

        <ul :if={@aliases != []} class="thumbs">
          <li :for={tag_alias <- @aliases} id={"alias-#{tag_alias.id}"}>
            <span>{tag_alias.name}</span>
            <button
              type="button"
              class="button button--cancel button--small"
              phx-click="remove-alias"
              phx-value-id={tag_alias.id}
              data-confirm={gettext("Are you sure?")}
            >
              {gettext("Remove")}
            </button>
          </li>
        </ul>

        <p :if={@aliases == []} class="card__empty">{gettext("Nothing here yet.")}</p>

        <form id="add-alias" phx-submit="add-alias" phx-change="alias-name" class="editform mt-4">
          <div class="editform__field">
            <label for="alias-name">{gettext("Add an alternative name")}</label>
            <input type="text" id="alias-name" name="name" value={@alias_name} />
            <p class="editform__hint">
              {gettext(
                "For a name nobody has typed yet, so it never becomes a page of its own. A name that is already a tag has to be merged instead."
              )}
            </p>
          </div>
          <div class="editform__actions">
            <button type="submit" class="button">{gettext("Add")}</button>
          </div>
        </form>
      </section>

      <%!-- The assisted pass: proposals a human approves, never applies
      anything itself (issue #1338). --%>
      <section class="card" id="candidate-queue">
        <h2 class="card__label">{gettext("Proposals")}</h2>
        <p class="text-sm text-slate-600 dark:text-slate-400">
          {gettext(
            "Pairs of tags that might be one topic, found by rule and, where a local model is available, judged by it. Nothing here has happened yet: opening one loads it above, where you see what a merge would move before confirming."
          )}
        </p>

        <div class="editform__actions mt-3">
          <button id="scan-candidates" type="button" class="button" phx-click="scan">
            {gettext("Look for proposals")}
          </button>
          <span :if={not Assistant.enabled?()} class="text-sm text-slate-600 dark:text-slate-400">
            {gettext("The model is switched off; proposals are listed unjudged.")}
          </span>
        </div>

        <p :if={@queue == []} class="card__empty">{gettext("Nothing here yet.")}</p>

        <div :if={@queue != []} class="card__tablewrap">
          <table class="pure-table">
            <thead>
              <tr>
                <th>{gettext("Pair")}</th>
                <th>{gettext("Profiles")}</th>
                <th>{gettext("Why")}</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={candidate <- @queue} id={"candidate-#{candidate.id}"}>
                <td>
                  {candidate.tag_a.name} · {candidate.tag_b.name}
                </td>
                <td>{delimited_count(candidate.members_affected)}</td>
                <td>
                  <span :if={candidate.reason}>{candidate.reason}</span>
                  <span :if={is_nil(candidate.reason)} class="text-slate-600 dark:text-slate-400">
                    {generator_label(candidate.generator)}
                  </span>
                </td>
                <td class="text-right">
                  <button
                    type="button"
                    class="button button--small"
                    phx-click="review"
                    phx-value-id={candidate.id}
                  >
                    {gettext("Review")}
                  </button>
                  <button
                    type="button"
                    class="button button--cancel button--small"
                    phx-click="reject"
                    phx-value-id={candidate.id}
                  >
                    {gettext("Different topics")}
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section class="card" id="merge-history">
        <h2 class="card__label">{gettext("Merges so far")}</h2>

        <p :if={@history == []} class="card__empty">{gettext("Nothing here yet.")}</p>

        <div :if={@history != []} class="card__tablewrap">
          <table class="pure-table">
            <thead>
              <tr>
                <th>{gettext("Absorbed")}</th>
                <th>{gettext("Into")}</th>
                <th>{gettext("Rows")}</th>
                <th>{gettext("When")}</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={merge <- @history} id={"merge-#{merge.id}"}>
                <td>{merge.absorbed_tag && merge.absorbed_tag.name}</td>
                <td>
                  <.link
                    :if={merge.canonical_tag}
                    navigate={~p"/tags/#{merge.canonical_tag}"}
                    class="text-sm font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
                  >
                    {merge.canonical_tag.name}
                  </.link>
                </td>
                <td>{delimited_count(total(merge.moved_counts))}</td>
                <td><.local_time at={merge.inserted_at} id={"merge-time-#{merge.id}"} /></td>
                <td class="text-right">
                  <span :if={merge.reverted_at} class="text-sm text-slate-600 dark:text-slate-400">
                    {gettext("Reverted")}
                  </span>
                  <button
                    :if={is_nil(merge.reverted_at)}
                    type="button"
                    class="button button--cancel button--small"
                    phx-click="revert"
                    phx-value-id={merge.id}
                    data-confirm={gettext("Are you sure?")}
                  >
                    {gettext("Revert")}
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
end
