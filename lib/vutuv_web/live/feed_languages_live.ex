defmodule VutuvWeb.FeedLanguagesLive do
  @moduledoc """
  The feed's language settings (GET /settings/feed_languages, issue #1672):
  a **ranked** list of the languages this member reads, plus what the feed does
  with everything else — show the original, translate it, or hide it.

  ## Why the list is ranked

  The list used to be an unordered set of chips on /settings/preferences, and
  the translation target was the reader's **UI locale**. That made Stefan's
  own case unsayable: "I read German and English, and everything else should
  reach me translated into German" is a sentence about *rank*, and a member
  browsing vutuv in English got English translations however they ticked the
  boxes. Now position 1 is the target — `VutuvWeb.Live.PostTranslations.target_language/1`
  is the one reader of that rule, and it serves the automatic mode and the
  manual Translate button alike.

  Ranking costs nothing for the common case (one language, which is trivially
  first) and is the only thing that had to be added to express the hard one.

  ## Why its own page, and why a LiveView

  It was one card among six on "Language & display", which is where a member
  goes to change the interface language — a different question that merely
  shares a word. Its own hub row under "Notifications & feed" puts it where
  somebody whose feed is full of a language they cannot read will actually
  look.

  A LiveView because ranking is the page's whole job and a reload per move is
  absurd: the arrows are `phx-click` (the reorder path on a phone, where no
  native drag event exists) and desktop drag reuses the `Reorder` hook and the
  `.reorder*` classes the profile sections already use. Every change persists
  on the spot through `Vutuv.Accounts.update_user/2` — the settings write
  chokepoint — so there is no Save button to forget.

  ## The summary panel

  The two controls interact in ways neither states alone, so the page says the
  outcome in words. It is not decoration: with **no** language chosen, "hide"
  hides nothing (`Vutuv.Posts.feed_language_filter/1` answers nil) while
  "translate" translates everything outside the UI locale — an asymmetry that
  is correct, deliberate and impossible to guess from two form controls. The
  panel names it, and the "hide" case gets an explicit warning rather than a
  setting that silently does nothing.
  """

  use VutuvWeb, :live_view

  on_mount({VutuvWeb.Live.InitAssigns, :require_login})

  alias Vutuv.AccountEvents
  alias Vutuv.Accounts
  alias Vutuv.Languages
  alias Vutuv.Posts
  alias Vutuv.Prefs
  alias Vutuv.Translations
  alias VutuvWeb.Live.PostTranslations

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:page_title, gettext("Feed languages"))
     |> assign(:foreign_pref, Prefs.pref!(:feed_foreign_posts))
     # The suggestion's *source* — interface language plus the profile's
     # language skills — cannot change while this page is open, and reading it
     # costs a query. Taken once here; what the card shows is that pool minus
     # whatever is already ranked, which `load_user/2` re-derives for free.
     |> assign(:suggestion_pool, Posts.suggested_feed_languages(user))
     |> load_user(user)}
  end

  ## Events

  @impl true
  def handle_event("add", %{"code" => code}, socket) do
    # `known?/1` here is not the validation — the changeset owns that — it is
    # what stops the picker's own placeholder ("" on every reselect) from
    # costing a write and an activity-log line.
    if Languages.known?(code) do
      # Appended, never inserted: a language a member just named is the one
      # they know least about ranking, and the top of the list is the slot
      # that carries a meaning (the translation target).
      {:noreply, store_languages(socket, socket.assigns.chosen ++ [code])}
    else
      {:noreply, socket}
    end
  end

  def handle_event("remove", %{"code" => code}, socket) do
    {:noreply, store_languages(socket, List.delete(socket.assigns.chosen, code))}
  end

  def handle_event("move", %{"code" => code, "dir" => dir}, socket) do
    {:noreply, store_languages(socket, move(socket.assigns.chosen, code, dir))}
  end

  # The desktop drag hook pushes the whole order. Trust nothing in it: keep
  # only codes this member actually chose, and append any the client left out,
  # so a stale or forged payload can reorder the list but never change what is
  # in it.
  def handle_event("reorder", %{"order" => order}, socket) when is_list(order) do
    chosen = socket.assigns.chosen
    submitted = order |> Enum.filter(&(&1 in chosen)) |> Enum.uniq()

    {:noreply, store_languages(socket, submitted ++ Enum.reject(chosen, &(&1 in submitted)))}
  end

  # The vocabulary lives on the changeset (`validate_inclusion`), so a forged
  # value is refused there and this page simply does not change — no second
  # copy of the list to keep in step.
  def handle_event("mode", %{"mode" => mode}, socket) do
    {:noreply, store(socket, %{"feed_foreign_posts" => mode})}
  end

  def handle_event("reset", _params, socket) do
    # Both halves: the plain member column and the :feed pref group beside it,
    # back to nil = inherit the installation default, current and future.
    {:ok, user} = Accounts.update_user(socket.assigns.user, %{"feed_languages" => []})
    {:ok, user} = Prefs.reset_group(user, :feed)

    record(user, ["feed_foreign_posts", "feed_languages"])

    {:noreply,
     socket
     |> load_user(user)
     |> put_flash(:info, gettext("Feed language settings reset to the site defaults."))}
  end

  ## Writing

  # A reorder that changed nothing writes nothing. The drag hook pushes on
  # every `dragend`, including one that dropped a row back where it started,
  # and each of those would otherwise cost an UPDATE and a line in the
  # member's own account-activity log.
  defp store_languages(socket, codes) do
    if codes == socket.assigns.chosen,
      do: socket,
      else: store(socket, %{"feed_languages" => codes})
  end

  # Every write goes through the user-update chokepoint, which normalizes the
  # list (unknown codes dropped, order kept, an empty list stored as nil =
  # "all languages"). A rejected changeset leaves the page as it was: nothing
  # here can produce one, and a silent no-op beats a half-applied list.
  defp store(socket, params) do
    case Accounts.update_user(socket.assigns.user, params) do
      {:ok, user} ->
        record(user, Map.keys(params))
        load_user(socket, user)

      {:error, _changeset} ->
        socket
    end
  end

  # The account-activity log hears about a settings change here the same way it
  # hears about one made on a controller page: the field NAMES only, never the
  # values (issue #1087).
  defp record(user, fields),
    do: AccountEvents.record(user, "preferences_changed", details: %{fields: Enum.sort(fields)})

  defp load_user(socket, user) do
    chosen = Posts.chosen_feed_languages(user)

    socket
    |> assign(:user, user)
    |> assign(:chosen, chosen)
    |> assign(:mode, Prefs.get(user, :feed_foreign_posts))
    |> assign(:target, PostTranslations.target_language(user))
    |> assign(:addable, Enum.reject(Languages.options(), fn {_label, code} -> code in chosen end))
    |> assign(:suggested, Enum.reject(socket.assigns.suggestion_pool, &(&1 in chosen)))
  end

  # Move one entry a single step. Both out-of-range cases — an arrow at either
  # end (disabled in the markup) and a code that is not in the list — fall out
  # of the one range test as "unchanged".
  defp move(codes, code, dir) do
    from = Enum.find_index(codes, &(&1 == code))
    to = target_index(from, dir)

    if to in 0..(length(codes) - 1)//1 do
      codes |> List.delete_at(from) |> List.insert_at(to, code)
    else
      codes
    end
  end

  defp target_index(nil, _dir), do: nil
  defp target_index(index, "up"), do: index - 1
  defp target_index(index, _down), do: index + 1

  ## Rendering

  @impl true
  def render(assigns) do
    ~H"""
    <.settings_shell user={@user} active={:feed_languages} title={gettext("Feed languages")}>
      <div class="space-y-6">
        <%!-- Deliberately does not repeat "posts that declare no language
        always show": the card below says it, from the shared
        `Prefs.hint(:feed_foreign_posts)`, and one page saying the same
        sentence twice reads as two different rules. --%>
        <.card>
          <p class="text-sm text-slate-600 dark:text-slate-400">
            {gettext(
              "Rank the languages you read. Posts in them reach your feed as they were written; you decide below what happens to the rest."
            )}
          </p>
        </.card>

        <.card>
          <.section_title>{gettext("Languages you read")}</.section_title>

          <p :if={@chosen == []} class="mt-3 text-sm text-slate-600 dark:text-slate-400">
            {gettext("No language chosen, so your feed shows all of them.")}
          </p>

          <%!-- The ranked list. `.reorder*` + the `Reorder` hook are the same
          drag-and-arrows tool the orderable profile sections use, so ordering
          reads and behaves identically wherever a member meets it here. The
          arrows are the path on a phone (touch fires no native drag event);
          the drag layers on top for a mouse. --%>
          <ul :if={@chosen != []} id="feed-language-order" class="reorder mt-3" phx-hook="Reorder">
            <li
              :for={{code, index} <- Enum.with_index(@chosen)}
              id={"feed-language-#{code}"}
              class="reorder__item"
              draggable="true"
              data-id={code}
              data-feed-language={code}
            >
              <span class="reorder__handle" aria-hidden="true" title={gettext("Drag to reorder")}>
                ⠿
              </span>

              <div class="reorder__body">
                <div class="reorder__text">
                  <div class="reorder__title">{Languages.name(code)}</div>
                  <div :if={index == 0} class="reorder__sub" data-target-note>
                    {gettext("First: translations go into this language")}
                  </div>
                </div>
              </div>

              <div class="reorder__move">
                <button
                  type="button"
                  phx-click="move"
                  phx-value-code={code}
                  phx-value-dir="up"
                  class="reorder__btn"
                  disabled={index == 0}
                  aria-label={gettext("Move up")}
                >
                  ↑
                </button>
                <button
                  type="button"
                  phx-click="move"
                  phx-value-code={code}
                  phx-value-dir="down"
                  class="reorder__btn"
                  disabled={index == length(@chosen) - 1}
                  aria-label={gettext("Move down")}
                >
                  ↓
                </button>
              </div>

              <button
                type="button"
                phx-click="remove"
                phx-value-code={code}
                class="reorder__btn"
                aria-label={gettext("Remove %{language}", language: Languages.name(code))}
              >
                ×
              </button>
            </li>
          </ul>

          <%!-- One tap for the languages this account already says the member
          reads (interface language + the language skills on their profile).
          A suggestion, never a preselection: it is offered as something to
          press, so nothing lands in the list that they did not choose. --%>
          <div :if={@suggested != []} class="mt-4 flex flex-wrap items-center gap-2">
            <span class="text-sm text-slate-600 dark:text-slate-400">{gettext("Suggested:")}</span>
            <button
              :for={code <- @suggested}
              type="button"
              phx-click="add"
              phx-value-code={code}
              data-suggested-language={code}
              class="inline-flex min-h-10 items-center rounded-full border border-slate-300 px-3 text-sm font-medium text-slate-700 hover:border-brand-600 hover:text-brand-700 focus-visible:ring-3 focus-visible:ring-brand-500 dark:border-slate-700 dark:text-slate-200 dark:hover:border-brand-500 dark:hover:text-brand-300"
            >
              + {Languages.name(code)}
            </button>
          </div>

          <%!-- Picking is the whole gesture, so there is no Add button beside
          it: `phx-change` adds on the spot, which is one tap instead of two
          and no reach across the form on a phone.

          The id carries the list length so a save gives morphdom a *new*
          element rather than a patched one, which is what reliably clears the
          member's pick back to the placeholder — a select's value is client
          state, and a patched-in-place select can keep showing a language that
          is already in the list above it. --%>
          <form phx-change="add" class="mt-4 sm:max-w-xs">
            <label
              for={"add-feed-language-#{length(@chosen)}"}
              class="block text-sm font-medium text-slate-900 dark:text-white"
            >
              {gettext("Add a language")}
            </label>
            <select
              id={"add-feed-language-#{length(@chosen)}"}
              name="code"
              class={input_class()}
              data-add-language
            >
              <option value="">{gettext("Choose a language")}</option>
              <option :for={{label, code} <- @addable} value={code}>{label}</option>
            </select>
          </form>
        </.card>

        <.card>
          <.section_title>{Prefs.label(:feed_foreign_posts)}</.section_title>
          <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">{Prefs.hint(:feed_foreign_posts)}</p>

          <%!-- The "translate" option names the target instead of saying "my
          language": on this page we know exactly which language it is, and
          "In meine Sprache übersetzen" was written when the target was the UI
          locale — a sentence that is now merely vague where it used to be
          wrong. The admin page keeps the generic `Prefs.value_label/2`, because
          an installation default has no member whose first language it could
          name. --%>
          <form phx-change="mode" class="mt-4 sm:max-w-xs">
            <label for="feed-foreign-posts" class="sr-only">{Prefs.label(:feed_foreign_posts)}</label>
            <select id="feed-foreign-posts" name="mode" class={input_class()}>
              <option :for={value <- @foreign_pref.values} value={value} selected={value == @mode}>
                {mode_label(@foreign_pref, value, @target)}
              </option>
            </select>
          </form>

          <p
            :if={@mode == "translate" and not Translations.enabled?()}
            class="mt-3 text-sm text-slate-600 dark:text-slate-400"
            data-translations-off
          >
            {gettext(
              "This installation has translations switched off, so posts in other languages show as written until an administrator turns them on."
            )}
          </p>
        </.card>

        <.card>
          <.section_title>{gettext("What your feed does")}</.section_title>
          <.outcome chosen={@chosen} mode={@mode} target={@target} />
        </.card>

        <div
          :if={Prefs.customized_in_group?(@user, :feed) or @user.feed_languages != nil}
          class="pt-1"
        >
          <button
            type="button"
            phx-click="reset"
            id="reset-feed-languages"
            class="text-sm font-semibold text-slate-600 hover:text-slate-800 dark:text-slate-400 dark:hover:text-slate-200"
          >
            {gettext("Reset to the site defaults")}
          </button>
        </div>
      </div>
    </.settings_shell>
    """
  end

  @doc """
  The plain-language outcome of the two controls together.

  Each line is **one** translatable string with placeholders, never a sentence
  assembled from translated fragments, and the languages themselves are
  rendered as chips rather than joined into prose — a comma-and-"and" list is
  a per-language grammar this installation has no CLDR list formatter for, and
  faking one is exactly the kind of concatenation that reads as machine text
  in every locale but the one it was written in.
  """
  attr(:chosen, :list, required: true)
  attr(:mode, :string, required: true)
  attr(:target, :string, required: true)

  def outcome(assigns) do
    ~H"""
    <dl class="mt-3 space-y-3 text-sm">
      <div :if={@chosen != []}>
        <dt class="font-medium text-slate-900 dark:text-white">{gettext("Shown as written")}</dt>
        <dd class="mt-1 flex flex-wrap gap-2">
          <.chip :for={code <- @chosen}>{Languages.name(code)}</.chip>
        </dd>
      </div>

      <div>
        <dt class="font-medium text-slate-900 dark:text-white">
          {if @chosen == [], do: gettext("Every language"), else: gettext("Every other language")}
        </dt>
        <dd class="mt-1 text-slate-600 dark:text-slate-400" data-outcome-rest>
          {rest_sentence(@chosen, @mode, @target)}
        </dd>
      </div>
    </dl>
    """
  end

  # The option that names its own target. Only "translate" has one; the other
  # two keep the registry's shared wording.
  defp mode_label(_pref, "translate", target),
    do: gettext("Translate into %{language}", language: Languages.name(target))

  defp mode_label(pref, value, _target), do: Prefs.value_label(pref, value)

  # "hide" with no language chosen hides nothing at all — the filter has no
  # list to keep. Said out loud, because a member who picked it and saw no
  # change would otherwise conclude the setting is broken.
  defp rest_sentence([], "hide", _target),
    do: gettext("Nothing is hidden: hiding needs at least one language above.")

  defp rest_sentence(_chosen, "hide", _target), do: gettext("Hidden from your feed.")

  defp rest_sentence(_chosen, "translate", target),
    do: gettext("Translated into %{language}.", language: Languages.name(target))

  defp rest_sentence(_chosen, _original, _target),
    do: gettext("Shown in the language it was written in.")
end
