defmodule VutuvWeb.PersonalNoteComponents do
  @moduledoc """
  How a private note (`Vutuv.PersonalNotes`) looks wherever it is shown: the
  panel on a profile, a page or a remote account's page
  (`VutuvWeb.PersonalNotesComponent`), the overview at `/system/notes`
  (`VutuvWeb.PersonalNotesLive`) and the card behind a handle.

  One definition of a note row and one of its form, so the date, the "edited"
  mark and the two controls read the same on every surface. The events are the
  caller's: a row names them (`edit`, `delete`, `update`, `cancel-edit`) and the
  caller decides where they go with `target`.
  """

  use Phoenix.Component
  use Gettext, backend: VutuvWeb.Gettext

  use Phoenix.VerifiedRoutes,
    endpoint: VutuvWeb.Endpoint,
    router: VutuvWeb.Router,
    statics: ~w(assets fonts images favicon.ico)

  import VutuvWeb.UI
  import VutuvWeb.PostComponents, only: [remote_avatar: 1, remote_initials: 1]

  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Organizations.Organization
  alias Vutuv.PersonalNotes
  alias Vutuv.PersonalNotes.PersonalNote
  alias Vutuv.ViewerClock
  alias VutuvWeb.Markdown

  @doc """
  The overview, optionally filtered to one account
  (`?member=<id>`, `?organization=<id>`, `?remote_account=<id>`) and to a
  search term (`?q=`).
  """
  def notes_path(subject, query \\ nil) do
    params =
      Enum.reject(
        [
          {subject && PersonalNotes.kind(subject), subject && subject.id},
          {"q", query}
        ],
        fn {key, value} -> is_nil(key) or value in [nil, ""] end
      )

    if params == [], do: ~p"/system/notes", else: ~p"/system/notes?#{params}"
  end

  @doc "The \"Visible only to you\" line every surface puts beside a note."
  def only_you, do: gettext("Visible only to you")

  @doc """
  One note: its date, whether it was edited, the text, and Edit / Delete. While
  `editing?` the text gives way to the form.
  """
  attr(:id, :string, required: true)
  attr(:note, PersonalNote, required: true)
  attr(:viewer, :any, required: true, doc: "the author, for the editor's bandwidth setting")
  attr(:editing?, :boolean, default: false)
  attr(:target, :any, default: nil, doc: "`phx-target` for the row's events")
  attr(:errors, :list, default: [], doc: "what the last edit was refused for")
  attr(:class, :any, default: nil)
  slot(:subject, doc: "who the note is about, above the date (the overview)")

  def note_item(assigns) do
    ~H"""
    <article id={@id} data-personal-note={@note.id} class={@class}>
      {render_slot(@subject)}
      <p class="mb-1 flex flex-wrap items-baseline gap-x-2 text-xs text-slate-600 dark:text-slate-400">
        <.local_time
          at={@note.inserted_at}
          style={:date}
          id={"#{@id}-at"}
          class="font-semibold text-slate-700 dark:text-slate-300"
        />
        <%!-- The date that counts is when the note was taken, so an edit
        never moves it. The mark says it was changed and the tooltip when. --%>
        <span :if={@note.edited_at} data-note-edited title={edited_title(@note)}>
          · {gettext("edited")}
        </span>
      </p>

      <%= if @editing? do %>
        <.note_form
          id={"#{@id}-form"}
          viewer={@viewer}
          value={@note.body}
          submit="update"
          cancel="cancel-edit"
          note_id={@note.id}
          target={@target}
          errors={@errors}
        />
      <% else %>
        <.markdown_prose
          text={@note.body}
          class="text-sm leading-relaxed text-slate-800 dark:text-slate-200"
        />
        <div class="mt-1 flex items-center gap-1">
          <.button
            variant="ghost"
            phx-click="edit"
            phx-value-id={@note.id}
            phx-target={@target}
            data-note-edit
          >
            {gettext("Edit")}
          </.button>
          <.button
            variant="danger-ghost"
            phx-click="delete"
            phx-value-id={@note.id}
            phx-target={@target}
            data-confirm={gettext("Delete this note?")}
            data-note-delete
          >
            {gettext("Delete")}
          </.button>
        </div>
      <% end %>
    </article>
    """
  end

  defp edited_title(%PersonalNote{edited_at: at}),
    do: gettext("Edited on %{date}", date: ViewerClock.format(at, :datetime))

  @doc """
  The form for a new note or an edit. The shared Markdown editor, so a note is
  written exactly like a post.

  The editor lives inside the caller's `:if` and carries the note (or `new`) in
  its id, so it is created and destroyed rather than patched: a saved note
  closes the form, and the next one starts from an empty editor. That is why it
  takes no re-seed token.
  """
  attr(:id, :string, required: true)
  attr(:viewer, :any, required: true)
  attr(:value, :string, default: "")
  attr(:submit, :string, required: true)
  attr(:cancel, :string, required: true)
  attr(:note_id, :string, default: nil)
  attr(:target, :any, default: nil)
  attr(:errors, :list, default: [])

  def note_form(assigns) do
    ~H"""
    <%!-- `phx-change="draft"` is what lets LiveView's form recovery put a
    half-written note back after a reconnect: the replayed change tells the
    caller which form was open. Debounced on the field, where LiveView reads it. --%>
    <.form
      for={%{}}
      id={@id}
      phx-submit={@submit}
      phx-change="draft"
      phx-target={@target}
      class="space-y-2"
      data-note-form
    >
      <input :if={@note_id} type="hidden" name="note_id" value={@note_id} />
      <.markdown_editor
        id={"#{@id}-editor"}
        name="note[body]"
        user={@viewer}
        value={@value}
        label={gettext("Personal note")}
        placeholder={gettext("What do you want to remember?")}
        rows={4}
        debounce="1000"
        submit_on="cmd-enter"
        compact
      />
      <p :for={error <- @errors} class="text-sm text-rose-600 dark:text-rose-400" data-note-error>
        {error}
      </p>
      <p class="text-xs text-slate-600 dark:text-slate-400">
        {only_you()} · {gettext("An @handle links to that profile and notifies nobody.")}
      </p>
      <div class="flex flex-wrap gap-2">
        <.button type="submit" phx-disable-with={gettext("Saving…")}>{gettext("Save")}</.button>
        <.button variant="ghost" phx-click={@cancel} phx-target={@target}>
          {gettext("Cancel")}
        </.button>
      </div>
    </.form>
    """
  end

  @doc """
  The picture of an account, whichever kind it is, at the 36px the remote tile
  has: the notes list and the card behind a handle both draw it.
  """
  attr(:subject, :any, required: true)

  def subject_avatar(%{subject: %User{}} = assigns) do
    ~H"""
    <.avatar user={@subject} size="sm" />
    """
  end

  def subject_avatar(%{subject: %Organization{}} = assigns) do
    ~H"""
    <.organization_logo organization={@subject} class="h-9 w-9 shrink-0 rounded-lg" />
    """
  end

  def subject_avatar(%{subject: %RemoteAccount{}} = assigns) do
    ~H"""
    <.remote_avatar initials={remote_initials(@subject)} src={RemoteAccount.avatar_url(@subject)} />
    """
  end

  @doc "Who a note is about, as a link to their page: picture, name, handle."
  attr(:subject, :any, required: true)

  def subject_line(assigns) do
    ~H"""
    <.link
      href={PersonalNotes.path(@subject)}
      class="mb-2 flex min-w-0 items-center gap-2 text-sm hover:text-brand-700 dark:hover:text-brand-300"
      data-note-subject={PersonalNotes.kind(@subject)}
    >
      <.subject_avatar subject={@subject} />
      <span class="min-w-0 truncate">
        <span class="font-semibold text-slate-900 dark:text-white">
          {PersonalNotes.display_name(@subject)}
        </span>
        <span
          :if={PersonalNotes.handle(@subject)}
          class="text-slate-600 dark:text-slate-400"
        >
          {PersonalNotes.handle(@subject)}
        </span>
      </span>
    </.link>
    """
  end

  @doc """
  The viewer's newest notes inside the card behind a handle
  (`assets/js/mention_card.js`), as the same quoted tiles the remote card uses
  for posts. Plain links only: the card is a fragment outside every LiveView
  root. Renders nothing when there are no notes, or when notes do not apply
  (`summary` false or nil).
  """
  attr(:subject, :any, required: true)
  attr(:summary, :any, required: true, doc: "`Vutuv.PersonalNotes.summary/3`, or false/nil")

  def card_notes(%{summary: %{notes: [_ | _]}} = assigns) do
    ~H"""
    <div class="actor-card__posts" data-actor-card-notes={@summary.count}>
      <a :for={note <- @summary.notes} href={notes_path(@subject)} class="actor-card__latest">
        <span class="actor-card__latest-label">
          {gettext("Your note")} · {ViewerClock.format(note.inserted_at, :date)}
        </span>
        <span class="actor-card__latest-text line-clamp-2">
          {note_line(note.body)}
        </span>
      </a>
    </div>
    """
  end

  def card_notes(assigns), do: ~H""

  # Two lines of a note that may run to 10,000 characters: cut the source before
  # the Markdown pipeline, which only has to find those two lines.
  defp note_line(body), do: body |> String.slice(0, 600) |> Markdown.to_preview_line()

  @doc """
  The card's way to the notes: to a first one while there is none, to all of
  them once the card cannot show every one, and to the list otherwise. A row of
  `.actor-card__links`, so it sits beside the card's other ways onward.
  """
  attr(:subject, :any, required: true)
  attr(:summary, :any, required: true)

  def card_notes_link(%{summary: %{count: _}} = assigns) do
    ~H"""
    <a href={notes_path(@subject)} data-actor-card-notes-link>
      <span>{card_notes_label(@summary)}</span>
      <span class="actor-card__go" aria-hidden="true">›</span>
    </a>
    """
  end

  def card_notes_link(assigns), do: ~H""

  defp card_notes_label(%{count: 0}), do: gettext("Add a personal note")

  defp card_notes_label(%{count: count, notes: notes}) when count > length(notes) do
    ngettext("All %{formatted} notes", "All %{formatted} notes", count,
      formatted: compact_count(count)
    )
  end

  defp card_notes_label(_summary), do: gettext("Your notes")

  @doc "Why a note was not saved, as the sentences the form shows."
  def refusal(%Ecto.Changeset{} = changeset),
    do: VutuvWeb.ErrorHelpers.changeset_messages(changeset)

  def refusal(:self), do: [gettext("You cannot write a note about yourself.")]
end
