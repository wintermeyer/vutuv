defmodule VutuvWeb.SectionReorderLive do
  @moduledoc """
  The owner's drag-and-drop ordering tool for a profile section, embedded into
  the section's (otherwise classic controller) index page via `live_render`,
  the same way the app shell is. It renders only for the page owner — the
  template gates the `live_render` on `@as_owner?` — so visitors and the "View
  as" preview keep the read-only `card_list`.

  One LiveView serves all five orderable sections (phone numbers, addresses,
  social media accounts, email addresses and links); the `section` (the URL
  segment) and the owner's `slug` arrive in the embedded session, the
  authenticated owner in the raw browser session's `user_id` (merged under the
  curated session by `Phoenix.LiveView.Static`, exactly like `ShellLive`). Every
  reorder/move is scoped to that `user_id` through `Vutuv.Ordering`, so the
  signed-in member can only ever renumber their own rows.

  Both interactions persist over the socket with no page reload: the up/down
  arrows are `phx-click` events; drag-and-drop is the `Reorder` JS hook
  (`app.js`) pushing the new id order. The disconnected first render still lists
  the entries (so the page is complete without JavaScript); reordering is the
  progressive enhancement on top.
  """
  use Phoenix.LiveView

  use Phoenix.VerifiedRoutes,
    endpoint: VutuvWeb.Endpoint,
    router: VutuvWeb.Router,
    statics: ~w(assets fonts images favicon.ico)

  use Gettext, backend: VutuvWeb.Gettext

  import Ecto.Query, only: [from: 2]
  import VutuvWeb.UI, only: [row_actions: 1]
  import VutuvWeb.UrlHTML, only: [linkable_url: 1, display_url: 1]
  import VutuvWeb.EmailHTML, only: [email_type_label: 1]
  import VutuvWeb.PhoneNumberHTML, only: [phone_type_label: 1]
  import VutuvWeb.UserHelpers, only: [format_address: 2]

  alias Vutuv.Profiles.SocialMediaAccount
  alias Vutuv.Repo

  # section (= URL segment) => the schema whose rows it orders.
  @schemas %{
    "phone_numbers" => Vutuv.Profiles.PhoneNumber,
    "addresses" => Vutuv.Profiles.Address,
    "social_media_accounts" => Vutuv.Profiles.SocialMediaAccount,
    "emails" => Vutuv.Accounts.Email,
    "links" => Vutuv.Profiles.Url
  }

  @impl true
  def mount(_params, session, socket) do
    # Embedded outside the live_session, so InitAssigns never runs — re-apply
    # the session locale here or the tool falls back to English.
    VutuvWeb.LiveLocale.put_locale(session)

    socket =
      socket
      # The authenticated owner is the raw browser session's user_id (merged
      # UNDER the curated session), never a value the page handed us — so the
      # signed-in member can only reorder their own rows. cast_or_nil tolerates
      # a pre-cutover integer cookie.
      |> assign(:user_id, Vutuv.UUIDv7.cast_or_nil(session["user_id"]))
      |> assign(:section, session["section"])
      |> assign(:slug, session["slug"])
      |> assign(:locale, session["locale"])
      |> load_entries()

    {:ok, socket}
  end

  @impl true
  def handle_event("reorder", %{"order" => order}, socket) when is_list(order) do
    Vutuv.Ordering.reorder(schema(socket), socket.assigns.user_id, order)
    {:noreply, load_entries(socket)}
  end

  def handle_event("move", %{"id" => id, "dir" => dir}, socket) when dir in ["up", "down"] do
    direction = if dir == "up", do: :up, else: :down
    Vutuv.Ordering.move(schema(socket), socket.assigns.user_id, id, direction)
    {:noreply, load_entries(socket)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <p class="reorder__hint">
        {gettext("Drag to reorder, or use the arrows. The order is the one shown on your profile.")}
      </p>

      <ul id={"reorder-" <> @section} class="reorder" phx-hook="Reorder">
        <li
          :for={{entry, idx} <- Enum.with_index(@entries)}
          id={"reorder-item-" <> entry.id}
          class="reorder__item"
          draggable="true"
          data-id={entry.id}
        >
          <span class="reorder__handle" aria-hidden="true" title={gettext("Drag to reorder")}>⠿</span>

          <div class="reorder__body">
            <.entry_body section={@section} entry={entry} locale={@locale} />
          </div>

          <div class="reorder__move">
            <button
              type="button"
              phx-click="move"
              phx-value-id={entry.id}
              phx-value-dir="up"
              class="reorder__btn"
              disabled={idx == 0}
              aria-label={gettext("Move up")}
            >↑</button>
            <button
              type="button"
              phx-click="move"
              phx-value-id={entry.id}
              phx-value-dir="down"
              class="reorder__btn"
              disabled={idx == length(@entries) - 1}
              aria-label={gettext("Move down")}
            >↓</button>
          </div>

          <.row_actions
            edit_to={edit_path(@slug, @section, entry.id)}
            delete_to={entry_path(@slug, @section, entry.id)}
          />
        </li>
      </ul>
    </div>
    """
  end

  # --- Section-specific row body. One clause per section so the LiveView holds
  # the same identifying facts the read-only card_list shows. ---

  defp entry_body(%{section: "links"} = assigns) do
    ~H"""
    <a class="reorder__thumb" href={linkable_url(@entry.value)}>
      <img
        :if={@entry.screenshot}
        src={Vutuv.Screenshot.url({@entry.screenshot, @entry}, :thumb)}
        alt=""
        width="400"
        height="264"
      />
      <img :if={!@entry.screenshot} src="/images/screenshot.png" alt="" width="400" height="264" />
    </a>
    <div class="reorder__text">
      <div :if={@entry.description} class="reorder__title">{@entry.description}</div>
      <div class="reorder__sub">
        <a href={linkable_url(@entry.value)}>{display_url(@entry.value)}</a>
      </div>
    </div>
    """
  end

  defp entry_body(%{section: "phone_numbers"} = assigns) do
    ~H"""
    <div class="reorder__text">
      <div class="reorder__title">{@entry.value}</div>
      <div class="reorder__sub">{phone_type_label(@entry.number_type)}</div>
    </div>
    """
  end

  defp entry_body(%{section: "addresses"} = assigns) do
    ~H"""
    <div class="reorder__text">
      <div class="reorder__title">{@entry.description}</div>
      <div class="reorder__sub">{format_address(@entry, @locale)}</div>
    </div>
    """
  end

  defp entry_body(%{section: "social_media_accounts"} = assigns) do
    ~H"""
    <div class="reorder__text">
      <div class="reorder__title">{@entry.provider}</div>
      <div class="reorder__sub">{SocialMediaAccount.social_media_link(@entry)}</div>
    </div>
    """
  end

  defp entry_body(%{section: "emails"} = assigns) do
    ~H"""
    <div class="reorder__text">
      <div class="reorder__title">
        {@entry.value}
        <span
          :if={@entry.undeliverable_at}
          class="reorder__warn"
          title={gettext("Mail to this address bounced. Logging in with a PIN sent to it will clear this warning.")}
        >{gettext("Undeliverable")}</span>
      </div>
      <div class="reorder__sub">
        {email_type_label(@entry.email_type)} · {if @entry.public?,
          do: gettext("Public"),
          else: gettext("Private")}
      </div>
    </div>
    """
  end

  defp entry_body(assigns), do: ~H""

  # --- Loading + helpers ---

  defp load_entries(socket) do
    assign(socket, :entries, fetch_entries(socket.assigns.section, socket.assigns.user_id))
  end

  defp fetch_entries(section, user_id) when is_binary(section) and not is_nil(user_id) do
    case Map.get(@schemas, section) do
      nil ->
        []

      schema ->
        from(x in schema, where: x.user_id == ^user_id)
        |> Vutuv.Ordering.by_position()
        |> Repo.all()
    end
  end

  defp fetch_entries(_section, _user_id), do: []

  defp schema(socket), do: Map.fetch!(@schemas, socket.assigns.section)

  # Verified routes need literal path segments, so each section gets its own
  # clause rather than an interpolated `~p"/#{slug}/#{section}/…"`.
  defp edit_path(slug, "links", id), do: ~p"/#{slug}/links/#{id}/edit"
  defp edit_path(slug, "phone_numbers", id), do: ~p"/#{slug}/phone_numbers/#{id}/edit"
  defp edit_path(slug, "addresses", id), do: ~p"/#{slug}/addresses/#{id}/edit"

  defp edit_path(slug, "social_media_accounts", id),
    do: ~p"/#{slug}/social_media_accounts/#{id}/edit"

  defp edit_path(slug, "emails", id), do: ~p"/#{slug}/emails/#{id}/edit"

  defp entry_path(slug, "links", id), do: ~p"/#{slug}/links/#{id}"
  defp entry_path(slug, "phone_numbers", id), do: ~p"/#{slug}/phone_numbers/#{id}"
  defp entry_path(slug, "addresses", id), do: ~p"/#{slug}/addresses/#{id}"
  defp entry_path(slug, "social_media_accounts", id), do: ~p"/#{slug}/social_media_accounts/#{id}"
  defp entry_path(slug, "emails", id), do: ~p"/#{slug}/emails/#{id}"
end
