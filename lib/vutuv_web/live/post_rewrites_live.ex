defmodule VutuvWeb.PostRewritesLive do
  @moduledoc """
  The reader's search-and-replace rules for one author (`Vutuv.PostRewrites`),
  at `/settings/rewrites/:account`, plus the list of accounts that have any at
  `/settings/rewrites`.

  Opened from a post card's ⋯ menu, which hands over the post it was opened on
  (`?post=` / `?remote_post=` / `?note=`) as the sample the two panes below the
  rules are drawn from: **before** is the text as stored, with what the rule
  being typed would catch marked in it; **after** is the result rendered the
  way the card will render it. Both follow every keystroke, so a member who has
  never written a regular expression sees what `^Gepostet in .*$` does before
  they save it — and the first rule is prefilled with the sample's last line,
  which is where a mirror's footer sits.

  A page rather than a modal for one reason: the card lives in fourteen hosts,
  some of them dead templates, and a link works in all of them while a modal
  would have to be wired into each. What a page owes in return is the way back,
  so the router's live_session reads the `Referer` of the dead render
  (`session/1`) and the **Done** button leads there; an explicit `?return_to=`
  wins over it, and the feed is the fallback.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.ErrorHelpers, only: [error_tag: 2, err_attrs: 2]

  on_mount({VutuvWeb.Live.InitAssigns, :require_login})

  alias Vutuv.Fediverse
  alias Vutuv.PostRewrites
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias VutuvWeb.ControllerHelpers
  alias VutuvWeb.Markdown

  # A footer line longer than this is not a footer, and a prefilled pattern that
  # long would be more frightening than helpful.
  @max_prefill_line 120

  @doc """
  The live_session's extra session: where the member came from, read off the
  dead render's `Referer`, as a local path — or nothing, when there is none or
  it points elsewhere. Only a LiveView routed through that live_session sees it.
  """
  def session(conn) do
    case Plug.Conn.get_req_header(conn, "referer") do
      [referer | _rest] ->
        case local_path(referer) do
          nil -> %{}
          path -> %{"return_to" => path}
        end

      [] ->
        %{}
    end
  end

  defp local_path(referer) do
    uri = URI.parse(referer)

    if (is_nil(uri.host) or Fediverse.local_host?(uri.host)) and is_binary(uri.path) do
      uri.path
      |> ControllerHelpers.with_query(uri.query || "")
      |> ControllerHelpers.safe_return_to()
    end
  end

  @impl true
  def mount(params, session, socket) do
    viewer = socket.assigns.current_user

    socket =
      socket
      |> assign(:user, viewer)
      |> assign(:page_title, gettext("Search & replace"))
      |> assign(:return_to, return_to(params, session))

    case socket.assigns.live_action do
      :index ->
        {:ok, assign(socket, :accounts, PostRewrites.accounts_for_user(viewer))}

      :edit ->
        mount_editor(socket, params, viewer)
    end
  end

  defp mount_editor(socket, params, viewer) do
    case PostRewrites.normalize_account(params["account"]) do
      nil ->
        {:ok, push_navigate(socket, to: ~p"/settings/rewrites")}

      account ->
        sample = PostRewrites.sample(named_sample(params), account, viewer)

        {:ok,
         socket
         |> assign(:account, account)
         |> assign(:sample, sample)
         |> load_rules()
         |> then(&assign_form(&1, prefill(&1.assigns.rules, sample)))
         |> assign_preview()}
    end
  end

  # Which record the ⋯ menu was opened on, if any.
  defp named_sample(params) do
    cond do
      id = params["remote_post"] -> {:remote_post, id}
      id = params["post"] -> {:post, id}
      id = params["note"] -> {:note, id}
      true -> nil
    end
  end

  # An explicit `?return_to=` beats the referer, and the feed is where a post
  # card is most often met.
  defp return_to(params, session) do
    ControllerHelpers.safe_return_to(params["return_to"]) || session["return_to"] || ~p"/feed"
  end

  ## Events

  @impl true
  def handle_event("validate", %{"rule" => attrs}, socket) do
    {:noreply, socket |> assign_form(attrs, :validate) |> assign_preview()}
  end

  def handle_event("add", %{"rule" => attrs}, socket) do
    case PostRewrites.create_rule(socket.assigns.user, socket.assigns.account, attrs) do
      {:ok, _rule} ->
        {:noreply, socket |> load_rules() |> assign_form(%{}) |> assign_preview()}

      {:error, :too_many_for_account} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("You have reached the limit of %{max} rules for one account.",
             max: PostRewrites.max_per_account()
           )
         )}

      {:error, :too_many} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("You have reached the limit of %{max} rules.",
             max: PostRewrites.max_per_user()
           )
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :rule))}
    end
  end

  def handle_event("move", %{"id" => id, "dir" => dir}, socket) when dir in ["up", "down"] do
    direction = if dir == "up", do: :up, else: :down
    PostRewrites.move_rule(socket.assigns.user, id, direction)

    {:noreply, socket |> load_rules() |> assign_preview()}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    PostRewrites.delete_rule(socket.assigns.user, id)

    {:noreply, socket |> load_rules() |> assign_preview()}
  end

  ## State

  # The saved rules, and the same rules compiled once for the preview — not
  # per keystroke.
  defp load_rules(socket) do
    %{user: user, account: account} = socket.assigns
    rules = PostRewrites.list_for_account(user, account)

    socket
    |> assign(:rules, rules)
    |> assign(:saved_rules, rules |> PostRewrites.compile() |> Map.get(account, []))
  end

  # The add form and, beside it, the rule it currently describes compiled (or
  # nil): the preview runs the draft as if it were saved last.
  defp assign_form(socket, attrs, action \\ nil) do
    changeset = attrs |> PostRewrites.change_rule() |> Map.put(:action, action)
    pattern = Ecto.Changeset.get_field(changeset, :pattern)
    replacement = Ecto.Changeset.get_field(changeset, :replacement)

    draft =
      with true <- changeset.errors == [] and is_binary(pattern) and pattern != "",
           {:ok, compiled} <- PostRewrites.compile_rule(pattern, replacement) do
        compiled
      else
        _none -> nil
      end

    socket
    |> assign(:form, to_form(changeset, as: :rule))
    |> assign(:draft, draft)
  end

  # The two panes. With a draft, "before" is the text after the SAVED rules —
  # what the reader sees today — with the draft's catches marked, and "after"
  # adds the draft; without one, "before" is the stored text and "after" shows
  # what the saved rules make of it.
  defp assign_preview(%{assigns: %{sample: nil}} = socket), do: assign(socket, :preview, nil)

  defp assign_preview(socket) do
    %{sample: sample, saved_rules: saved, draft: draft} = socket.assigns
    text = Posts.text(sample) || ""

    {segments, result} =
      if draft do
        base = PostRewrites.rewrite_text(text, saved)
        {PostRewrites.segments(base, draft), PostRewrites.rewrite_text(base, [draft])}
      else
        {[{:plain, text}], PostRewrites.rewrite_text(text, saved)}
      end

    assign(socket, :preview, %{
      segments: segments,
      hits: Enum.count(segments, &match?({:hit, _}, &1)),
      result: result,
      result_html: render_result(sample, result),
      changed?: result != text
    })
  end

  defp render_result(%Post{}, text), do: Markdown.render_post(text, [])
  defp render_result(_remote, text), do: Phoenix.HTML.raw(Markdown.render_remote(text))

  # The beginner's first rule: the sample's last line, anchored, with an empty
  # replacement — a footer, deleted. Only while the account has no rules yet;
  # after that the form starts empty like any other.
  defp prefill([], sample) when not is_nil(sample) do
    line =
      (Posts.text(sample) || "")
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> List.last()

    if is_binary(line) and String.length(line) <= @max_prefill_line,
      do: %{"pattern" => "^" <> escape(line) <> "$", "replacement" => ""},
      else: %{}
  end

  defp prefill(_rules, _sample), do: %{}

  # Only what PCRE would read as syntax. `Regex.escape/1` also escapes spaces
  # and `#`, which turns a sentence into a thicket for the person reading it.
  defp escape(line), do: String.replace(line, ~r/[\\^$.|?*+()\[\]{}]/u, "\\\\\\0")

  ## Render

  @impl true
  def render(%{live_action: :index} = assigns) do
    ~H"""
    <.settings_shell user={@user} active={:rewrites} title={gettext("Search & replace")}>
      <.card>
        <.section_title>{gettext("Search & replace")}</.section_title>
        <p class="mt-3 text-sm text-slate-600 dark:text-slate-400">
          {gettext(
            "Rules that rewrite the text of one account's posts before you read them: a footer under every post, a signature, a wall of hashtags. Only you see the difference. Open the ⋯ menu on any post to write rules for its author."
          )}
        </p>

        <ul
          :if={@accounts != []}
          id="rewrite-accounts"
          class="mt-6 divide-y divide-slate-100 dark:divide-slate-800"
        >
          <li
            :for={row <- @accounts}
            class="flex items-center justify-between gap-3 py-3 first:pt-0 last:pb-0"
          >
            <.link
              href={~p"/settings/rewrites/#{row.account}"}
              class="min-w-0 break-all font-mono text-sm font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
            >
              {row.account}
            </.link>
            <span class="shrink-0 text-xs text-slate-600 dark:text-slate-400">
              {ngettext("%{formatted} rule", "%{formatted} rules", row.count,
                formatted: compact_count(row.count)
              )}
            </span>
          </li>
        </ul>

        <p :if={@accounts == []} class="mt-6 text-sm text-slate-600 dark:text-slate-400">
          {gettext("You have no rules yet.")}
        </p>
      </.card>
    </.settings_shell>
    """
  end

  def render(assigns) do
    ~H"""
    <.settings_shell user={@user} active={:rewrites} title={gettext("Search & replace")}>
      <div class="space-y-6">
        <.card>
          <.section_title>{gettext("Rules for %{account}", account: @account)}</.section_title>
          <p class="mt-3 text-sm text-slate-600 dark:text-slate-400">
            {gettext(
              "Each rule is a regular expression and what its matches become. They run from top to bottom on the text of every post by this account, for you alone. Leave the replacement empty to delete what a rule finds."
            )}
          </p>

          <ol
            :if={@rules != []}
            id="rewrite-rules"
            class="mt-5 divide-y divide-slate-100 dark:divide-slate-800"
          >
            <li
              :for={{rule, index} <- Enum.with_index(@rules)}
              id={"rewrite-#{rule.id}"}
              class="flex flex-wrap items-center gap-3 py-3 first:pt-0 last:pb-0"
              data-rewrite-pattern={rule.pattern}
            >
              <span class="w-6 shrink-0 text-right text-xs text-slate-600 dark:text-slate-400">
                {index + 1}.
              </span>
              <div class="min-w-0 flex-1 break-all font-mono text-sm">
                <code class="font-semibold text-slate-900 dark:text-slate-100">{rule.pattern}</code>
                <span class="mx-1 text-slate-600 dark:text-slate-400" aria-hidden="true">→</span>
                <code :if={rule.replacement != ""} class="text-slate-900 dark:text-slate-100">
                  {rule.replacement}
                </code>
                <span
                  :if={rule.replacement == ""}
                  class="text-xs italic text-slate-600 dark:text-slate-400"
                >
                  {gettext("(deleted)")}
                </span>
              </div>
              <%!-- The same arrow pair the profile's reorder tool and the feed
              languages page use, so one look for "move this row" app-wide. --%>
              <div class="reorder__move">
                <button
                  type="button"
                  id={"move-up-#{rule.id}"}
                  phx-click="move"
                  phx-value-id={rule.id}
                  phx-value-dir="up"
                  class="reorder__btn"
                  disabled={index == 0}
                  aria-label={gettext("Move up")}
                >
                  ↑
                </button>
                <button
                  type="button"
                  id={"move-down-#{rule.id}"}
                  phx-click="move"
                  phx-value-id={rule.id}
                  phx-value-dir="down"
                  class="reorder__btn"
                  disabled={index == length(@rules) - 1}
                  aria-label={gettext("Move down")}
                >
                  ↓
                </button>
              </div>
              <.button
                type="button"
                variant="danger-ghost"
                id={"delete-#{rule.id}"}
                phx-click="delete"
                phx-value-id={rule.id}
              >
                {gettext("Remove")}
              </.button>
            </li>
          </ol>

          <.form
            for={@form}
            id="rewrite-form"
            phx-change="validate"
            phx-submit="add"
            class="mt-5 flex flex-col gap-3"
          >
            <div>
              <label
                for="rule_pattern"
                class="block text-sm font-medium text-slate-700 dark:text-slate-300"
              >
                {gettext("Search for")}
              </label>
              <input
                type="text"
                id="rule_pattern"
                name={@form[:pattern].name}
                value={Phoenix.HTML.Form.normalize_value("text", @form[:pattern].value)}
                phx-debounce="200"
                autocomplete="off"
                spellcheck="false"
                placeholder="^Gepostet in .*$"
                class={[input_class(@form, :pattern), "mt-1 font-mono"]}
                {err_attrs(@form, :pattern)}
              />
              {error_tag(@form, :pattern)}
              <p
                :if={!@form.errors[:pattern]}
                class="mt-1 text-xs text-slate-600 dark:text-slate-400"
              >
                {gettext(
                  "A regular expression. ^ is the start of a line, $ its end, .* anything in between. Case matters unless the rule starts with (?i)."
                )}
              </p>
            </div>
            <div>
              <label
                for="rule_replacement"
                class="block text-sm font-medium text-slate-700 dark:text-slate-300"
              >
                {gettext("Replace with")}
              </label>
              <input
                type="text"
                id="rule_replacement"
                name={@form[:replacement].name}
                value={Phoenix.HTML.Form.normalize_value("text", @form[:replacement].value)}
                phx-debounce="200"
                autocomplete="off"
                spellcheck="false"
                placeholder={gettext("Empty deletes the match")}
                class={[input_class(@form, :replacement), "mt-1 font-mono"]}
                {err_attrs(@form, :replacement)}
              />
              {error_tag(@form, :replacement)}
              <p
                :if={!@form.errors[:replacement]}
                class="mt-1 text-xs text-slate-600 dark:text-slate-400"
              >
                {gettext("\\1 puts back what the first (…) group matched, \\0 the whole match.")}
              </p>
            </div>
            <div class="flex flex-wrap items-center gap-3">
              <.button type="submit">{gettext("Add rule")}</.button>
              <.button id="rewrite-done" href={@return_to} variant="secondary">
                {gettext("Done")}
              </.button>
            </div>
          </.form>
        </.card>

        <.card :if={@preview}>
          <.section_title>{gettext("Before and after")}</.section_title>
          <p class="mt-3 text-sm text-slate-600 dark:text-slate-400">
            {sample_line(@account, @draft, @preview)}
          </p>
          <div class="mt-4 grid gap-4 md:grid-cols-2">
            <div>
              <h3 class="text-xs font-semibold uppercase tracking-wide text-slate-600 dark:text-slate-400">
                {gettext("Before")}
              </h3>
              <pre
                id="rewrite-before"
                class="mt-2 max-h-96 overflow-auto whitespace-pre-wrap break-words rounded-lg bg-slate-50 p-3 font-mono text-sm text-slate-800 dark:bg-slate-800 dark:text-slate-200"
              ><%= for segment <- @preview.segments do %><%= case segment do %><% {:hit, part} -> %><mark class="rounded-sm bg-brand-100 text-brand-900 dark:bg-brand-500/30 dark:text-brand-100">{part}</mark><% {:plain, part} -> %>{part}<% end %><% end %></pre>
            </div>
            <div>
              <h3 class="text-xs font-semibold uppercase tracking-wide text-slate-600 dark:text-slate-400">
                {gettext("After")}
              </h3>
              <div
                id="rewrite-after"
                class="mt-2 max-h-96 overflow-auto rounded-lg p-3 text-sm ring-1 ring-slate-200 dark:ring-slate-800"
              >
                <div
                  :if={@preview.result != ""}
                  class="markdown markdown--post text-slate-800 dark:text-slate-200"
                >
                  {@preview.result_html}
                </div>
                <p :if={@preview.result == ""} class="text-xs italic text-slate-600 dark:text-slate-400">
                  {gettext("Nothing is left of this post.")}
                </p>
              </div>
            </div>
          </div>
        </.card>

        <.card :if={is_nil(@preview)}>
          <p class="text-sm text-slate-600 dark:text-slate-400">
            {gettext("There is no post by this account to preview your rules on.")}
          </p>
        </.card>
      </div>
    </.settings_shell>
    """
  end

  # The one sentence over the panes: what is being previewed, and what the rule
  # being typed catches in it.
  defp sample_line(account, draft, preview) do
    cond do
      draft ->
        ngettext(
          "Your new rule matches %{count} time in this post by %{who}.",
          "Your new rule matches %{count} times in this post by %{who}.",
          preview.hits,
          who: account
        )

      preview.changed? ->
        gettext("Your saved rules change this post by %{who} as shown.", who: account)

      true ->
        gettext("Your rules leave this post by %{who} as it is.", who: account)
    end
  end
end
