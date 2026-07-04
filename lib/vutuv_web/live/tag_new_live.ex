defmodule VutuvWeb.TagNewLive do
  @moduledoc """
  The add-tag form (GET /settings/tags/new) — a LiveView so the member sees,
  while typing, exactly which tags a submit will attach (issue #848, variant
  one): the input splits on commas and spaces, a leading `#` is stripped, and
  each name is matched case-insensitively against the existing global tags,
  whose stored display name wins (`Vutuv.Tags.preview_tag_names/1`). That
  makes the non-obvious tag rules visible before the submit — a camel-case
  variant of an existing lowercase tag previews as the lowercase chip the
  profile will actually show.

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
    <.page_header crumbs={[
      {gettext("Settings"), ~p"/settings"},
      {gettext("Tags"), ~p"/settings/tags"},
      gettext("New")
    ]} />

    <.card_section>
      <.form for={@form} id="tag-form" class="editform" phx-change="preview" phx-submit="save">
        <.form_error :if={@changeset} changeset={@changeset} />

        <div class={["editform__field", @changeset && "editform__field--error"]}>
          <label for={@form[:value].id}>{gettext("Tags")}</label>
          <p class="editform__hint">
            💡 <strong>{gettext("Tip:")}</strong> {gettext(
              "Separate tags with a comma or a space."
            )}
          </p>
          <input
            type="text"
            id={@form[:value].id}
            name={@form[:value].name}
            value={@form[:value].value}
            placeholder={gettext("PHP, JavaScript, Origami, Recruiting")}
            autocomplete="off"
            phx-debounce="150"
          />
          {@changeset && error_tag(@changeset, :user_id_tag_id)}
        </div>

        <div :if={@preview != []} id="tag-preview" class="editform__field">
          <h2 class="card__label">{gettext("Preview")}</h2>
          <p class="editform__hint">{gettext("This will create the following tags:")}</p>
          <div class="mt-2 flex flex-wrap gap-2">
            <.chip :for={name <- @preview} data-tag-chip>{name}</.chip>
          </div>
        </div>

        <.form_actions backlink={~p"/settings/tags"} />
      </.form>
    </.card_section>
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
  end
end
