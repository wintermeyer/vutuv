defmodule VutuvWeb.CVLive do
  @moduledoc """
  The interactive CV builder at `/:slug/cv` (issue #841), embedded by
  `VutuvWeb.CVController.show` via `live_render/3` the same way the profile
  is (so the controller keeps owning the URL and the app shell renders once).

  Public like the profile: the CV is built through the viewer's eyes
  (`VutuvWeb.CV`), so it only ever carries data the viewer can already see.
  The left column is the CV as a set of include/exclude toggles — every
  identity field (name, photo, contact, profile link), every section, and
  every single entry — so a recruiter can drop parts or hit **Anonymize** to
  forward a bias-free CV. The right column (bottom on mobile) is the download
  panel: the current selection is encoded into every download link as
  `?hide=…`, and the `VutuvWeb.CVController` print/download actions honor it.

  Nothing is persisted; the selection lives in the socket and in the links.
  """
  use VutuvWeb, :live_view

  import VutuvWeb.UserHelpers

  alias Vutuv.Accounts
  alias VutuvWeb.ContentPolicy
  alias VutuvWeb.CV
  alias VutuvWeb.Live.InitAssigns

  @impl true
  def mount(_params, session, socket) do
    current_user = InitAssigns.load_user(session["user_id"])
    VutuvWeb.LiveLocale.put_locale(current_user, session)

    user = Accounts.get_user(session["profile_user_id"])
    # Everyone else's CV is public; only the machine-readable JSON Resume is
    # withheld from a fully machine-opted-out member (its URL 404s), matching
    # the agent docs. The owner always gets every format of their own.
    owner? = current_user && current_user.id == user.id
    machine_ok? = owner? || not ContentPolicy.agent_docs_blocked?(user)

    socket =
      socket
      |> assign(:current_user, current_user)
      |> assign(:current_user_id, current_user && current_user.id)
      |> assign(:user, user)
      |> assign(:owner?, owner?)
      |> assign(:machine_ok?, machine_ok?)
      |> assign(:locale, session["locale"])
      |> assign(:shell_path, session["request_path"])
      |> assign(:page_title, gettext("CV"))
      |> assign(:cv, CV.build(user, viewer: current_user, photo: true))
      |> put_hide(MapSet.new())

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle", %{"key" => key}, socket) do
    hide = socket.assigns.hide

    hide =
      if MapSet.member?(hide, key),
        do: MapSet.delete(hide, key),
        else: MapSet.put(hide, key)

    {:noreply, put_hide(socket, hide)}
  end

  def handle_event("anonymize", _params, socket) do
    hide = MapSet.union(socket.assigns.hide, MapSet.new(CV.anonymize_keys()))
    {:noreply, put_hide(socket, hide)}
  end

  def handle_event("reset", _params, socket) do
    {:noreply, put_hide(socket, MapSet.new())}
  end

  # Recompute the download query whenever the selection changes, so every
  # link in the render reflects the current include/exclude set.
  defp put_hide(socket, hide) do
    query = if MapSet.size(hide) == 0, do: %{}, else: %{"hide" => Enum.join(Enum.sort(hide), ",")}

    socket
    |> assign(:hide, hide)
    |> assign(:query, query)
  end

  defp shown?(hide, key), do: not MapSet.member?(hide, key)

  # The identity fields that have a value, as `{key, label, preview}` rows.
  defp identity_rows(cv) do
    for {key, field} <- CV.identity_fields(),
        value = Map.fetch!(cv, field),
        present?(value) do
      {key, identity_label(key), identity_preview(key, value)}
    end
  end

  defp present?(nil), do: false
  defp present?([]), do: false
  defp present?(_value), do: true

  defp identity_label("name"), do: gettext("Name")
  defp identity_label("photo"), do: gettext("Photo")
  # "Tagline" is what the profile basics form calls the headline field.
  defp identity_label("headline"), do: gettext("Tagline")
  defp identity_label("email"), do: gettext("Email address")
  defp identity_label("phone"), do: gettext("Phone number")
  defp identity_label("address"), do: gettext("Address")
  defp identity_label("url"), do: gettext("Profile link")

  # A short preview of the field's value beside its toggle (the photo has no
  # text, so its label carries the meaning).
  defp identity_preview("photo", _value), do: nil
  defp identity_preview("address", lines), do: Enum.join(lines, ", ")
  defp identity_preview(_key, value), do: value

  @formats [
    {"Word (.docx)", "docx"},
    {"OpenDocument (.odt)", "odt"},
    {"HTML", "html"},
    {"LaTeX (.tex)", "tex"}
  ]

  defp download_formats(true), do: @formats ++ [{"JSON Resume", "json"}]
  defp download_formats(false), do: @formats

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-6">
      <div class="mb-4">
        <.link
          navigate={~p"/#{@user}"}
          class="text-sm font-medium text-slate-600 hover:text-brand-700 dark:text-slate-400 dark:hover:text-brand-300"
        >
          ‹ {full_name(@user)}
        </.link>
        <h1 class="mt-1 text-2xl font-bold text-slate-900 dark:text-white">{gettext("CV")}</h1>
      </div>

      <div class="grid gap-6 md:grid-cols-3">
        <div class="min-w-0 space-y-4 md:col-span-2">
          <.card>
            <p class="text-sm text-slate-600 dark:text-slate-400">
              {gettext(
                "Pick what to include. Untick single entries or whole sections, or anonymize the CV by hiding the name, photo and contact details."
              )}
            </p>
            <div class="mt-4 flex flex-wrap gap-2">
              <button
                type="button"
                id="cv-anonymize"
                phx-click="anonymize"
                class="rounded-lg bg-slate-100 px-4 py-2 text-sm font-semibold text-slate-700 hover:bg-slate-200 dark:bg-slate-800 dark:text-slate-200 dark:hover:bg-slate-700"
              >
                {gettext("Anonymize")}
              </button>
              <button
                type="button"
                id="cv-reset"
                phx-click="reset"
                class="text-sm font-semibold text-brand-600 hover:text-brand-700"
              >
                {gettext("Reset")}
              </button>
            </div>
          </.card>

          <.card>
            <.section_title class="mb-3">{gettext("Header")}</.section_title>
            <div class="space-y-1">
              <label
                :for={{key, label, preview} <- identity_rows(@cv)}
                class={[
                  "flex cursor-pointer items-baseline gap-3 rounded-lg px-2 py-1.5",
                  shown?(@hide, key) || "opacity-40"
                ]}
              >
                <input
                  type="checkbox"
                  class={checkbox_class()}
                  checked={shown?(@hide, key)}
                  phx-click="toggle"
                  phx-value-key={key}
                />
                <span class="w-28 shrink-0 text-sm font-medium text-slate-900 dark:text-slate-100">
                  {label}
                </span>
                <span :if={preview} class="min-w-0 truncate text-sm text-slate-600 dark:text-slate-400">
                  {preview}
                </span>
              </label>
            </div>
          </.card>

          <.card :for={section <- @cv.sections}>
            <label class={[
              "flex cursor-pointer items-center gap-3",
              shown?(@hide, section.key) || "opacity-50"
            ]}>
              <input
                type="checkbox"
                class={checkbox_class()}
                checked={shown?(@hide, section.key)}
                phx-click="toggle"
                phx-value-key={section.key}
              />
              <.section_title>{section.heading}</.section_title>
            </label>
            <div class={["mt-3 space-y-2", shown?(@hide, section.key) || "opacity-40"]}>
              <label
                :for={entry <- section.entries}
                class={[
                  "flex cursor-pointer items-baseline gap-3 rounded-lg px-2 py-1.5",
                  shown?(@hide, entry.id) || "line-through opacity-50"
                ]}
              >
                <input
                  type="checkbox"
                  class={checkbox_class()}
                  checked={shown?(@hide, entry.id)}
                  phx-click="toggle"
                  phx-value-key={entry.id}
                />
                <span class="min-w-0">
                  <span class="text-sm font-semibold text-slate-900 dark:text-slate-100">
                    {[entry.title, entry.organization] |> Enum.filter(& &1) |> Enum.join(", ")}
                  </span>
                  <span :if={entry.period} class="ml-2 text-xs text-slate-600 dark:text-slate-400">
                    {entry.period}
                  </span>
                  <span
                    :if={entry.description}
                    class="mt-0.5 block truncate text-xs text-slate-600 dark:text-slate-400"
                  >
                    {entry.description}
                  </span>
                </span>
              </label>
            </div>
          </.card>

          <.card :if={@cv.skills != []}>
            <label class={[
              "flex cursor-pointer items-center gap-3",
              shown?(@hide, "tags") || "opacity-50"
            ]}>
              <input
                type="checkbox"
                class={checkbox_class()}
                checked={shown?(@hide, "tags")}
                phx-click="toggle"
                phx-value-key="tags"
              />
              <.section_title>{gettext("Tags")}</.section_title>
            </label>
            <div class={["mt-3 flex flex-wrap gap-2", shown?(@hide, "tags") || "opacity-40"]}>
              <button
                :for={skill <- @cv.skills}
                type="button"
                phx-click="toggle"
                phx-value-key={skill.id}
                class={[
                  "inline-flex items-center gap-1.5 rounded-lg px-3 py-1.5 text-sm font-medium",
                  if(shown?(@hide, skill.id),
                    do: "bg-brand-50 text-brand-700 dark:bg-brand-900/40 dark:text-brand-100",
                    else: "bg-slate-100 text-slate-400 line-through dark:bg-slate-800"
                  )
                ]}
              >
                {skill.name}
              </button>
            </div>
          </.card>

          <.card :if={@cv.links != []}>
            <label class={[
              "flex cursor-pointer items-center gap-3",
              shown?(@hide, "links") || "opacity-50"
            ]}>
              <input
                type="checkbox"
                class={checkbox_class()}
                checked={shown?(@hide, "links")}
                phx-click="toggle"
                phx-value-key="links"
              />
              <.section_title>{gettext("Links")}</.section_title>
            </label>
            <div class={["mt-3 space-y-1", shown?(@hide, "links") || "opacity-40"]}>
              <label
                :for={link <- @cv.links}
                class={[
                  "flex cursor-pointer items-baseline gap-3 rounded-lg px-2 py-1.5",
                  shown?(@hide, link.id) || "line-through opacity-50"
                ]}
              >
                <input
                  type="checkbox"
                  class={checkbox_class()}
                  checked={shown?(@hide, link.id)}
                  phx-click="toggle"
                  phx-value-key={link.id}
                />
                <span class="min-w-0 truncate text-sm text-slate-700 dark:text-slate-300">
                  <span :if={link.label} class="font-medium">{link.label}: </span>{link.url}
                </span>
              </label>
            </div>
          </.card>
        </div>

        <aside class="space-y-4">
          <.card>
            <.section_title class="mb-1">{gettext("Download")}</.section_title>
            <p class="mb-4 text-xs text-slate-600 dark:text-slate-400">
              {gettext("Every download reflects the parts you selected.")}
            </p>
            <a
              id="cv-print"
              href={~p"/#{@user}/cv/print?#{@query}"}
              target="_blank"
              rel="noopener"
              class="block w-full rounded-lg bg-brand-600 px-4 py-2 text-center text-sm font-semibold text-white hover:bg-brand-700"
            >
              {gettext("Print / Save as PDF")}
            </a>
            <div class="mt-3 grid gap-2">
              <a
                :for={{label, format} <- download_formats(@machine_ok?)}
                id={"cv-download-#{format}"}
                href={~p"/#{@user}/cv/download/#{format}?#{@query}"}
                class="rounded-lg bg-slate-100 px-4 py-2 text-center text-sm font-semibold text-slate-700 hover:bg-slate-200 dark:bg-slate-800 dark:text-slate-200 dark:hover:bg-slate-700"
              >
                {label}
              </a>
            </div>
            <p class="mt-4 text-xs text-slate-600 dark:text-slate-400">
              {gettext(
                "For a PDF, open the print view and choose \"Save as PDF\" in your browser's print dialog. Word and OpenDocument are editable; LaTeX is the typesetting source; JSON Resume is the open jsonresume.org format."
              )}
            </p>
          </.card>
        </aside>
      </div>
    </div>
    """
  end
end
