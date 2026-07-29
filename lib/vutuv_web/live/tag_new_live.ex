defmodule VutuvWeb.TagNewLive do
  @moduledoc """
  The add-tag form (GET /settings/tags/new) shows, while typing, exactly which
  tags a submit will attach (issue #848). Two halves do that: the shared
  `<.tag_input>` pill box turns each comma-finished tag into a removable pill,
  so where one tag ends and the next begins is visible in the field itself; and
  the server preview below it speaks only when the outcome differs from those
  pills — an existing tag matched case-insensitively contributes its own stored
  display name (typing `AhmetSun` when `ahmetsun` exists), and a name the save
  would refuse drops out (`Vutuv.Tags.preview_tag_names/1`).

  Submitting saves over the socket through the same `Vutuv.Tags.add_user_tag/2`
  chokepoint the retired controller create action used: a single tag keeps the
  inline error re-render (duplicate / invalid), a batch redirects with a count.
  The parsed names are deduplicated case-insensitively first, so the outcome
  always matches the preview. Styled as a classic editform page
  (components.css), like its /settings siblings.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.ErrorHelpers

  on_mount({VutuvWeb.Live.InitAssigns, :require_login})

  alias Vutuv.Tags
  alias Vutuv.Tags.UserTag
  alias VutuvWeb.UserHelpers

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Tags"))
     |> assign(:changeset, nil)
     |> assign_input("")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.form_page
      user={@current_user}
      active={:tags}
      section={{gettext("Tags"), ~p"/settings/tags"}}
      title={gettext("Add a tag")}
    >
      <.form for={@form} id="tag-form" class="editform" phx-change="preview" phx-submit="save">
        <.form_error :if={@changeset} changeset={@changeset} />

        <div class={["editform__field", @changeset && "editform__field--error"]}>
          <label for={@form[:value].id}>{gettext("Tags")}</label>
          <p class="editform__hint">
            💡 <strong>{gettext("Tip:")}</strong> {gettext(
              "Separate tags with a comma. A tag may be several words long, like Ruby on Rails."
            )}
          </p>
          <.tag_input
            id="tag-input"
            field_id={@form[:value].id}
            name={@form[:value].name}
            value={@form[:value].value}
            placeholder={gettext("PHP, JavaScript, Ruby on Rails")}
            invalid?={@changeset != nil}
            phx-debounce="150"
          />
          {@changeset && error_tag(@changeset, :user_id_tag_id)}
          {@changeset && error_tag(@changeset, :tag_id)}
        </div>

        <%!-- The pills in the box already show what each tag is, so this says
        only what they cannot: which of them will be spelled differently once
        saved (an existing tag keeps the spelling its first writer chose) and
        which will be dropped as unusable. When the two agree it stays away
        rather than repeating the box back at the member. --%>
        <div :if={@preview != [] and @preview != @typed} id="tag-preview" class="editform__field">
          <h2 class="card__label">{gettext("Preview")}</h2>
          <p class="editform__hint">{gettext("This will create the following tags:")}</p>
          <div class="mt-2 flex flex-wrap gap-2">
            <.chip :for={name <- @preview} data-tag-chip>{name}</.chip>
          </div>
        </div>

        <.form_actions backlink={~p"/settings/tags"} submit={gettext("Add tags")} />
      </.form>
    </.form_page>
    """
  end

  @impl true
  def handle_event("preview", %{"tag_param" => %{"value" => value}}, socket) do
    # Editing again clears a stale submit error; the banner returns on the
    # next failed save.
    {:noreply, socket |> assign(:changeset, nil) |> assign_input(value)}
  end

  @impl true
  def handle_event("save", %{"tag_param" => %{"value" => value}}, socket) do
    user = socket.assigns.current_user

    if Tags.at_user_tag_limit?(user) do
      # Profile already at the tag ceiling: surface it inline (like a form
      # error) and attach nothing, for a single tag or a whole batch alike, so
      # the member sees one clear reason rather than a pile of failures.
      {:noreply,
       socket
       |> assign(:changeset, Tags.tag_limit_changeset(user))
       |> assign_input(value)}
    else
      save_tags(socket, user, value)
    end
  end

  defp save_tags(socket, user, value) do
    case value |> Tags.parse_tag_names() |> Enum.uniq_by(&String.downcase/1) do
      # Nothing usable typed: keep the form, show the error banner (the same
      # empty-changeset re-render the controller create used to do).
      [] ->
        changeset = %UserTag{} |> UserTag.changeset(%{}) |> Map.put(:action, :insert)
        {:noreply, socket |> assign(:changeset, changeset) |> assign_input(value)}

      [single] ->
        case Tags.add_user_tag(user, single) do
          {:ok, _user_tag} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("User tag created successfully."))
             |> redirect(to: ~p"/settings/tags")}

          {:error, changeset} ->
            {:noreply, socket |> assign(:changeset, changeset) |> assign_input(value)}
        end

      many ->
        results = Enum.map(many, &Tags.add_user_tag(user, &1))
        failures = Enum.count(results, &match?({:error, _}, &1))
        successes = length(results) - failures
        kind = if successes == 0, do: :error, else: :info

        {:noreply,
         socket
         |> put_flash(kind, UserHelpers.tags_added_flash(successes, failures))
         |> redirect(to: ~p"/settings/tags")}
    end
  end

  defp assign_input(socket, value) do
    socket
    |> assign(:form, to_form(%{"value" => value}, as: :tag_param))
    |> assign(:preview, Tags.preview_tag_names(value))
    # What the pill box shows: the typed names, deduplicated the way a save
    # dedupes them. The preview block renders only where the two differ.
    |> assign(:typed, value |> Tags.parse_tag_names() |> Enum.uniq_by(&String.downcase/1))
  end
end
