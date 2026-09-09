defmodule VutuvWeb.PressKitLive do
  @moduledoc """
  The member's press-kit editor (`GET /settings/press`, issue #2085): the two
  shelves `Vutuv.PressKit` holds — up to ten press photos and a handful of logo
  variants — with the upload, the credit, the caption, the order and the
  delete.

  ## The authorization, which is this page's real subject

  `Vutuv.PressKit.create/4` shipped in #2083 with **no production caller** and
  no authorization at all; this is the first caller, so the rule lands here.
  It is asked twice, deliberately:

    * the context refuses outright (`PressKit.manageable_by?/2`, checked inside
      `create/4` before a byte is measured), so no surface can forget it;
    * and every picture this page writes is resolved out of the signed-in
      member's **own** shelves rather than fetched by the id the client sent
      (`owned/2` below). A forged id is therefore not merely refused, it is
      never found — which is the answer that stays true when a later kind of
      viewer is added.

  The signed-in member comes from `VutuvWeb.Live.InitAssigns`, i.e. from the
  cookie's `session_token`, never a bare `session["user_id"]` (#1034/#1036).

  A **page's** press kit is not edited here — that is #2087's surface, on the
  page's own manage menu — but the rule it needs is already written:
  `manageable_by?/2` answers for an owner or a publisher of the page.

  ## Why a LiveView, and why one editor at a time

  The upload travels over the socket (a 30 MB print-quality photo needs a
  progress indicator that is not a spinner), and ordering is the page's other
  job: the first photo is the hero, so a reload per move is absurd. The tiles
  reuse the `.reorder*` tool and its `Reorder` hook — drag for a mouse, the
  arrows for a phone, which is where this page will actually be used.

  Only the **open** tile renders the shared Markdown editor. Ten of them would
  mean ten Milkdown instances on one page; the composer already answers this
  with a per-photo panel (`@open_photo`), and this is that shape.

  ## The rights confirmation is a gate, not a field

  Nothing may be stored without the member confirming that they hold the rights
  and release the file for editorial use with the credit shown — it is what
  allows the file to be handed out at all. So the tick **arms the picker**
  rather than sitting beside it: an unconfirmed upload is prevented rather than
  reported, which on a 30 MB print file is the whole difference. The tick then
  rides into `create/4` as the changeset's own `rights_confirmed`, so a client
  that ignores a disabled input meets the same refusal — one rule, in the place
  that already owns it, rather than a second copy here that nothing could reach
  to test. Each stored row carries its own `rights_confirmed_at`, and every
  later edit of its caption keeps that moment
  (`Vutuv.Images.Image.press_kit_update_changeset/2`).
  """

  use VutuvWeb, :live_view

  alias Vutuv.Images.Image
  alias Vutuv.Moderation.ImageScans
  alias Vutuv.PressKit
  alias Vutuv.PressKitStore
  alias VutuvWeb.ErrorHelpers

  on_mount({VutuvWeb.Live.InitAssigns, :require_login})

  @impl true
  def mount(_params, _session, socket) do
    # `:user` is the press kit's **owner** and `:current_user` the member acting
    # — the same person on this page, and deliberately named apart, because
    # #2087's editor differs from this one in exactly that: there the owner is
    # the page and the viewer one of its staff. `store/3` already passes them as
    # two arguments for that reason.
    user = socket.assigns.current_user

    socket =
      socket
      |> assign(:page_title, gettext("Press photos & logos"))
      |> assign(:user, user)
      # Which tile's edit panel is open; nil = none, which is the whole page for
      # somebody who came here only to upload.
      |> assign(:open, nil)
      # The rights tick, per shelf. Not a form field that rides along with the
      # upload: it is what arms the picker, so it has to exist before a file
      # does. It stays armed while the page is open — a photographer adding five
      # pictures confirms once for that session, and each row still records its
      # own moment. A reconnect is safe: the tick and the credit sit in a form
      # with a `phx-change`, which LiveView's form recovery replays on rejoin.
      |> assign(:armed, %{false => false, true => false})
      # Which ground the logo tiles stand on. A white wordmark is invisible on
      # white, so the shelf that holds one lets the owner look at it on the
      # background it was drawn for. A preview only — nothing about it is stored.
      |> assign(:logo_ground, "light")
      |> assign(:error, nil)
      |> load_shelves()

    {:ok,
     socket
     # The credit the next upload carries, offered ready-filled from the last
     # picture on that shelf and editable before the file is picked. Read off
     # the shelves `load_shelves/1` has just loaded rather than queried again.
     |> assign(:credits, %{
       false => PressKit.last_credit(socket.assigns.photos) || "",
       true => PressKit.last_credit(socket.assigns.logos) || ""
     })
     |> allow_upload(:photo,
       accept: PressKitStore.photo_extensions(),
       max_entries: PressKit.max_photos(),
       max_file_size: PressKit.max_filesize(),
       auto_upload: true,
       progress: &handle_progress/3
     )
     |> allow_upload(:logo,
       accept: PressKitStore.logo_extensions(),
       max_entries: PressKit.max_logos(),
       max_file_size: PressKit.max_filesize(),
       auto_upload: true,
       progress: &handle_progress/3
     )
     |> load_shelves()}
  end

  ## Events

  @impl true
  def handle_event("upload_form", params, socket) do
    logo? = shelf_param(params)

    {:noreply,
     socket
     |> put_in_shelf(:armed, logo?, params["rights"] == "on")
     |> put_in_shelf(:credits, logo?, params["credit"] || credit(socket, logo?))}
  end

  def handle_event("cancel-upload", %{"ref" => ref} = params, socket) do
    name = if shelf_param(params), do: :logo, else: :photo
    {:noreply, cancel_upload(socket, name, ref)}
  end

  def handle_event("open", %{"id" => id}, socket) do
    {:noreply, assign(socket, :open, if(owned(socket, id), do: id))}
  end

  def handle_event("close", _params, socket), do: {:noreply, assign(socket, :open, nil)}

  def handle_event("save", %{"picture_id" => id} = params, socket) do
    case owned(socket, id) do
      nil ->
        {:noreply, socket}

      image ->
        case PressKit.update(image, socket.assigns.current_user, params["picture"] || %{}) do
          {:ok, _image} ->
            {:noreply, socket |> assign(:open, nil) |> assign(:error, nil) |> load_shelves()}

          {:error, changeset} ->
            {:noreply, assign(socket, :error, first_error(changeset))}
        end
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case owned(socket, id) do
      nil ->
        {:noreply, socket}

      image ->
        :ok = PressKit.delete(image)

        {:noreply,
         socket
         |> assign(:open, nil)
         |> assign(:error, nil)
         |> load_shelves()
         |> put_flash(:info, gettext("Picture removed."))}
    end
  end

  def handle_event("move", %{"id" => id, "dir" => dir}, socket) when dir in ["up", "down"] do
    case owned(socket, id) do
      nil ->
        {:noreply, socket}

      image ->
        direction = if dir == "up", do: :up, else: :down
        viewer = socket.assigns.current_user
        PressKit.move(socket.assigns.user, viewer, Image.logo?(image), id, direction)
        {:noreply, load_shelves(socket)}
    end
  end

  # The drag hook pushes the whole order. Trust nothing in it: `PressKit.reorder/3`
  # keeps only ids that are on this member's own shelf and appends whatever the
  # client left out, so a stale or forged payload can rearrange the shelf but
  # never bring a foreign picture onto it.
  def handle_event("reorder_photos", %{"order" => order}, socket) when is_list(order),
    do: {:noreply, reorder(socket, false, order)}

  def handle_event("reorder_logos", %{"order" => order}, socket) when is_list(order),
    do: {:noreply, reorder(socket, true, order)}

  def handle_event("logo_ground", %{"ground" => ground}, socket) when ground in ~w(light dark),
    do: {:noreply, assign(socket, :logo_ground, ground)}

  # A form with a `phx-change` and no submit still submits on Return, and the
  # credit input is one Return away from the drop zone on a phone keyboard.
  # Named rather than a catch-all: a catch-all also swallows a renamed event,
  # which leaves a dead button and a green test.
  def handle_event("noop", _params, socket), do: {:noreply, socket}

  ## Writing

  defp reorder(socket, logo?, order) do
    PressKit.reorder(socket.assigns.user, socket.assigns.current_user, logo?, order)
    load_shelves(socket)
  end

  # Every write on this page starts here: the picture is looked up **in the
  # signed-in member's own shelves**, not by the id the client sent, so a
  # foreign or stale id resolves to nothing. Two shelves of at most ten and
  # five, already loaded, so this is a list walk rather than a query.
  defp owned(socket, id) do
    Enum.find(socket.assigns.photos ++ socket.assigns.logos, &(&1.id == id))
  end

  defp load_shelves(socket) do
    user = socket.assigns.user

    socket
    |> assign(:photos, PressKit.photos(user))
    |> assign(:logos, PressKit.logos(user))
  end

  # `auto_upload: true`, so this runs the moment the last chunk lands.
  defp handle_progress(name, entry, socket) when name in [:photo, :logo] do
    if entry.done?, do: store(socket, entry, name == :logo), else: {:noreply, socket}
  end

  defp store(socket, entry, logo?) do
    # The tick rides in as the changeset's own `rights_confirmed`, rather than
    # being asked a second time here: the picker being disabled is what a member
    # meets, and the changeset is what a crafted client meets. One rule, in the
    # place that already owns it, instead of a copy on this page that nothing
    # could reach to test.
    attrs = %{
      "logo" => logo?,
      "credit" => credit(socket, logo?),
      "rights_confirmed" => socket.assigns.armed[logo?]
    }

    result =
      consume_uploaded_entry(socket, entry, fn %{path: path} ->
        {:ok,
         PressKit.create(
           socket.assigns.user,
           socket.assigns.current_user,
           {path, entry.client_name},
           attrs
         )}
      end)

    case result do
      {:ok, _image} ->
        {:noreply, socket |> assign(:error, nil) |> load_shelves()}

      {:error, reason} ->
        {:noreply, assign(socket, :error, store_error(reason, logo?))}
    end
  end

  defp store_error(:too_many, true),
    do: gettext("No more than %{max} logo variants.", max: compact_count(PressKit.max_logos()))

  defp store_error(:too_many, false),
    do: gettext("No more than %{max} press photos.", max: compact_count(PressKit.max_photos()))

  # Defensive: `allow_upload/3` is configured with the same cap, so LiveView
  # refuses an oversized file before this can see it. The wording is the shared
  # one either way, so the two gates cannot answer differently.
  defp store_error(:too_large, _logo?),
    do:
      gettext("That file is larger than %{limit}. Please upload a smaller one.",
        limit: megabyte_label(PressKit.max_filesize())
      )

  defp store_error(:forbidden, _logo?),
    do: gettext("You cannot add a picture to this press kit.")

  defp store_error(%Ecto.Changeset{errors: errors} = changeset, _logo?) do
    if Keyword.has_key?(errors, :rights_confirmed),
      do: gettext("Please confirm the rights first, then choose the file."),
      else: first_error(changeset)
  end

  defp store_error(_reason, _logo?), do: gettext("That file could not be processed.")

  # `ErrorHelpers.changeset_messages/1` rather than a traverse of our own: it
  # translates and interpolates, where a bare `{message, _opts}` hands the
  # member the raw msgid with a live `%{count}` in it.
  defp first_error(%Ecto.Changeset{} = changeset) do
    changeset
    |> ErrorHelpers.changeset_messages()
    |> List.first()
    |> Kernel.||(gettext("That could not be saved."))
  end

  ## Shelf state

  defp shelf_param(%{"shelf" => "logo"}), do: true
  defp shelf_param(_params), do: false

  defp put_in_shelf(socket, key, logo?, value),
    do: assign(socket, key, Map.put(socket.assigns[key], logo?, value))

  defp credit(socket, logo?), do: socket.assigns.credits[logo?]

  ## Rendering

  @impl true
  def render(assigns) do
    ~H"""
    <.settings_shell user={@user} active={:press} title={gettext("Press photos & logos")}>
      <div class="space-y-6">
        <.card>
          <p class="text-sm text-slate-600 dark:text-slate-400">
            {gettext(
              "What a journalist writing about you may download: photos in print quality and your logo as a file. Everything here is public and free for editorial use as long as your credit is shown."
            )}
          </p>
        </.card>

        <.error_banner :if={@error} id="press-error">{@error}</.error_banner>

        <.shelf
          user={@user}
          logo?={false}
          images={@photos}
          upload={@uploads.photo}
          armed?={@armed[false]}
          credit={@credits[false]}
          open={@open}
        />

        <.shelf
          user={@user}
          logo?={true}
          images={@logos}
          upload={@uploads.logo}
          armed?={@armed[true]}
          credit={@credits[true]}
          open={@open}
          logo_ground={@logo_ground}
        />
      </div>
    </.settings_shell>
    """
  end

  attr(:user, :any, required: true)
  attr(:logo?, :boolean, required: true)
  attr(:images, :list, required: true)
  attr(:upload, :any, required: true)
  attr(:armed?, :boolean, required: true)
  attr(:credit, :string, required: true)
  attr(:open, :string, default: nil)

  # Only the logo shelf passes one, so `@logo_ground` never enters the photo
  # tiles' comprehension — a comprehension tracks no per-entry change, so
  # pressing Light/Dark would otherwise re-send every photo tile's dynamics too.
  attr(:logo_ground, :string, default: "light")

  defp shelf(assigns) do
    # `assign/3` and deliberately not `Map.put/3`: the count changes with every
    # upload and delete, and a `Map.put` key carries no change mark, so the
    # counter and the "shelf is full" line would keep the value they were first
    # rendered with — measured as "0 of 1" beside a tile that was plainly there.
    assigns = assign(assigns, :count, length(assigns.images))

    ~H"""
    <.card data-press-shelf={PressKit.shelf_name(@logo?)}>
      <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
        <.section_title>
          {if @logo?, do: gettext("Logo variants"), else: gettext("Press photos")}
        </.section_title>
        <%!-- Counted, not spelled out: `compact_count/1` is what every number a
        member reads goes through, and a cap that an installation raised past a
        thousand still reads at a glance. --%>
        <span
          data-press-count={PressKit.shelf_name(@logo?)}
          class="text-sm tabular-nums text-slate-600 dark:text-slate-400"
        >
          {gettext("%{used} of %{max}",
            used: compact_count(@count),
            max: compact_count(shelf_max(@logo?))
          )}
        </span>
      </div>

      <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">
        {if @logo?,
          do:
            gettext(
              "Your logo as a file, one tile per variant. A vector (SVG) is what a printer asks for; a PNG is what everybody else can open."
            ),
          else:
            gettext(
              "The first photo is the one shown first. Drag a tile, or use the arrows, to change the order."
            )}
      </p>

      <%!-- The light/dark switch, on the logo shelf alone: a white wordmark on
      a white card is an empty tile, and the only way to see that it is there is
      to put it on the ground it was drawn for. --%>
      <div :if={@logo? and @images != []} class="mt-3 flex flex-wrap items-center gap-2">
        <span class="text-sm text-slate-600 dark:text-slate-400">{gettext("Show tiles on:")}</span>
        <.button
          :for={{ground, label} <- [{"light", gettext("Light")}, {"dark", gettext("Dark")}]}
          type="button"
          variant={if @logo_ground == ground, do: "primary", else: "secondary"}
          phx-click="logo_ground"
          phx-value-ground={ground}
          data-logo-ground={ground}
          aria-pressed={to_string(@logo_ground == ground)}
        >
          {label}
        </.button>
      </div>

      <p :if={@images == []} class="mt-3 text-sm text-slate-600 dark:text-slate-400">
        {if @logo?,
          do: gettext("No logo here yet."),
          else: gettext("No press photo here yet.")}
      </p>

      <ul
        :if={@images != []}
        id={"press-order-#{PressKit.shelf_name(@logo?)}"}
        class="reorder mt-4"
        phx-hook="Reorder"
        data-reorder-event={"reorder_#{PressKit.shelf_name(@logo?)}s"}
      >
        <.tile
          :for={{image, index} <- Enum.with_index(@images)}
          user={@user}
          image={image}
          index={index}
          last?={index == @count - 1}
          open?={@open == image.id}
          logo_ground={@logo_ground}
        />
      </ul>

      <.add_form
        :if={@count < shelf_max(@logo?)}
        logo?={@logo?}
        upload={@upload}
        armed?={@armed?}
        credit={@credit}
      />

      <p
        :if={@count >= shelf_max(@logo?)}
        data-press-full={PressKit.shelf_name(@logo?)}
        class="mt-4 text-sm text-slate-600 dark:text-slate-400"
      >
        {gettext("This shelf is full. Remove one picture to add another.")}
      </p>
    </.card>
    """
  end

  attr(:user, :any, required: true)
  attr(:image, :any, required: true)
  attr(:index, :integer, required: true)
  attr(:last?, :boolean, required: true)
  attr(:open?, :boolean, required: true)
  attr(:logo_ground, :string, required: true)

  defp tile(assigns) do
    ~H"""
    <li
      id={"press-tile-#{@image.id}"}
      class="reorder__item"
      draggable="true"
      data-id={@image.id}
      data-press-picture={@image.id}
    >
      <%!-- `data-reorder-handle` is not decoration: an open tile holds two text
      inputs and the Markdown editor's contenteditable, and a draggable ancestor
      turns selecting a caption into a drag of the whole row. The shared hook
      arms the row only while the pointer is on this grip, and takes ↑/↓ from
      the keyboard there. --%>
      <span
        class="reorder__handle"
        data-reorder-handle
        aria-hidden="true"
        title={gettext("Drag to reorder")}
      >
        ⠿
      </span>

      <div class="reorder__body">
        <%!-- The tile keeps the picture's own shape rather than a square crop:
        this page is where the owner checks what a journalist will get, and a
        crop is not it. A logo stands on the ground the switch above chose. --%>
        <span class={[
          "relative block w-24 shrink-0 overflow-hidden rounded-md ring-1 ring-slate-200 sm:w-32 dark:ring-slate-700",
          Image.logo?(@image) && if(@logo_ground == "dark", do: "bg-slate-900", else: "bg-white")
        ]}>
          <%!-- The stored dimensions ride along so the browser reserves the
          tile's height before a lazy thumbnail arrives; without them a shelf of
          ten tiles is ten hairlines that grow one after the other. --%>
          <img
            src={PressKit.url(@image, tile_version(@image))}
            alt={@image.alt || ""}
            width={@image.width}
            height={@image.height}
            loading="lazy"
            class="block h-auto w-full"
          />
          <%!-- A status, not a control, so it sits on the picture and never in
          the row of buttons beside it. The owner sees the real picture while
          it waits; a stranger meets the pixelated stand-in (#2084). --%>
          <.checking_badge :if={pending?(@image)} class="absolute bottom-1 left-1" />
        </span>

        <div class="reorder__text">
          <div class="reorder__title">
            {tile_title(@image)}
          </div>
          <div :if={@index == 0} class="reorder__sub" data-press-hero>
            {if Image.logo?(@image),
              do: gettext("First: the main variant"),
              else: gettext("First: the main photo")}
          </div>
          <div :if={@image.credit not in [nil, ""]} class="reorder__sub">{@image.credit}</div>
        </div>
      </div>

      <div class="reorder__move">
        <button
          type="button"
          phx-click="move"
          phx-value-id={@image.id}
          phx-value-dir="up"
          class="reorder__btn"
          disabled={@index == 0}
          aria-label={gettext("Move up")}
        >
          ↑
        </button>
        <button
          type="button"
          phx-click="move"
          phx-value-id={@image.id}
          phx-value-dir="down"
          class="reorder__btn"
          disabled={@last?}
          aria-label={gettext("Move down")}
        >
          ↓
        </button>
      </div>

      <div class="flex flex-wrap items-center gap-2">
        <.button
          type="button"
          variant="secondary"
          phx-click={if @open?, do: "close", else: "open"}
          phx-value-id={@image.id}
          aria-expanded={to_string(@open?)}
          aria-controls={"press-panel-#{@image.id}"}
        >
          {if @open?, do: gettext("Done"), else: gettext("Edit")}
        </.button>
        <.button
          type="button"
          variant="danger-ghost"
          phx-click="delete"
          phx-value-id={@image.id}
          data-confirm={gettext("Remove this picture from your press kit?")}
        >
          {gettext("Remove")}
        </.button>
      </div>

      <%!-- The panel is a full-width row of the tile (`basis-full`), so opening
      it never reflows the controls above it. Only the open tile renders the
      Markdown editor: ten of them would be ten editor instances on one page. --%>
      <div :if={@open?} id={"press-panel-#{@image.id}"} class="basis-full">
        <.form for={%{}} id={"press-form-#{@image.id}"} phx-submit="save" class="space-y-3 pt-2">
          <input type="hidden" name="picture_id" value={@image.id} />

          <div>
            <label
              for={"press-label-#{@image.id}"}
              class="block text-sm font-medium text-slate-700 dark:text-slate-300"
            >
              {if Image.logo?(@image),
                do: gettext("Which variant this is"),
                else: gettext("What the picture shows")}
            </label>
            <input
              type="text"
              id={"press-label-#{@image.id}"}
              name="picture[alt]"
              value={@image.alt}
              maxlength="255"
              class={[input_class(), "mt-1"]}
              placeholder={
                if Image.logo?(@image),
                  do: gettext("White on a dark background"),
                  else: gettext("At the desk in the Bonn office")
              }
            />
          </div>

          <div>
            <label
              for={"press-credit-#{@image.id}"}
              class="block text-sm font-medium text-slate-700 dark:text-slate-300"
            >
              {gettext("Credit")}
            </label>
            <input
              type="text"
              id={"press-credit-#{@image.id}"}
              name="picture[credit]"
              value={@image.credit}
              maxlength="255"
              class={[input_class(), "mt-1"]}
              placeholder={gettext("Photo: Ada King")}
            />
            <p class="mt-1 text-xs text-slate-600 dark:text-slate-400">
              {gettext("Shown beside the picture and asked for with every download.")}
            </p>
          </div>

          <div :if={not Image.logo?(@image)}>
            <.markdown_editor
              id={"press-caption-#{@image.id}"}
              name="picture[caption]"
              user={@user}
              value={@image.caption || ""}
              label={gettext("Caption")}
              placeholder={gettext("Who took it, where, and what may be cropped.")}
              rows={4}
              help
            />
            <p class="mt-1 text-xs text-slate-600 dark:text-slate-400">
              {gettext("A photographer's @handle links to their profile and notifies nobody.")}
            </p>
          </div>

          <div class="flex flex-wrap gap-2">
            <.button type="submit">{gettext("Save")}</.button>
            <.button type="button" variant="ghost" phx-click="close">{gettext("Cancel")}</.button>
          </div>
        </.form>
      </div>
    </li>
    """
  end

  attr(:logo?, :boolean, required: true)
  attr(:upload, :any, required: true)
  attr(:armed?, :boolean, required: true)
  attr(:credit, :string, required: true)

  defp add_form(assigns) do
    assigns = Map.put(assigns, :shelf, PressKit.shelf_name(assigns.logo?))

    ~H"""
    <form
      id={"press-add-#{@shelf}"}
      phx-change="upload_form"
      phx-submit="noop"
      class="mt-4 space-y-3"
    >
      <input type="hidden" name="shelf" value={@shelf} />

      <div>
        <label
          for={"press-new-credit-#{@shelf}"}
          class="block text-sm font-medium text-slate-700 dark:text-slate-300"
        >
          {gettext("Credit")}
        </label>
        <input
          type="text"
          id={"press-new-credit-#{@shelf}"}
          name="credit"
          value={@credit}
          maxlength="255"
          phx-debounce="300"
          class={[input_class(), "mt-1"]}
          placeholder={gettext("Photo: Ada King")}
        />
      </div>

      <label class="flex items-start gap-2 text-sm text-slate-700 dark:text-slate-300">
        <input
          type="checkbox"
          name="rights"
          checked={@armed?}
          data-press-rights={@shelf}
          class={checkbox_class()}
        />
        <span>
          {gettext(
            "I hold the rights to this file and release it for editorial use, as long as the credit above is shown."
          )}
        </span>
      </label>

      <%!-- A `<label>` around the input, so the picker opens with no JavaScript
      at all. The rights tick arms **both** ways in: the input is disabled and
      `phx-drop-target` is withheld, so a drop cannot upload 30 MB that the
      changeset would then refuse. The focus ring rides the wrapper, since the
      input a keyboard reaches is visually hidden. --%>
      <label
        data-press-dropzone={@shelf}
        phx-drop-target={@armed? && @upload.ref}
        class={[
          "flex flex-col items-center justify-center gap-2 rounded-xl border-2 border-dashed px-6 py-8 text-center",
          "has-[:focus-visible]:border-brand-500 has-[:focus-visible]:ring-2 has-[:focus-visible]:ring-brand-500",
          @armed? &&
            "cursor-pointer border-slate-300 bg-slate-50 hover:border-brand-400 hover:bg-brand-50 dark:border-slate-700 dark:bg-slate-800/50 dark:hover:border-brand-500 dark:hover:bg-slate-800",
          !@armed? &&
            "cursor-not-allowed border-slate-200 bg-slate-50 opacity-60 dark:border-slate-800 dark:bg-slate-900"
        ]}
      >
        <span class="text-sm font-medium text-slate-700 dark:text-slate-200">
          {if @logo?,
            do: gettext("Add a logo variant"),
            else: gettext("Add a press photo")}
        </span>
        <%!-- Both halves derived: a whitelist differs per installation (SVG
        needs librsvg in libvips), and a hint naming a format the box then
        refuses is worse than no hint. --%>
        <span class="text-xs text-slate-600 dark:text-slate-400">
          {gettext("%{formats}, up to %{limit}",
            formats: format_list(PressKitStore.extension_whitelist(@logo?)),
            limit: megabyte_label(PressKit.max_filesize())
          )}
        </span>
        <.live_file_input upload={@upload} disabled={not @armed?} class="sr-only" />
      </label>

      <.upload_problems upload={@upload} />

      <div
        :for={entry <- @upload.entries}
        class="flex items-center gap-3 text-sm text-slate-600 dark:text-slate-400"
        data-press-progress={entry.ref}
      >
        <%!-- A ring rather than a bar: the file is a picture, the tile it will
        become is square-ish, and a 30 MB upload on a phone is long enough that
        the shape of the wait matters. Drawn from `pathLength`, so the dash
        length IS the percentage and no CSS of its own is needed — which also
        means nothing here can meet an older release's stylesheet. --%>
        <svg viewBox="0 0 24 24" class="h-8 w-8 shrink-0 -rotate-90" aria-hidden="true">
          <circle cx="12" cy="12" r="10" fill="none" stroke="currentColor" stroke-width="3" class="text-slate-200 dark:text-slate-700" />
          <circle
            cx="12"
            cy="12"
            r="10"
            fill="none"
            stroke="currentColor"
            stroke-width="3"
            stroke-linecap="round"
            pathLength="100"
            stroke-dasharray={"#{entry.progress} 100"}
            class="text-brand-600 dark:text-brand-400"
          />
        </svg>
        <span class="truncate">{entry.client_name}</span>
        <span class="tabular-nums" role="status" aria-live="polite">
          {gettext("%{percent}%", percent: compact_count(entry.progress))}
        </span>
        <button
          type="button"
          phx-click="cancel-upload"
          phx-value-ref={entry.ref}
          phx-value-shelf={@shelf}
          class="reorder__btn"
          aria-label={gettext("Cancel upload")}
        >
          ✕
        </button>
      </div>
    </form>
    """
  end

  ## View helpers

  defp shelf_max(true), do: PressKit.max_logos()
  defp shelf_max(false), do: PressKit.max_photos()

  # A logo's `thumb` is scaled down whole; a photo's is a square crop, so its
  # tile takes `lite` — the cheap version, which is what this page's ten tiles
  # should cost on the phone they are uploaded from.
  defp tile_version(image), do: if(Image.logo?(image), do: "thumb", else: "lite")

  defp pending?(image), do: not ImageScans.released?(image.moderation)

  defp tile_title(image) do
    case image.alt do
      label when is_binary(label) and label != "" ->
        label

      _none ->
        if Image.logo?(image), do: gettext("Logo variant"), else: gettext("Press photo")
    end
  end
end
