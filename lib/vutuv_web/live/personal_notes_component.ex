defmodule VutuvWeb.PersonalNotesComponent do
  @moduledoc """
  The "Personal notes" panel on a member's profile, an organization page and a
  remote account's page (`Vutuv.PersonalNotes`): the newest few notes the viewer
  wrote about that account, a form to add one, and Edit / Delete on each.

  One component for the three pages, because the three hold the same thing
  about a different kind of account. It renders nothing visible until there is
  a note or the viewer asked to write one: an empty "Personal notes" card on
  every profile would be a box about nothing. The way in is the page's own
  control (the profile's ⋯ menu, a button on the other two), which sends
  `open_form/0` straight to this panel.

  The page passes `viewer` and `subject`; the notes are loaded here, once per
  pair, so the page's own re-renders (a live count ticking) cost no query.

  The open forms survive a reconnect: both carry a `phx-change`, so LiveView's
  form recovery replays what is typed and `"draft"` reopens the form it belongs
  to.
  """

  use VutuvWeb, :live_component

  import VutuvWeb.PersonalNoteComponents

  alias Phoenix.LiveView.JS
  alias Vutuv.PersonalNotes

  # The DOM id every page mounts the panel under, which `open_form/0` targets.
  @panel_id "personal-notes"

  @doc "The panel's DOM id."
  def panel_id, do: @panel_id

  @doc "The page control's click: open the new-note form on the panel."
  def open_form, do: JS.push("new", target: "#" <> @panel_id)

  @impl true
  def mount(socket) do
    {:ok, assign(socket, composing?: false, editing: nil, errors: [], loaded_for: nil)}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, id: assigns.id, viewer: assigns.viewer, subject: assigns.subject)
    key = {assigns.viewer && assigns.viewer.id, assigns.subject.id}

    if socket.assigns.loaded_for == key,
      do: {:ok, socket},
      else: {:ok, socket |> assign(:loaded_for, key) |> load()}
  end

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply, assign(socket, composing?: true, editing: nil, errors: [])}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, composing?: false, errors: [])}
  end

  def handle_event("draft", %{"note_id" => id}, socket),
    do: {:noreply, assign(socket, editing: id, composing?: false)}

  def handle_event("draft", _params, socket), do: {:noreply, assign(socket, :composing?, true)}

  def handle_event("save", %{"note" => params}, socket) do
    %{viewer: viewer, subject: subject} = socket.assigns

    case PersonalNotes.create(viewer, subject, params) do
      {:ok, _note} ->
        {:noreply, socket |> assign(composing?: false, errors: []) |> load()}

      {:error, reason} ->
        {:noreply, assign(socket, :errors, refusal(reason))}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    {:noreply, assign(socket, editing: id, composing?: false, errors: [])}
  end

  def handle_event("cancel-edit", _params, socket) do
    {:noreply, assign(socket, editing: nil, errors: [])}
  end

  def handle_event("update", %{"note_id" => id, "note" => params}, socket) do
    case PersonalNotes.update(socket.assigns.viewer, id, params) do
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :errors, refusal(changeset))}

      _saved_or_gone ->
        {:noreply, socket |> assign(editing: nil, errors: []) |> load()}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    PersonalNotes.delete(socket.assigns.viewer, id)
    {:noreply, load(socket)}
  end

  defp load(socket) do
    %{count: count, notes: notes} =
      PersonalNotes.summary(socket.assigns.viewer, socket.assigns.subject)

    assign(socket, count: count, notes: notes)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} data-personal-notes={@count} hidden={@count == 0 and not @composing?}>
      <.card>
        <div class="flex items-start justify-between gap-3">
          <div class="min-w-0">
            <.section_title>{gettext("Personal notes")}</.section_title>
            <p class="mb-0 mt-0.5 text-xs text-slate-600 dark:text-slate-400">{only_you()}</p>
          </div>
          <.button
            :if={not @composing?}
            variant="ghost"
            phx-click="new"
            phx-target={@myself}
            data-note-new
            class="shrink-0"
          >
            {gettext("Add note")}
          </.button>
        </div>

        <div :if={@composing?} class="mt-4">
          <.note_form
            id={"#{@id}-new"}
            viewer={@viewer}
            submit="save"
            cancel="cancel"
            target={@myself}
            errors={@errors}
          />
        </div>

        <div :if={@notes != []} class="mt-4 divide-y divide-slate-100 dark:divide-slate-800">
          <.note_item
            :for={note <- @notes}
            id={"#{@id}-note-#{note.id}"}
            note={note}
            viewer={@viewer}
            editing?={@editing == note.id}
            errors={if @editing == note.id, do: @errors, else: []}
            target={@myself}
            class="py-3 first:pt-0 last:pb-0"
          />
        </div>

        <.card_footer_link :if={@count > length(@notes)} href={notes_path(@subject)}>
          {ngettext("Show all %{formatted} notes", "Show all %{formatted} notes", @count,
            formatted: compact_count(@count)
          )}
        </.card_footer_link>
      </.card>
    </div>
    """
  end
end
