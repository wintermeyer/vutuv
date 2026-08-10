defmodule VutuvWeb.Admin.TagMergeLive do
  @moduledoc """
  The tag merge screen (`/admin/tags/merge`, issue #1338): fold several tags for
  one topic into one page.

  Pick the tag to absorb and the tag that survives, and the screen says what the
  merge would move **before** anything happens — how many profiles, posts,
  follows and job postings change hands, and how many rows would be dropped
  because their owner already carries both spellings. That preview is the point
  of the page: absorbing a tag moves rows people put there deliberately.

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
     |> assign(:absorbed, nil)
     |> assign(:canonical, nil)
     |> assign(:absorbed_query, "")
     |> assign(:canonical_query, "")
     |> assign(:absorbed_results, [])
     |> assign(:canonical_results, [])
     |> assign(:alias_name, "")
     |> assign(:scanning?, false)
     |> load_preview()
     |> load_history()
     |> load_queue()}
  end

  @impl true
  def handle_event("search", %{"side" => side, "q" => q}, socket) do
    {:noreply,
     socket
     |> assign(:"#{side}_query", q)
     |> assign(:"#{side}_results", search(q))}
  end

  def handle_event("pick", %{"side" => side, "id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:"#{side}", Repo.get(Tag, id))
     |> assign(:"#{side}_results", [])
     |> assign(:"#{side}_query", "")
     |> load_preview()}
  end

  def handle_event("clear", %{"side" => side}, socket) do
    {:noreply, socket |> assign(:"#{side}", nil) |> load_preview()}
  end

  def handle_event("merge", _params, socket) do
    %{absorbed: absorbed, canonical: canonical} = socket.assigns

    case Merge.merge(absorbed, canonical, actor: socket.assigns.current_user) do
      {:ok, _merge} ->
        # Decided, so it leaves the proposal queue whether it came from there
        # or was picked by hand.
        Assistant.drop_pair(absorbed, canonical)

        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("%{absorbed} is now an alternative name for %{canonical}.",
             absorbed: absorbed.name,
             canonical: canonical.name
           )
         )
         |> assign(:absorbed, nil)
         |> assign(:canonical, Repo.get(Tag, canonical.id))
         |> load_preview()
         |> load_history()
         |> load_queue()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, refusal(reason))}
    end
  end

  def handle_event("mark-distinct", _params, socket) do
    %{absorbed: absorbed, canonical: canonical} = socket.assigns
    {:ok, _} = Merge.mark_distinct(absorbed, canonical, actor: socket.assigns.current_user)
    Assistant.drop_pair(absorbed, canonical)

    {:noreply,
     socket
     |> put_flash(
       :info,
       gettext("%{a} and %{b} are recorded as different topics.",
         a: absorbed.name,
         b: canonical.name
       )
     )
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
             |> assign(
               :canonical,
               socket.assigns.canonical && Repo.get(Tag, socket.assigns.canonical.id)
             )
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
  # preview: the pair is loaded into the pickers instead of being merged on the
  # spot. A one-click merge from a queue row is exactly the unreviewed merge
  # this feature exists to avoid.
  def handle_event("review", %{"id" => id}, socket) do
    case Assistant.get_candidate(id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("That proposal is gone."))}

      candidate ->
        {absorbed, canonical} = sides(candidate)

        {:noreply,
         socket
         |> assign(:absorbed, absorbed)
         |> assign(:canonical, canonical)
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
    case Merge.add_alias(socket.assigns.canonical, name) do
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

  defp search(query) do
    case String.trim(to_string(query)) do
      "" -> []
      q -> q |> Tags.admin_search(limit: @results_limit) |> Repo.all()
    end
  end

  # The preview is recomputed on every pick, so what the screen shows is always
  # the answer for the pair currently named — including the refusal, which is
  # shown in place of the button rather than only after pressing it.
  defp load_preview(socket) do
    %{absorbed: absorbed, canonical: canonical} = socket.assigns

    preview =
      case {absorbed, canonical} do
        {%Tag{}, %Tag{}} -> Merge.preview(absorbed, canonical)
        _ -> nil
      end

    assign(socket, :preview, preview)
    |> assign(:aliases, canonical && Tag.aliases_of(canonical))
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
            "One topic sometimes ends up under several tags. Pick the tag to absorb and the tag that stays: everything filed under the first moves to the second, and the absorbed name becomes an alternative name that keeps pointing there. Every merge can be reverted below."
          )}
        </p>

        <div class="mt-6 grid gap-6 md:grid-cols-2">
          <.tag_picker
            side="absorbed"
            id="absorbed"
            label={gettext("Tag to absorb")}
            hint={gettext("Its entries move away and its page redirects.")}
            tag={@absorbed}
            query={@absorbed_query}
            results={@absorbed_results}
          />
          <.tag_picker
            side="canonical"
            id="canonical"
            label={gettext("Tag that stays")}
            hint={gettext("The topic's one page from now on.")}
            tag={@canonical}
            query={@canonical_query}
            results={@canonical_results}
          />
        </div>
      </section>

      <section :if={@preview} class="card" id="merge-preview">
        <h2 class="card__label">{gettext("What this merge would move")}</h2>

        <%= case @preview do %>
          <% {:error, reason} -> %>
            <p class="alert alert-danger" role="alert">{refusal(reason)}</p>
          <% preview -> %>
            <div class="card__tablewrap">
              <table class="pure-table">
                <thead>
                  <tr>
                    <th>{gettext("What")}</th>
                    <th>{gettext("Moves")}</th>
                    <th>{gettext("Dropped as duplicate")}</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={{table, _} <- Map.merge(preview.moved, preview.dropped)}>
                    <td>{row_label(table)}</td>
                    <td>{delimited_count(Map.get(preview.moved, table, 0))}</td>
                    <td>{delimited_count(Map.get(preview.dropped, table, 0))}</td>
                  </tr>
                  <tr :if={total(preview.moved) == 0 and total(preview.dropped) == 0}>
                    <td colspan="3">{gettext("Nothing is filed under this tag.")}</td>
                  </tr>
                </tbody>
              </table>
            </div>

            <p :if={total(preview.dropped) > 0} class="mt-3 text-sm text-slate-600 dark:text-slate-400">
              {gettext(
                "A dropped row belongs to somebody who already carries the surviving tag, so they end up carrying the topic once. Endorsements move to the row that stays."
              )}
            </p>

            <div class="editform__actions mt-4">
              <button id="do-merge" type="button" class="button" phx-click="merge">
                {gettext("Merge")}
              </button>
              <button
                id="mark-distinct"
                type="button"
                class="button button--cancel"
                phx-click="mark-distinct"
              >
                {gettext("These are different topics")}
              </button>
            </div>
        <% end %>
      </section>

      <section :if={@canonical} class="card" id="alias-editor">
        <h2 class="card__label">
          {gettext("Alternative names for %{tag}", tag: @canonical.name)}
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

  attr(:side, :string, required: true)
  attr(:id, :string, required: true)
  attr(:label, :string, required: true)
  attr(:hint, :string, required: true)
  attr(:tag, :any, default: nil)
  attr(:query, :string, default: "")
  attr(:results, :list, default: [])

  defp tag_picker(assigns) do
    ~H"""
    <div>
      <h2 class="card__label">{@label}</h2>
      <p class="text-sm text-slate-600 dark:text-slate-400">{@hint}</p>

      <div :if={@tag} class="mt-2 flex items-center gap-3" id={"picked-#{@id}"}>
        <.chip navigate={~p"/tags/#{@tag}"}>{@tag.name}</.chip>
        <button
          type="button"
          class="button button--cancel button--small"
          phx-click="clear"
          phx-value-side={@side}
        >
          {gettext("Change")}
        </button>
      </div>

      <form :if={is_nil(@tag)} id={"search-#{@id}"} phx-change="search" phx-submit="search" class="mt-2">
        <input type="hidden" name="side" value={@side} />
        <input
          type="text"
          id={"q-#{@id}"}
          name="q"
          value={@query}
          autocomplete="off"
          placeholder={gettext("Search by name or slug")}
        />
      </form>

      <ul :if={is_nil(@tag) and @results != []} class="thumbs mt-2">
        <li :for={result <- @results}>
          <button
            type="button"
            id={"pick-#{@side}-#{result.id}"}
            class="button button--small"
            phx-click="pick"
            phx-value-side={@side}
            phx-value-id={result.id}
          >
            {result.name}
          </button>
        </li>
      </ul>
    </div>
    """
  end
end
