defmodule VutuvWeb.PersonalNotesLive do
  @moduledoc """
  Every private note the member wrote (`Vutuv.PersonalNotes`), at
  `/system/notes`: newest first, searchable as they type, and paged with
  "Load more" so a member with hundreds of notes gets twenty at a time.

  `?member=<id>`, `?organization=<id>` or `?remote_account=<id>` narrows the
  list to one account and adds a form to write about it; that is where the
  "Show all notes" link under a profile's panel and the card behind a handle
  lead. The search term rides the URL as `q`, so the view survives a reload.

  Under `/system/` because profiles own the URL root, and `noindex` because it
  is one member's private list.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.PersonalNoteComponents

  alias Vutuv.PersonalNotes
  alias Vutuv.SearchText

  @per_page 20
  @kinds ~w(member organization remote_account)

  on_mount({VutuvWeb.Live.InitAssigns, :require_login})

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: gettext("Personal notes"),
       subject_params: :unset,
       subject: nil,
       editing: nil,
       composing?: false,
       errors: []
     )}
  end

  # A search keystroke patches the URL too, so the account is resolved again
  # only when the filter part of the URL changed. That also keeps an open form
  # open while the member searches.
  @impl true
  def handle_params(params, _uri, socket) do
    query = params["q"] |> SearchText.normalize_search() |> SearchText.cap()

    socket
    |> assign(query: query, editing: nil, errors: [])
    |> put_subject(Map.take(params, @kinds))
    |> load(reset: true)
    |> then(&{:noreply, &1})
  end

  defp put_subject(%{assigns: %{subject_params: same}} = socket, same), do: socket

  defp put_subject(socket, subject_params) do
    user = socket.assigns.current_user

    subject =
      Enum.find_value(subject_params, fn {kind, id} -> PersonalNotes.subject(kind, id, user) end)

    assign(socket,
      subject_params: subject_params,
      subject: subject,
      # Nothing about this account yet: the form is the only thing to do here.
      composing?: subject != nil and PersonalNotes.count(user, subject) == 0
    )
  end

  # ── Events ─────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, push_patch(socket, to: notes_path(socket.assigns.subject, q))}
  end

  def handle_event("load-more", _params, socket), do: {:noreply, load(socket, reset: false)}

  def handle_event("new", _params, socket) do
    {:noreply, assign(socket, composing?: true, errors: [])}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, composing?: false, errors: [])}
  end

  def handle_event("draft", %{"note_id" => id}, socket) do
    if socket.assigns.editing == id,
      do: {:noreply, socket},
      else: {:noreply, socket |> assign(:editing, id) |> restream(id)}
  end

  def handle_event("draft", _params, socket), do: {:noreply, assign(socket, :composing?, true)}

  def handle_event("save", %{"note" => params}, %{assigns: %{subject: subject}} = socket)
      when not is_nil(subject) do
    case PersonalNotes.create(socket.assigns.current_user, subject, params) do
      {:ok, note} ->
        {:noreply,
         socket
         |> assign(composing?: false, errors: [])
         |> update(:shown, &(&1 + 1))
         |> stream_insert(:notes, %{note | subject: subject}, at: 0)}

      {:error, reason} ->
        {:noreply, assign(socket, :errors, refusal(reason))}
    end
  end

  # The form only renders under an account; a stale submit from a page whose
  # filter is gone has nobody to write about.
  def handle_event("save", _params, socket), do: {:noreply, socket}

  def handle_event("edit", %{"id" => id}, socket) do
    previous = socket.assigns.editing

    {:noreply,
     socket
     |> assign(editing: id, errors: [])
     |> restream(previous)
     |> restream(id)}
  end

  def handle_event("cancel-edit", _params, socket) do
    previous = socket.assigns.editing
    {:noreply, socket |> assign(editing: nil, errors: []) |> restream(previous)}
  end

  def handle_event("update", %{"note_id" => id, "note" => params}, socket) do
    case PersonalNotes.update(socket.assigns.current_user, id, params) do
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, socket |> assign(:errors, refusal(changeset)) |> restream(id)}

      _saved_or_gone ->
        {:noreply, socket |> assign(editing: nil, errors: []) |> restream(id)}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case PersonalNotes.delete(socket.assigns.current_user, id) do
      :ok ->
        {:noreply,
         socket
         |> stream_delete_by_dom_id(:notes, "notes-#{id}")
         |> update(:shown, &(&1 - 1))}

      {:error, :not_found} ->
        {:noreply, socket}
    end
  end

  # One page after the cursor, or the first page when `reset`. One extra row
  # is read to learn whether another page exists. `shown` counts what the
  # stream holds, since a stream cannot say whether it is empty.
  defp load(socket, reset: reset?) do
    %{current_user: user, subject: subject, query: query} = socket.assigns
    cursor = if reset?, do: nil, else: socket.assigns.cursor

    rows =
      PersonalNotes.list(user,
        subject: subject,
        query: query,
        max_id: cursor,
        limit: @per_page + 1
      )

    {page, rest} = Enum.split(rows, @per_page)

    socket
    |> stream(:notes, page, reset: reset?)
    |> assign(
      more?: rest != [],
      cursor: if(page == [], do: cursor, else: List.last(page).id),
      shown: if(reset?, do: length(page), else: socket.assigns.shown + length(page))
    )
  end

  # A streamed row renders only when it is inserted again, so every change to
  # which note is open for editing re-inserts the rows it concerns.
  defp restream(socket, nil), do: socket

  defp restream(socket, id) do
    case PersonalNotes.listed(socket.assigns.current_user, id) do
      nil -> socket
      note -> stream_insert(socket, :notes, note)
    end
  end

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-2xl space-y-6 py-6">
      <div>
        <h1 class="text-2xl font-bold text-slate-900 dark:text-white">
          {gettext("Personal notes")}
        </h1>
        <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">
          {gettext(
            "What you wrote down about other accounts. Nobody else can see these notes, including the accounts they are about."
          )}
        </p>
      </div>

      <.card :if={@subject} id="notes-subject">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <div class="min-w-0">
            <.section_title>{gettext("Notes about")}</.section_title>
            <div class="mt-2"><.subject_line subject={@subject} /></div>
          </div>
          <.button
            :if={not @composing?}
            variant="ghost"
            phx-click="new"
            data-note-new
          >
            {gettext("Add note")}
          </.button>
        </div>

        <div :if={@composing?} class="mt-4">
          <.note_form
            id="notes-new"
            viewer={@current_user}
            submit="save"
            cancel="cancel"
            errors={@errors}
          />
        </div>

        <.card_footer_link href={notes_path(nil)}>
          {gettext("All your notes")}
        </.card_footer_link>
      </.card>

      <.card>
        <.form
          for={%{}}
          id="notes-search"
          phx-change="search"
          phx-submit="search"
          class="mb-4"
        >
          <label for="notes-q" class="block text-sm font-semibold text-slate-700 dark:text-slate-200">
            {gettext("Search your notes")}
          </label>
          <input
            type="search"
            name="q"
            id="notes-q"
            value={@query}
            phx-debounce="250"
            autocomplete="off"
            maxlength={SearchText.max_chars()}
            placeholder={gettext("A word from the note, a name or a handle")}
            class={[input_class(), "mt-1"]}
          />
        </.form>

        <p :if={@shown == 0} id="notes-empty" class="mb-0 text-sm text-slate-600 dark:text-slate-400">
          {empty_text(@query, @subject)}
        </p>

        <div
          id="notes"
          phx-update="stream"
          class="divide-y divide-slate-100 dark:divide-slate-800"
        >
          <.note_item
            :for={{dom_id, note} <- @streams.notes}
            id={dom_id}
            note={note}
            viewer={@current_user}
            editing?={@editing == note.id}
            errors={if @editing == note.id, do: @errors, else: []}
            class="py-4 first:pt-0 last:pb-0"
          >
            <:subject :if={is_nil(@subject)}>
              <.subject_line subject={note.subject} />
            </:subject>
          </.note_item>
        </div>

        <.load_more :if={@more?} class="mt-4" />
      </.card>
    </div>
    """
  end

  defp empty_text(query, _subject) when is_binary(query),
    do: gettext("No note matches your search.")

  defp empty_text(nil, nil),
    do:
      gettext(
        "You have not written any notes yet. Open a profile and choose \"Add a personal note\" in its ⋯ menu."
      )

  defp empty_text(nil, _subject), do: gettext("No notes about this account yet.")
end
