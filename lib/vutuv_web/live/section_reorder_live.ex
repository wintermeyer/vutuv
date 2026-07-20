defmodule VutuvWeb.SectionReorderLive do
  @moduledoc """
  The owner's drag-and-drop ordering tool for a profile section, embedded into
  the section's (otherwise classic controller) index page via `live_render`,
  the same way the app shell is. It renders only for the page owner — the
  template gates the `live_render` on `@as_owner?` — so visitors and the "View
  as" preview keep the read-only `card_list`.

  One LiveView serves all six orderable sections (phone numbers, addresses,
  social media accounts, email addresses, links and languages — where the order
  additionally means preference, the first language being the member's preferred
  contact language, issue #894); the `section` (the URL segment) and the owner's
  `slug` arrive in the embedded session, the
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
  import VutuvWeb.UI, only: [row_actions: 1, verified_mark: 1]
  import VutuvWeb.UrlHTML, only: [linkable_url: 1, display_url: 1]
  import VutuvWeb.EmailHTML, only: [email_type_label: 1]
  import VutuvWeb.PhoneNumberHTML, only: [phone_type_label: 1]

  import VutuvWeb.LanguageHTML,
    only: [language_name: 1, proficiency_badge: 1, proficiency_label: 1]

  import VutuvWeb.UserHelpers, only: [format_address: 2]

  alias Vutuv.Profiles.SocialMediaAccount
  alias Vutuv.Repo

  # section (= URL segment) => the schema whose rows it orders.
  @schemas %{
    "phone_numbers" => Vutuv.Profiles.PhoneNumber,
    "addresses" => Vutuv.Profiles.Address,
    "social_media_accounts" => Vutuv.Profiles.SocialMediaAccount,
    "emails" => Vutuv.Accounts.Email,
    "links" => Vutuv.Profiles.Url,
    "languages" => Vutuv.Profiles.Language
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
      <p class="reorder__hint">{hint(@section)}</p>

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
            <.entry_body
              section={@section}
              entry={entry}
              locale={@locale}
              preferred?={idx == 0 and length(@entries) > 1}
            />
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
            edit_to={edit_path(@section, entry)}
            delete_to={entry_path(@section, entry)}
          />
        </li>
      </ul>
    </div>
    """
  end

  # The reorder hint. Languages get their own line because their order *means*
  # preference (issue #894); every other section's order is presentational.
  defp hint("languages"),
    do:
      gettext(
        "Drag to reorder, or use the arrows. The first language is your preferred contact language."
      )

  defp hint(_section),
    do: gettext("Drag to reorder, or use the arrows. The order is the one shown on your profile.")

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
      <div class="reorder__sub">
        <span :if={@entry.verified_at} class="inline-flex items-center gap-1 text-emerald-700 dark:text-emerald-300">
          <.verified_mark class="h-3.5 w-3.5" /> {gettext("Verified webpage")}
        </span>
        <.link
          :if={is_nil(@entry.verified_at)}
          navigate={~p"/settings/links/#{@entry}/verify"}
          class="font-semibold text-brand-600 hover:text-brand-700"
        >
          {gettext("Verify this is your page")} →
        </.link>
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

  defp entry_body(%{section: "languages"} = assigns) do
    ~H"""
    <div class="reorder__text">
      <div class="reorder__title">
        {language_name(@entry.language_code)}
        <span
          class="ml-1 inline-flex cursor-help items-center rounded-lg bg-brand-50 px-2 py-0.5 text-xs font-medium text-brand-700 dark:bg-brand-900/40 dark:text-brand-100"
          title={proficiency_label(@entry.proficiency)}
        >
          {proficiency_badge(@entry.proficiency)}
        </span>
      </div>
      <%!-- Order is preference (issue #894): the top entry, once there is a
      choice, is the language this member prefers to be contacted in. --%>
      <div :if={@preferred?} class="reorder__sub">
        {gettext("Preferred contact language")}
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
  # clause rather than an interpolated `~p"/#{slug}/#{section}/…"`. The entry is
  # interpolated whole so `Phoenix.Param` decides the route param: the default
  # is the row id, but `Language` derives it to its ISO code, so languages need
  # no special clause here.
  defp edit_path("links", entry), do: ~p"/settings/links/#{entry}/edit"
  defp edit_path("phone_numbers", entry), do: ~p"/settings/phone_numbers/#{entry}/edit"
  defp edit_path("addresses", entry), do: ~p"/settings/addresses/#{entry}/edit"

  defp edit_path("social_media_accounts", entry),
    do: ~p"/settings/social_media_accounts/#{entry}/edit"

  defp edit_path("emails", entry), do: ~p"/settings/emails/#{entry}/edit"
  defp edit_path("languages", entry), do: ~p"/settings/languages/#{entry}/edit"

  defp entry_path("links", entry), do: ~p"/settings/links/#{entry}"
  defp entry_path("phone_numbers", entry), do: ~p"/settings/phone_numbers/#{entry}"
  defp entry_path("addresses", entry), do: ~p"/settings/addresses/#{entry}"

  defp entry_path("social_media_accounts", entry),
    do: ~p"/settings/social_media_accounts/#{entry}"

  defp entry_path("emails", entry), do: ~p"/settings/emails/#{entry}"
  defp entry_path("languages", entry), do: ~p"/settings/languages/#{entry}"
end
