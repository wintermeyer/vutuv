defmodule VutuvWeb.PressKitLive do
  @moduledoc """
  The press-kit editor: the two shelves `Vutuv.PressKit` holds — up to ten press
  photos and a handful of logo variants — with the upload, the credit, the
  caption, the order and the delete.

  ## Two hosts, one editor

  A member's own kit is at `GET /settings/media-kit` (issue #2085), routed inside the
  `:default` live_session, where `VutuvWeb.Live.InitAssigns` has already resolved
  the viewer and `:settings_pipe` has already turned an anonymous request away.
  A **page's** kit is at `GET /organizations/:slug/media-kit/edit` (issue #2087),
  embedded by `VutuvWeb.OrganizationController` — off the router, so no
  `on_mount` hook runs at all and `mount/3` resolves the viewer itself
  (`InitAssigns.assign_embedded/2`) and re-asks the role on the socket
  (`VutuvWeb.OrganizationLive.ManageGate`), because the `organization_id` in the
  curated session map is signed, not encrypted, and outlives a withdrawn role.

  What that split costs is exactly two things: the chrome (the settings shell
  against the page's manage tab bar) and the handful of sentences whose German
  addresses the reader as the owner — `Vutuv.PressKit` itself has taken an owner
  since #2083, so the shelves, the events and the writes are the same code for
  both. Two assigns keep it honest: `:owner` is whose kit this is, `:current_user`
  the member acting, and every write passes both.

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

  `manageable_by?/2` is what the page's editor is gated on as well — an owner or
  a publisher — asked by the controller for the request, by `ManageGate` for the
  socket, and by every write for the event.

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

  import VutuvWeb.OrganizationComponents, only: [manage_header: 1]

  alias Vutuv.Accounts.User
  alias Vutuv.Images.Image
  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Organizations.Organization
  alias Vutuv.PressKit
  alias Vutuv.PressKitStore
  alias VutuvWeb.ErrorHelpers
  alias VutuvWeb.Live.InitAssigns
  alias VutuvWeb.OrganizationLive.ManageGate

  @impl true
  def mount(_params, session, socket) do
    if session["organization_id"],
      do: mount_page(socket, session),
      else: mount_member(socket)
  end

  # The routed half. `Live.InitAssigns` has already resolved the viewer from the
  # session token, and `:settings_pipe` has already refused the anonymous
  # request that produced this page — the redirect below is the socket's own
  # copy of that refusal, which used to be the module's `:require_login`
  # on_mount and cannot be one any more: a hook reading `current_user` raises on
  # the embedded mount, where nothing has assigned it yet.
  defp mount_member(socket) do
    case socket.assigns[:current_user] do
      %User{} = user ->
        {:ok, editor(socket, user)}

      _anonymous ->
        {:ok,
         socket
         |> put_flash(:error, gettext("You must be logged in to access that page"))
         |> redirect(to: ~p"/login")}
    end
  end

  # The embedded half (#2087). The viewer comes from the cookie's session token
  # like everywhere else, and the role is re-asked here rather than trusted from
  # the controller's signed map — `ManageGate` says why, and takes the very
  # predicate the controller passed.
  defp mount_page(socket, session) do
    socket = InitAssigns.assign_embedded(socket, session)

    case ManageGate.allow(socket, session, &PressKit.manageable_by?/2) do
      {:ok, organization} -> {:ok, editor(socket, organization)}
      {:refused, socket} -> {:ok, socket}
    end
  end

  # Everything below this line is the same editor for both owners: `:owner` is
  # whose kit it is, `:current_user` the member acting. They are the same person
  # on `/settings/media-kit` and deliberately named apart, because on a page's
  # editor they are not — `PressKit.create/4` has taken them as two arguments
  # since #2083 for exactly that reason.
  defp editor(socket, owner) do
    socket =
      socket
      |> assign(:page_title, gettext("Media Kit"))
      |> assign(:owner, owner)
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
      # Which bio's editor is open; nil = none (issue #2101). Its own assign
      # rather than a value of `:open`, because the two panels answer different
      # events and a member may perfectly well have a tile open while they
      # reread their bio. `:typing_words` is the live count of the one being
      # written, deliberately apart from the stored counts in `:bio_words` so
      # that abandoning an edit undoes itself without a query.
      |> assign(:open_bio, nil)
      |> assign(:typing_words, nil)
      # Whether the page's own logo may be taken onto the logo shelf (#2087).
      # Once, here, and not in the shelf's markup: the answer is a `Path.wildcard`
      # on disk, it cannot change from this page (a page's logo is uploaded on
      # its Edit form), and an attribute in a component call is rebuilt whenever
      # any assign that call reads changes — which for the add form is every
      # debounced keystroke in the credit field and every upload chunk.
      |> assign(:adopt_logo?, PressKit.page_logo_source(owner) != nil)
      |> load_shelves()
      |> load_bio()

    socket
    # The credit the next upload carries, offered ready-filled and editable
    # before the file is picked: the last picture on that shelf, or the owner's
    # own name where the shelf is empty (`PressKit.credit_default/2` says why).
    # Read off the shelves `load_shelves/1` has just loaded rather than queried
    # again.
    |> assign(:credits, %{
      false => PressKit.credit_default(owner, socket.assigns.photos),
      true => PressKit.credit_default(owner, socket.assigns.logos)
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

          # Every reason this write can be refused, not the changeset alone:
          # `update/3` asks the same `manageable_by?/2` every other write asks,
          # and answers `{:error, :forbidden}` — which is not a changeset, and
          # took the socket down with a `FunctionClauseError` when it reached
          # `first_error/1`. `write_error/2` is the one vocabulary all three
          # writers share.
          {:error, reason} ->
            {:noreply, assign(socket, :error, write_error(reason, Image.logo?(image)))}
        end
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    # Re-asked here, per event, because `PressKit.delete/1` cannot ask: #2084's
    # AI rejection calls it with no viewer at all. While a kit's owner *was* its
    # viewer, resolving the row out of `owned/2` was the check; on a page's kit
    # it is not, and this is the irreversible write — `Images.purge/1` drops the
    # row, every served version and the private original, and nothing derives a
    # print file back. A withdrawn role therefore bites on the next press rather
    # than at the next mount.
    with %Image{} = image <- owned(socket, id),
         true <- PressKit.manageable_by?(socket.assigns.owner, socket.assigns.current_user) do
      :ok = PressKit.delete(image)

      {:noreply,
       socket
       |> assign(:open, nil)
       |> assign(:error, nil)
       |> load_shelves()
       |> put_flash(:info, gettext("Picture removed."))}
    else
      # Silent and unchanged, the way a refused `move` or `reorder` already
      # answers: the shelf is reloaded, so the page shows what is really there.
      _refused -> {:noreply, load_shelves(socket)}
    end
  end

  def handle_event("move", %{"id" => id, "dir" => dir}, socket) when dir in ["up", "down"] do
    case owned(socket, id) do
      nil ->
        {:noreply, socket}

      image ->
        direction = if dir == "up", do: :up, else: :down
        viewer = socket.assigns.current_user
        PressKit.move(socket.assigns.owner, viewer, Image.logo?(image), id, direction)
        {:noreply, load_shelves(socket)}
    end
  end

  # The drag hook pushes the whole order. Trust nothing in it: `PressKit.reorder/4`
  # keeps only ids that are on this member's own shelf and appends whatever the
  # client left out, so a stale or forged payload can rearrange the shelf but
  # never bring a foreign picture onto it.
  def handle_event("reorder_photos", %{"order" => order}, socket) when is_list(order),
    do: {:noreply, reorder(socket, false, order)}

  def handle_event("reorder_logos", %{"order" => order}, socket) when is_list(order),
    do: {:noreply, reorder(socket, true, order)}

  def handle_event("logo_ground", %{"ground" => ground}, socket) when ground in ~w(light dark),
    do: {:noreply, assign(socket, :logo_ground, ground)}

  # The page's own logo onto its logo shelf (#2087). Nothing about it is a
  # shortcut past `create/4`: the same authorization, cap, whitelist, rights
  # stamp and AI scan, with the stored file standing in for the picked one.
  def handle_event("adopt_logo", _params, socket) do
    socket.assigns.owner
    |> PressKit.adopt_page_logo(socket.assigns.current_user, shelf_attrs(socket, true))
    |> then(&stored(socket, &1, true))
  end

  ## The three bios (issue #2101)

  def handle_event("open_bio", %{"length" => length}, socket),
    do:
      {:noreply,
       socket |> assign(:open_bio, PressKit.bio_length(length)) |> assign(:typing_words, nil)}

  # Cancel wrote nothing, so the stored counts in `:bio_words` are still right
  # and there is nothing to read back: dropping the live count is the whole undo.
  def handle_event("close_bio", _params, socket),
    do: {:noreply, socket |> assign(:open_bio, nil) |> assign(:typing_words, nil)}

  # The counter while a member types, kept apart from the stored counts so that
  # abandoning an edit needs no query. Which bio it is about comes from the
  # form's own hidden field, like `save_bio` — the assign would be a second,
  # disagreeing answer to the same question.
  def handle_event("bio_typing", %{"length" => length} = params, socket) do
    case PressKit.bio_length(length) do
      nil -> {:noreply, socket}
      _key -> {:noreply, assign(socket, :typing_words, PressKit.bio_word_count(bio_text(params)))}
    end
  end

  def handle_event("save_bio", %{"length" => length} = params, socket) do
    case PressKit.bio_length(length) do
      nil ->
        {:noreply, socket}

      key ->
        save_bio(socket, key, bio_text(params))
    end
  end

  # A form with a `phx-change` and no submit still submits on Return, and the
  # credit input is one Return away from the drop zone on a phone keyboard.
  # Named rather than a catch-all: a catch-all also swallows a renamed event,
  # which leaves a dead button and a green test.
  def handle_event("noop", _params, socket), do: {:noreply, socket}

  ## Writing

  defp reorder(socket, logo?, order) do
    PressKit.reorder(socket.assigns.owner, socket.assigns.current_user, logo?, order)
    load_shelves(socket)
  end

  # Every write on this page starts here: the picture is looked up **in the
  # signed-in member's own shelves**, not by the id the client sent, so a
  # foreign or stale id resolves to nothing. Two shelves of at most ten and
  # five, already loaded, so this is a list walk rather than a query.
  defp owned(socket, id) do
    Enum.find(socket.assigns.photos ++ socket.assigns.logos, &(&1.id == id))
  end

  # One query for both shelves, not one per shelf: this runs on mount and again
  # after every save, delete, move, reorder and upload, and the whole kit is at
  # most fifteen rows.
  defp load_shelves(socket) do
    shelves = PressKit.shelves(socket.assigns.owner)

    socket
    |> assign(:photos, shelves.photos)
    |> assign(:logos, shelves.logos)
  end

  # What the open editor submitted. The Markdown editor's real field is a plain
  # textarea, so this is an ordinary form value and an absent one is the empty
  # string — a member who cleared the box means to clear the bio.
  defp bio_text(params), do: get_in(params, ["bio", "text"]) || ""

  # Every write asks `manageable_by?/2` again, on this event rather than at
  # mount. A refused write is silent and closes the panel, the way a refused
  # move or reorder already answers: the only viewer who can reach it is one
  # whose right to write was taken away while this page sat open, and telling
  # them so needs a sentence for a case nobody honest meets. A refused
  # **changeset** does get its say, through the one `first_error/1` every other
  # form on this page reports with.
  defp save_bio(socket, key, text) do
    case PressKit.save_bio(socket.assigns.owner, socket.assigns.current_user, %{key => text}) do
      {:ok, bio} ->
        # The row we were just handed, rather than a second read of it: only
        # `key` can have changed, and the count for it is already on screen.
        {:noreply,
         socket
         |> assign(:error, nil)
         |> assign(:open_bio, nil)
         |> assign(:typing_words, nil)
         |> put_bio(bio, key)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :error, first_error(changeset))}

      {:error, _forbidden} ->
        {:noreply, socket |> assign(:open_bio, nil) |> assign(:typing_words, nil)}
    end
  end

  # The three bios and, beside them, how many words a reader would count in
  # each (issue #2101). The counts are derived here rather than in the markup:
  # each one flattens Markdown through Earmark, and the card re-renders on every
  # keystroke while a bio is open — three flattenings per keystroke for two
  # texts nobody is typing in.
  defp load_bio(socket) do
    bio = PressKit.bio(socket.assigns.owner)

    socket
    |> assign(:bio, bio)
    |> assign(:bio_words, Map.new(PressKit.bio_lengths(), &{&1, count_of(bio, &1)}))
  end

  # After a save, only the length that was written needs recounting.
  defp put_bio(socket, bio, key) do
    socket
    |> assign(:bio, bio)
    |> update(:bio_words, &Map.put(&1, key, count_of(bio, key)))
  end

  defp count_of(bio, length), do: PressKit.bio_word_count(Map.fetch!(bio, length))

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
    attrs = shelf_attrs(socket, logo?)

    result =
      consume_uploaded_entry(socket, entry, fn %{path: path} ->
        {:ok,
         PressKit.create(
           socket.assigns.owner,
           socket.assigns.current_user,
           {path, entry.client_name},
           attrs
         )}
      end)

    stored(socket, result, logo?)
  end

  # What the add form is holding for one shelf, as changeset attrs — the upload
  # and the page-logo adoption write the same three.
  defp shelf_attrs(socket, logo?) do
    %{
      "logo" => logo?,
      "credit" => credit(socket, logo?),
      "rights_confirmed" => socket.assigns.armed[logo?]
    }
  end

  # What either way of adding a picture does with the answer.
  defp stored(socket, {:ok, _image}, _logo?),
    do: {:noreply, socket |> assign(:error, nil) |> load_shelves()}

  defp stored(socket, {:error, reason}, logo?),
    do: {:noreply, assign(socket, :error, write_error(reason, logo?))}

  # The one error vocabulary of this page's three writers — the upload, the
  # page-logo adoption and the caption edit. Named for the write rather than for
  # the upload since #2087, when a refused edit found its way here.
  defp write_error(:too_many, true),
    do: gettext("No more than %{max} logo variants.", max: compact_count(PressKit.max_logos()))

  defp write_error(:too_many, false),
    do: gettext("No more than %{max} press photos.", max: compact_count(PressKit.max_photos()))

  # Defensive: `allow_upload/3` is configured with the same cap, so LiveView
  # refuses an oversized file before this can see it. The wording is the shared
  # one either way, so the two gates cannot answer differently.
  defp write_error(:too_large, _logo?),
    do:
      gettext("That file is larger than %{limit}. Please upload a smaller one.",
        limit: megabyte_label(PressKit.max_filesize())
      )

  defp write_error(:forbidden, _logo?),
    do: gettext("You cannot add a picture to this Media Kit.")

  defp write_error(%Ecto.Changeset{errors: errors} = changeset, _logo?) do
    if Keyword.has_key?(errors, :rights_confirmed),
      do: gettext("Please confirm the rights first, then choose the file."),
      else: first_error(changeset)
  end

  defp write_error(_reason, _logo?), do: gettext("That file could not be processed.")

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
    <.editor_chrome owner={@owner} viewer={@current_user} title={@page_title}>
      <.error_banner :if={@error} id="press-error">{@error}</.error_banner>

      <%!-- The bios first: a journalist reads about the person before picking a
      picture of them, and the editor shows the kit in the order the page does.
      A page has none (`Vutuv.PressKit.bio/1` says why), so the card is a
      member's. --%>
      <.bios_card
        :if={match?(%User{}, @owner)}
        viewer={@current_user}
        bio={@bio}
        words={@bio_words}
        typing={@typing_words}
        open={@open_bio}
      />

      <.shelf
        owner={@owner}
        viewer={@current_user}
        logo?={false}
        images={@photos}
        upload={@uploads.photo}
        armed?={@armed[false]}
        credit={@credits[false]}
        open={@open}
      />

      <.shelf
        owner={@owner}
        viewer={@current_user}
        logo?={true}
        images={@logos}
        upload={@uploads.logo}
        armed?={@armed[true]}
        credit={@credits[true]}
        open={@open}
        logo_ground={@logo_ground}
        adopt_logo?={@adopt_logo?}
      />
    </.editor_chrome>
    """
  end

  # The three bios (issue #2101): a row per length, each showing what is
  # written, how many words that is and the way in.
  #
  # **One editor at a time**, the same rule the picture tiles follow: the
  # Markdown editor sits inside the open row's `:if` and carries that length in
  # its id, so it is created and destroyed rather than patched — three Milkdown
  # instances on one page is what `markdown_editor_test.exs` exempts this file
  # from having to re-seed.
  attr(:viewer, :any, required: true)
  attr(:bio, :any, required: true)
  attr(:words, :map, required: true)
  attr(:typing, :integer, default: nil)
  attr(:open, :atom, default: nil)

  defp bios_card(assigns) do
    ~H"""
    <.card data-press-bios>
      <.section_title>{gettext("About you")}</.section_title>
      <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">
        {gettext(
          "Three bios in three lengths, so a journalist can take the one that fits. You write them; nothing is made out of your CV."
        )}
      </p>

      <ul class="mt-4 list-none divide-y divide-slate-100 pl-0 dark:divide-slate-800">
        <.bio_row
          :for={length <- PressKit.bio_lengths()}
          viewer={@viewer}
          length={length}
          text={Map.fetch!(@bio, length)}
          words={
            if(@open == length && @typing, do: @typing, else: Map.fetch!(@words, length))
          }
          open?={@open == length}
        />
      </ul>
    </.card>
    """
  end

  attr(:viewer, :any, required: true)
  attr(:length, :atom, required: true)
  attr(:text, :string, default: nil)
  attr(:words, :integer, required: true)
  attr(:open?, :boolean, required: true)

  defp bio_row(assigns) do
    ~H"""
    <li class="py-4 first:pt-0" data-press-bio={@length}>
      <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
        <h3 class="m-0 text-sm font-semibold text-slate-900 dark:text-slate-100">
          {PressKit.bio_label(@length)}
        </h3>
        <%!-- The count a member watches while they write. `%{formatted}` and
        not `%{count}`: `ngettext/3` binds that name to the raw integer itself
        and a `count:` binding does not win, so a formatted number needs a
        placeholder of its own. --%>
        <span
          data-press-bio-words={@length}
          class="text-sm tabular-nums text-slate-600 dark:text-slate-400"
        >
          {ngettext("%{formatted} word", "%{formatted} words", @words,
            formatted: delimited_count(@words)
          )}
        </span>
      </div>

      <p class="mt-1 text-xs text-slate-600 dark:text-slate-400">{bio_hint(@length)}</p>

      <p :if={is_nil(@text)} class="mt-2 text-sm italic text-slate-500 dark:text-slate-400">
        {gettext("Nothing written yet.")}
      </p>
      <.markdown_prose
        :if={@text && not @open?}
        text={@text}
        class="mt-2 text-sm text-slate-700 dark:text-slate-300"
      />

      <div :if={not @open?} class="mt-2">
        <.button type="button" variant="secondary" phx-click="open_bio" phx-value-length={@length}>
          {if @text, do: gettext("Edit"), else: gettext("Write")}
        </.button>
      </div>

      <div :if={@open?} id={"press-bio-panel-#{@length}"} class="mt-2">
        <%!-- `phx-change` is what keeps the counter live: the Markdown editor
        mirrors Milkdown's prose into its textarea and dispatches a bubbling
        `input`, so a keystroke in the rich view reaches this handler exactly as
        one in the plain textarea does. The editor ignores the server's echo of
        `value` after mount, which is what makes a per-keystroke re-render safe
        here (it is what the post composer does). The debounce goes to the
        editor's own field rather than on this form — see the attr's doc. --%>
        <.form
          for={%{}}
          id={"press-bio-form-#{@length}"}
          phx-submit="save_bio"
          phx-change="bio_typing"
          class="space-y-3"
        >
          <input type="hidden" name="length" value={@length} />
          <.markdown_editor
            id={"press-bio-#{@length}"}
            name="bio[text]"
            user={@viewer}
            value={@text || ""}
            label={PressKit.bio_label(@length)}
            placeholder={bio_placeholder(@length)}
            rows={bio_rows(@length)}
            debounce="300"
            help
          />
          <p class="text-xs text-slate-600 dark:text-slate-400">
            {gettext("An @handle links to that profile and notifies nobody.")}
          </p>

          <div class="flex flex-wrap gap-2">
            <.button type="submit">{gettext("Save")}</.button>
            <.button type="button" variant="ghost" phx-click="close_bio">
              {gettext("Cancel")}
            </.button>
          </div>
        </.form>
      </div>
    </li>
    """
  end

  # The word count is guidance and nothing enforces it, so it is said here
  # rather than in a validation: what the length is *for*, then how long that
  # usually makes it.
  defp bio_hint(:short),
    do:
      gettext("About %{words} words. The two sentences under a photo.",
        words: delimited_count(PressKit.bio_word_target(:short))
      )

  defp bio_hint(:medium),
    do:
      gettext("About %{words} words. A paragraph at the end of an article.",
        words: delimited_count(PressKit.bio_word_target(:medium))
      )

  defp bio_hint(:long), do: gettext("As long as you like. The whole portrait.")

  defp bio_placeholder(:short), do: gettext("Two sentences a caption can carry.")
  defp bio_placeholder(:medium), do: gettext("A paragraph an article can end on.")
  defp bio_placeholder(:long), do: gettext("The whole story, for as long as it needs.")

  defp bio_rows(:short), do: 3
  defp bio_rows(:medium), do: 6
  defp bio_rows(:long), do: 12

  # The one thing the two hosts do not share: where this editor sits, and the
  # one sentence that says what the shelves are for — which cannot be shared,
  # because the German of the member's version addresses the reader as the owner
  # ("Ihr Logo") and a page's team is not the page.
  attr(:owner, :any, required: true)
  attr(:viewer, :any, required: true)
  attr(:title, :string, required: true)
  slot(:inner_block, required: true)

  defp editor_chrome(%{owner: %Organization{}} = assigns) do
    ~H"""
    <div class="mx-auto max-w-2xl py-6">
      <.manage_header organization={@owner} active={:press} viewer={@viewer} />

      <h1 class="text-2xl font-bold text-slate-900 dark:text-slate-100">{@title}</h1>
      <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">
        {gettext(
          "What a journalist writing about this page may download: photos in print quality and its logo as a file. Everything here is public and free for editorial use as long as the credit is shown."
        )}
      </p>

      <div class="mt-6 space-y-6">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  defp editor_chrome(assigns) do
    ~H"""
    <.settings_shell user={@owner} active={:press} title={@title}>
      <div class="space-y-6">
        <.card>
          <p class="text-sm text-slate-600 dark:text-slate-400">
            {gettext(
              "What a journalist writing about you may download: photos in print quality and your logo as a file. Everything here is public and free for editorial use as long as your credit is shown."
            )}
          </p>
        </.card>

        {render_slot(@inner_block)}
      </div>
    </.settings_shell>
    """
  end

  attr(:owner, :any, required: true)
  attr(:viewer, :any, required: true)
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

  # Likewise only the logo shelf can adopt anything, and the answer is read from
  # disk once at mount (`editor/2`), never from this markup.
  attr(:adopt_logo?, :boolean, default: false)

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
        {if @logo?, do: logo_shelf_hint(@owner), else: photo_shelf_hint()}
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
          owner={@owner}
          viewer={@viewer}
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
        adopt_logo?={@adopt_logo?}
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

  attr(:owner, :any, required: true)
  attr(:viewer, :any, required: true)
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
          data-confirm={remove_confirm(@owner)}
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
              user={@viewer}
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
  attr(:adopt_logo?, :boolean, default: false)

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

      <%!-- The page's own logo, taken onto the shelf with one press (#2087),
      offered only where that file is a vector — a raster logo on this page is
      already the screen-sized copy, and offering it for print would be a
      promise the file cannot keep. It is armed by the very tick beside it
      rather than skipping the gate: the page holds the file, but releasing it
      for editorial use is still somebody's decision, and one rule beats a
      second one that only this button knows about. --%>
      <div :if={@adopt_logo?} class="space-y-1">
        <.button
          type="button"
          id="press-adopt-logo"
          variant="secondary"
          phx-click="adopt_logo"
          disabled={not @armed?}
        >
          {gettext("Use the page's own logo")}
        </.button>
        <p class="text-xs text-slate-600 dark:text-slate-400">
          {gettext("Copies the vector file this page's logo was uploaded as onto this shelf.")}
        </p>
      </div>

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

  # The three sentences that cannot be one msgid: their German addresses the
  # reader as the owner of what it describes ("Ihr Logo", "Ihrem Pressebereich"),
  # and a page's team is not the page. A msgid is a key rather than a phrase, so
  # a different voice gets one of its own instead of a translation that fits
  # neither.
  defp logo_shelf_hint(%Organization{}) do
    gettext(
      "The page's logo as a file, one tile per variant. A vector (SVG) is what a printer asks for; a PNG is what everybody else can open."
    )
  end

  defp logo_shelf_hint(_owner) do
    gettext(
      "Your logo as a file, one tile per variant. A vector (SVG) is what a printer asks for; a PNG is what everybody else can open."
    )
  end

  # The photo shelf's is about the order rather than about whose pictures they
  # are, so both hosts say it.
  defp photo_shelf_hint do
    gettext(
      "The first photo is the one shown first. Drag a tile, or use the arrows, to change the order."
    )
  end

  defp remove_confirm(%Organization{}),
    do: gettext("Remove this picture from this page's Media Kit?")

  defp remove_confirm(_owner), do: gettext("Remove this picture from your Media Kit?")

  defp shelf_max(true), do: PressKit.max_logos()
  defp shelf_max(false), do: PressKit.max_photos()

  # A logo's `thumb` is scaled down whole; a photo's is a square crop, so its
  # tile takes `lite` — the cheap version, which is what this page's ten tiles
  # should cost on the phone they are uploaded from.
  defp tile_version(image), do: if(Image.logo?(image), do: "thumb", else: "lite")

  defp pending?(image), do: not ImageScans.released?(image.moderation)

  defp tile_title(image), do: PressKit.title(image)
end
