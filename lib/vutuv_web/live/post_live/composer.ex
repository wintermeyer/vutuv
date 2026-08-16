defmodule VutuvWeb.PostLive.Composer do
  @moduledoc """
  The post composer, used by the feed (new posts), the edit page and the
  reply page (pass `parent` to create the post as a reply via
  `Vutuv.Posts.create_reply/3`, and `initial_body` to open it with text
  already in the editor).

  **Images upload eagerly**: the moment a file is picked it is processed
  (`Vutuv.Posts.create_pending_image/3` — AVIF versions, private original)
  and gets a URL, so the author can reference it inline (`![](…)`) before
  the post exists. Submit attaches the pending rows; abandoned ones are
  swept after a day. Each image carries an alt-text input (stored on save).

  **Inline embedding** is client-driven: every completed upload is announced
  to the editor hook (`mde-image-uploaded` — the hook inserts files that were
  dropped/pasted into the prose at the cursor), and each thumbnail row's
  "Insert" button pushes `mde-insert-image` for an explicit at-cursor insert.
  Attachments the body does not reference render as a gallery below the post
  (`VutuvWeb.PostComponents`); referenced ones render in place
  (`VutuvWeb.Markdown.render_post/2`, own-upload whitelist).

  **Audience:** new posts publish **public** — there is no audience picker on
  the composer. The deny model still stands behind it: an existing restricted
  post keeps its audience when edited (`validate`/`save` fall back to the post's
  derived preset when the form carries none, so a followers-only post is never
  silently widened to public), and an already-custom post still shows the *Hide
  from…* sheet (wildcards + a person typeahead) so its per-user denials stay
  editable. Any restriction also closes anonymous access, and `Vutuv.Posts`
  enforces it.

  **One composer, no tabs.** A post is one kind — photos are optional
  attachments on it — and the composer says so: the editor is always on
  screen, and every arrangement decision keys on **whether photos are
  attached**, never on a mode. Attached photos always render as the large
  natural-ratio grid with their caption input and camera switch inline under
  every tile (no panel hunting). The two rights questions — licence and
  download — fold behind the collapsed **"Photo details"** row that appears
  with the first photo, prefilled with the author's defaults: someone
  stapling a screenshot to a text is not charged two rulings they have no
  answer to (the spirit of issue #1157), while a photographer is one tap
  away. A post saved with the row folded keeps the author's default licence
  and the web-versions-only download; `save` falls back to the stored value
  on edit, so an edit that never rendered the selects cannot reset them.
  The Text|Fotos tabs this replaces made the same stored post *feel* like
  two kinds, with the questions asked diverging per tab. Entry points: the
  feed's pill opens the composer plain, its camera button opens the same
  composer and client-side clicks the "Add photos" control.

  **Photos survive a reconnect.** The attached rows ride the form as hidden
  `post[image_ids][]` inputs; a re-mounted composer re-adopts the recovered,
  still-pending rows in `validate` (`Posts.pending_images/2`) — the photo
  half of issue #1130, whose text half form recovery already covered.
  """

  use VutuvWeb, :live_component

  alias Vutuv.Fediverse.Note
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Languages
  alias Vutuv.Organizations.Organization
  alias Vutuv.Posts
  alias Vutuv.Posts.GalleryLayout
  alias Vutuv.Posts.PhotoLicense
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostDraft
  alias Vutuv.Posts.PostImage
  alias Vutuv.Uploads.Spec
  alias VutuvWeb.ErrorHelpers
  alias VutuvWeb.PostComponents

  @presets ~w(public followers connections only_me custom)

  # The debounced autosave firing (issue #1148): `schedule_draft_save/1` sends
  # this to the component itself via `send_update_after/3`, so the write happens
  # once the member pauses rather than once per keystroke, and no host LiveView
  # needs a handler for it.
  @impl true
  def update(%{save_draft: true}, socket), do: {:ok, persist_draft(socket)}

  def update(assigns, socket) do
    socket =
      assign(
        socket,
        Map.take(assigns, [
          :id,
          :current_user,
          # The organization this member is writing as, or nil (issue #1335).
          # Only the feed passes it; every other host composes personally.
          :acting_as,
          :post,
          :parent,
          :remote_note,
          :remote_post,
          :initial_body,
          :preloaded_draft
        ])
      )

    # Only the feed passes `acting_as`; every other host (edit, reply, the
    # answer to a remote post) composes personally, so the key has to exist
    # either way or the template raises on a missing assign.
    socket = Phoenix.Component.assign_new(socket, :acting_as, fn -> nil end)

    socket =
      if socket.assigns[:composer_ready?] do
        socket
      else
        init_composer(socket)
      end

    {:ok, socket}
  end

  defp init_composer(socket) do
    post = socket.assigns[:post]
    {preset, wildcards, denied_users} = derive_audience(post)
    images = post_images(post)

    socket
    |> assign(:composer_ready?, true)
    |> assign_new(:parent, fn -> nil end)
    # Set when this composer answers a reply from another network (issue #1070);
    # it then saves through Posts.create_remote_reply/3 instead.
    |> assign_new(:remote_note, fn -> nil end)
    # …and this one when it answers a post by an account the member follows
    # (issue #1165): Posts.create_remote_post_reply/3, a top-level post rather
    # than a reply.
    |> assign_new(:remote_post, fn -> nil end)
    # Reposted or answered posts carry other people's shares and replies:
    # the audience is pinned to public (Posts.update_post/2 enforces it; the
    # select disappears).
    |> assign(
      :audience_locked?,
      post != nil and (Posts.has_reposts?(post) or Posts.has_replies?(post))
    )
    # `initial_body` opens the composer with text already in it — the reply
    # page seeds a Markdown blockquote when the reader marked part of the post
    # before pressing Reply (issue #1114). An edited post's own body wins.
    |> assign(:body, (post && post.body) || socket.assigns[:initial_body] || "")
    # Whether the folded licence/download row is opened. Starts folded even on
    # edit — the fold names the answers in force, and a reconnect that resets
    # the flag hides no data (the values live in assigns and the draft).
    |> assign(:photo_details_open?, false)
    |> assign(:tags_value, tags_value(post))
    |> assign(:images, images)
    # The per-photo settings the composer is editing (issue #1104), keyed by
    # image id. Held in the socket rather than in form fields: the two switches
    # reveal follow-up controls, and an unchecked checkbox submits nothing — so
    # driving them by event keeps "off" an actual state instead of an absence.
    |> assign(:photos, photo_state(images))
    # Which photo's panel is open; nil = none, which is the whole hobby flow.
    |> assign(:open_photo, nil)
    # The chosen bento arrangement (Vutuv.Posts.GalleryLayout); nil = auto.
    |> assign(:layout, (post && post.gallery_layout) || nil)
    # Whether the bento tiles are filled (cropped) rather than showing whole
    # photos. Default whole — nobody's picture loses its edges unasked.
    |> assign(:fill?, (post && post.gallery_fill?) == true)
    # The first half of a tap-tap swap in the bento preview: the id of the
    # photo tapped first, highlighted until its partner (or the same photo
    # again, to cancel) is tapped. Event-driven on purpose — tap-tap needs no
    # drag, so it works the same on a phone and a desktop.
    |> assign(:swap_photo, nil)
    |> assign(:license, initial_license(post, socket.assigns.current_user))
    |> assign(:language, initial_language(post))
    |> assign(:preset, preset)
    |> assign(:deny_wildcards, wildcards)
    |> assign(:denied_users, denied_users)
    |> assign(:user_search, "")
    |> assign(:user_results, [])
    |> assign(:error, nil)
    # Whether what is on screen came back from a stored draft, which the notice
    # above the form says out loud (issue #1148). Cleared by the first edit:
    # from then on it is simply what the member is writing.
    |> assign(:restored_draft?, false)
    # True while an autosave is already queued, so a burst of keystrokes
    # schedules one write rather than one per character.
    |> assign(:draft_scheduled?, false)
    |> allow_upload(:images,
      accept: Vutuv.PostImageStore.extension_whitelist(),
      max_entries: Posts.max_images_per_post(),
      max_file_size: Posts.max_image_filesize(),
      auto_upload: true,
      progress: &handle_progress/3
    )
    |> restore_draft()
  end

  ## Drafts (issue #1148)
  #
  # A reload rebuilds the page from nothing — LiveView's form recovery only
  # runs on a socket reconnect — so the composer stores what it is holding and
  # reads it back here. There is no "are you sure you want to leave" dialog any
  # more: the browser never let us word one, and with the content kept there is
  # nothing left to warn about.

  # How long the composer waits after the last change before writing. Long
  # enough that ordinary typing costs one write per pause instead of one per
  # character, short enough that a reload is very unlikely to outrun it. `0`
  # means "write on the spot", which is what the test env uses so a draft is
  # observable the moment a change round trips (and what an installation would
  # set to trade writes for never losing the last second of typing).
  @default_draft_debounce_ms 1_500

  defp draft_debounce_ms,
    do: Application.get_env(:vutuv, :composer_draft_debounce_ms, @default_draft_debounce_ms)

  # The edit page is deliberately draft-free: its composer opens full of a
  # *published* post, and silently restoring a weeks-old unsaved edit over text
  # other people have already read is a different promise from keeping a draft.
  defp draftable?(assigns), do: assigns[:post] == nil and assigns[:remote_post] == nil

  # Which composer this is, in the terms `Vutuv.Posts` keys drafts by. The
  # answer-to-a-followed-post composer (issue #1165) is deliberately absent: it
  # is not a draft context, for the blue/green reason `Posts.draft_key/1`
  # spells out. `draftable?/1` keeps it from autosaving into the feed
  # composer's row.
  defp draft_context(assigns), do: assigns[:parent] || assigns[:remote_note]

  # The stored draft this composer restores: what the host already read and
  # handed in (`preloaded_draft={{:loaded, draft_or_nil}}` — the feed reads it
  # anyway to decide whether the panel opens), or this composer's own query.
  # The `{:loaded, ...}` wrapper keeps "host read it and found none" apart from
  # "host did not pass one".
  defp stored_draft(assigns) do
    case assigns[:preloaded_draft] do
      {:loaded, draft} -> draft
      _not_handed_in -> Posts.get_draft(assigns.current_user, draft_context(assigns))
    end
  end

  defp restore_draft(socket) do
    assigns = socket.assigns

    with true <- draftable?(assigns),
         %PostDraft{} = draft <- stored_draft(assigns) do
      # The ids are re-checked against the author's own still-pending rows, so a
      # stale list cannot resurrect a photo that was removed or attached since.
      images = Posts.pending_images(assigns.current_user, draft.image_ids)

      socket
      |> assign(:body, draft.body)
      |> assign(:tags_value, draft.tags)
      |> assign(:images, images)
      |> assign(:photos, photo_state_from_draft(draft, images))
      |> assign(:license, PhotoLicense.cast(draft.license || assigns.license))
      |> assign(:language, Post.cast_language(draft.language) || assigns.language)
      |> assign(:layout, GalleryLayout.cast(draft.layout))
      |> assign(:fill?, draft.fill? == true)
      |> assign(:restored_draft?, true)
    else
      _no_draft -> socket
    end
  end

  # Rebuilds the per-photo panel state from the stored map. The keys are read
  # by name from a fixed list rather than turned into atoms, and anything the
  # draft does not name falls back to the image row's own value, so a photo
  # attached after the last autosave still arrives with sane settings.
  defp photo_state_from_draft(%PostDraft{photos: stored}, images) when is_map(stored) do
    Map.new(images, fn image ->
      defaults = photo_defaults(image)

      settings =
        case Map.get(stored, image.id) do
          saved when is_map(saved) ->
            %{
              alt: Map.get(saved, "alt", defaults.alt),
              caption: Map.get(saved, "caption", defaults.caption),
              show_camera_info:
                Map.get(saved, "show_camera_info", defaults.show_camera_info) == true,
              download_original:
                Map.get(saved, "download_original", defaults.download_original) == true,
              download_exact: Map.get(saved, "download_exact", defaults.download_exact) == true
            }

          _missing ->
            defaults
        end

      {image.id, settings}
    end)
  end

  defp photo_state_from_draft(_draft, images), do: photo_state(images)

  # Queues one autosave. Called from every handler that changes what the
  # composer is holding; the flag collapses a burst into a single write.
  defp schedule_draft_save(socket) do
    cond do
      not draftable?(socket.assigns) ->
        socket

      draft_debounce_ms() == 0 ->
        persist_draft(socket)

      socket.assigns.draft_scheduled? ->
        socket

      true ->
        send_update_after(
          __MODULE__,
          [id: socket.assigns.id, save_draft: true],
          draft_debounce_ms()
        )

        assign(socket, :draft_scheduled?, true)
    end
  end

  defp persist_draft(socket) do
    assigns = socket.assigns

    if draftable?(assigns) do
      Posts.save_draft(assigns.current_user, draft_context(assigns), %{
        "body" => assigns.body,
        "tags" => assigns.tags_value,
        "license" => assigns.license,
        "language" => assigns.language,
        "image_ids" => Enum.map(assigns.images, & &1.id),
        "photos" => Map.new(assigns.photos, fn {id, settings} -> {id, stringify(settings)} end),
        "layout" => assigns.layout,
        "fill?" => assigns.fill?
      })
    end

    assign(socket, :draft_scheduled?, false)
  end

  # Called once the post is really saved, and by the notice's "Discard".
  defp drop_draft(socket) do
    if draftable?(socket.assigns) do
      Posts.delete_draft(socket.assigns.current_user, draft_context(socket.assigns))
    end

    assign(socket, :restored_draft?, false)
  end

  defp tags_value(nil), do: ""
  defp tags_value(post), do: Enum.map_join(post.tags, ", ", & &1.name)

  defp post_images(nil), do: []
  defp post_images(%Post{images: images}) when is_list(images), do: images
  defp post_images(_post), do: []

  # Editing keeps the post's declared language; a new post is preset to the
  # UI locale (issue #1489) — the author says what language they wrote in,
  # nobody guesses.
  defp initial_language(%Post{language: language}) when is_binary(language), do: language
  defp initial_language(_post), do: Gettext.get_locale(VutuvWeb.Gettext)

  defp other_language_options do
    site = Languages.site_locales()
    Enum.reject(Languages.options(), fn {_label, code} -> code in site end)
  end

  # Editing keeps the post's own license; a new post starts from the author's
  # last pick, so a professional sets it once and never again.
  defp initial_license(%Post{license: license}, _author) when is_binary(license), do: license
  defp initial_license(_post, author), do: Posts.default_license(author)

  ## Per-photo settings (issue #1104)

  # Seeded from the stored rows, so opening an existing post for editing shows
  # the choices that are actually in force rather than fresh defaults.
  defp photo_state(images), do: Map.new(images, &{&1.id, photo_defaults(&1)})

  defp photo_defaults(%PostImage{} = image) do
    %{
      alt: image.alt || "",
      caption: image.caption || "",
      show_camera_info: image.show_camera_info,
      download_original: image.download_original,
      download_exact: image.download_exact
    }
  end

  defp photo_settings(photos, %PostImage{} = image),
    do: Map.get(photos, image.id) || photo_defaults(image)

  defp photo_setting(photos, %PostImage{} = image, key),
    do: photos |> photo_settings(image) |> Map.fetch!(key)

  # Whether the photo has an accessible name: an alt, or the caption that
  # `PostComponents.photo_alt/1` falls back to. The amber ALT nudge shows
  # only while it has neither — a photo with a caption is not undescribed.
  defp photo_described?(photos, %PostImage{} = image) do
    settings = photo_settings(photos, image)
    settings.alt != "" or settings.caption != ""
  end

  defp open_photo(_images, nil), do: nil
  defp open_photo(images, id), do: Enum.find(images, &(&1.id == id))

  # Applies (or clears) one photo's crop and swaps the updated row into the
  # list, so the re-render shows the freshly cropped tile.
  defp apply_photo_crop(socket, image, crop) do
    case Posts.crop_image(image, crop) do
      {:ok, updated} ->
        images =
          Enum.map(socket.assigns.images, &if(&1.id == updated.id, do: updated, else: &1))

        socket |> assign(:images, images) |> assign(:error, nil)

      {:error, _reason} ->
        assign(socket, :error, gettext("The photo could not be cropped."))
    end
  end

  # Trades the positions of two photos (the bento preview's tap-tap swap).
  # Unknown ids leave the list untouched — a tile can go stale between taps.
  defp swap_images(images, first_id, second_id) do
    first = Enum.find_index(images, &(&1.id == first_id))
    second = Enum.find_index(images, &(&1.id == second_id))

    if first && second do
      images
      |> List.replace_at(first, Enum.at(images, second))
      |> List.replace_at(second, Enum.at(images, first))
    else
      images
    end
  end

  ## The post-wide download answer (issue #1104 follow-up)

  # What a visitor can save, as one value for the whole set: the served
  # versions the page shows, the full-resolution original with its metadata
  # removed, or the uploaded file byte for byte. The choice is per photo in
  # the database (and the panel still edits it there), but it is asked once
  # per post — a photographer decides "may my originals be downloaded" for a
  # set, not for picture three of nine.
  @download_choices ~w(none clean exact)

  defp download_choice(%{download_original: false}), do: "none"
  defp download_choice(%{download_exact: true}), do: "exact"
  defp download_choice(_settings), do: "clean"

  # `"mixed"` is a reading, not a choice: a post whose photos disagree (a
  # per-photo override in the panel, or an older post opened for editing) must
  # not have the select claim an answer nobody gave.
  defp download_selection(photos, images) do
    images
    |> Enum.map(&download_choice(photo_settings(photos, &1)))
    |> Enum.uniq()
    |> case do
      [] -> "none"
      [one] -> one
      _differing -> "mixed"
    end
  end

  defp apply_download_choice(socket, choice) when choice in @download_choices do
    settings = download_settings(choice)

    photos =
      Map.new(socket.assigns.photos, fn {id, current} -> {id, Map.merge(current, settings)} end)

    assign(socket, :photos, photos)
  end

  defp apply_download_choice(socket, _mixed_or_unknown), do: socket

  defp download_settings("none"), do: %{download_original: false, download_exact: false}
  defp download_settings("clean"), do: %{download_original: true, download_exact: false}
  defp download_settings("exact"), do: %{download_original: true, download_exact: true}

  # How many of the photos carry the place they were taken. Only `has_gps` is
  # stored (never the coordinates), which is all the warning needs.
  defp located_photos(images), do: Enum.count(images, & &1.has_gps)

  # A format `Vutuv.Uploads.MetadataStrip` cannot take apart is handed out as
  # it is, whatever "metadata removed" says — `Posts.update_image_settings/2`
  # forces the exact file at save time rather than breaking the promise, so
  # the composer says so up front.
  defp uncleanable?(images),
    do: Enum.any?(images, &(not Vutuv.PostImageStore.cleanable?(&1)))

  # "AVIF" — the served format names itself, so the select cannot advertise a
  # format the pipeline no longer produces.
  defp served_format do
    Spec.served_ext() |> String.trim_leading(".") |> String.upcase()
  end

  defp update_photo(socket, id, fun) do
    case Map.fetch(socket.assigns.photos, id) do
      :error ->
        socket

      {:ok, settings} ->
        assign(socket, :photos, Map.put(socket.assigns.photos, id, fun.(settings)))
    end
  end

  # Only the open panel renders text inputs, so a change event carries at most
  # one photo's texts — merge them in rather than replacing the map, or closing
  # the panel would blank every other photo's caption.
  defp merge_photo_texts(socket, nil), do: socket

  defp merge_photo_texts(socket, submitted) when is_map(submitted) do
    photos =
      Enum.reduce(submitted, socket.assigns.photos, fn {id, texts}, acc ->
        case Map.fetch(acc, id) do
          :error ->
            acc

          {:ok, settings} ->
            Map.put(acc, id, %{
              settings
              | alt: Map.get(texts, "alt", settings.alt),
                caption: Map.get(texts, "caption", settings.caption)
            })
        end
      end)

    assign(socket, :photos, photos)
  end

  defp merge_photo_texts(socket, _other), do: socket

  # Written on submit, not on every keystroke: an abandoned composer should not
  # leave settings on rows it never attached to a post.
  defp save_photo_settings(images, photos) do
    Enum.each(images, fn image ->
      case Map.fetch(photos, image.id) do
        :error -> :ok
        {:ok, settings} -> Posts.update_image_settings(image, stringify(settings))
      end
    end)
  end

  defp stringify(settings), do: Map.new(settings, fn {key, value} -> {to_string(key), value} end)

  # Edit mode: recognize the quick presets in the stored denials; anything
  # else (including a lone "non_followees", which no longer has its own preset)
  # is a custom audience.
  defp derive_audience(nil), do: {"public", MapSet.new(), []}

  defp derive_audience(%Post{denials: denials}) do
    case denials do
      [] ->
        {"public", MapSet.new(), []}

      [%{wildcard: "non_followers"}] ->
        {"followers", MapSet.new(), []}

      [%{wildcard: "non_connections"}] ->
        {"connections", MapSet.new(), []}

      [%{wildcard: "everyone"}] ->
        {"only_me", MapSet.new(), []}

      denials ->
        {
          "custom",
          MapSet.new(for d <- denials, d.wildcard, do: d.wildcard),
          for(d <- denials, d.denied_user_id, do: d.denied_user)
        }
    end
  end

  ## Events

  # The photo panel's inputs are named `photo[<id>][…]`, deliberately outside
  # the `post[…]` namespace: they belong to an image row, not to the post, and
  # they are written through `Posts.update_image_settings/2` rather than the
  # post changeset. So both handlers take the whole payload.
  @impl true
  def handle_event("validate", %{"post" => params} = payload, socket) do
    drafting_before? = drafting?(socket.assigns)
    body = params["body"] || socket.assigns.body

    socket =
      socket
      |> assign(:body, body)
      |> assign(:tags_value, params["tags"] || socket.assigns.tags_value)
      |> assign(:license, PhotoLicense.cast(params["license"] || socket.assigns.license))
      |> assign(:language, Post.cast_language(params["language"]) || socket.assigns.language)
      |> assign(:preset, resolve_preset(params, socket.assigns))
      |> assign(:error, nil)
      # The restore notice has said its piece once the member starts editing;
      # from here on this is simply what they are writing.
      |> assign(:restored_draft?, false)
      |> adopt_recovered_images(params["image_ids"])
      |> merge_photo_texts(payload["photo"])
      |> sweep_rejected_uploads()

    socket =
      if socket.assigns.preset == "custom" do
        socket
        |> assign(:deny_wildcards, checked_keys(params["deny_wildcards"]))
        |> run_user_search(params["user_search"] || "")
      else
        socket
      end

    {:noreply, socket |> announce_draft(drafting_before?) |> schedule_draft_save()}
  end

  def handle_event("deny-user", %{"id" => id}, socket) do
    # cast_or_nil: a tampered phx-value-id (non-UUID) is a no-op, not a
    # CastError that crashes the composer and loses the pending compose state.
    user =
      case Vutuv.UUIDv7.cast_or_nil(id) do
        nil -> nil
        uuid -> Vutuv.Repo.get(Vutuv.Accounts.User, uuid)
      end

    denied_users =
      if user && user.id != socket.assigns.current_user.id do
        Enum.uniq_by(socket.assigns.denied_users ++ [user], & &1.id)
      else
        socket.assigns.denied_users
      end

    {:noreply,
     socket
     |> assign(:denied_users, denied_users)
     |> assign(:user_search, "")
     |> assign(:user_results, [])}
  end

  def handle_event("undeny-user", %{"id" => id}, socket) do
    {:noreply,
     assign(socket, :denied_users, Enum.reject(socket.assigns.denied_users, &(&1.id == id)))}
  end

  def handle_event("insert-inline", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.images, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      image ->
        {:noreply, push_event(socket, "mde-insert-image", editor_image_payload(socket, image))}
    end
  end

  ## Photo grid and panel (issue #1104)

  # The folded licence/download row (the two rights questions) opens on
  # request and stays open; the fold itself names the answers in force.
  def handle_event("toggle-photo-details", _params, socket) do
    {:noreply, assign(socket, :photo_details_open?, not socket.assigns.photo_details_open?)}
  end

  def handle_event("photo-open", %{"id" => id}, socket) do
    # Tapping the open photo's ⚙ again closes it — the same button, so nobody
    # has to find a second one.
    open = if socket.assigns.open_photo == id, do: nil, else: id
    {:noreply, assign(socket, :open_photo, open)}
  end

  def handle_event("photo-close", _params, socket) do
    {:noreply, assign(socket, :open_photo, nil)}
  end

  def handle_event("photo-toggle", %{"id" => id, "field" => field}, socket)
      when field in ["show_camera_info", "download_original"] do
    key = String.to_existing_atom(field)

    {:noreply,
     update_photo(socket, id, fn settings ->
       flipped = Map.put(settings, key, not settings[key])
       # Switching the download off drops the exact-file choice with it, so
       # turning it on again starts from the safe answer rather than silently
       # restoring "hand out everything" (the schema enforces this too).
       if key == :download_original and not flipped.download_original,
         do: %{flipped | download_exact: false},
         else: flipped
     end)
     |> schedule_draft_save()}
  end

  def handle_event("photo-exact", %{"id" => id, "exact" => exact}, socket) do
    {:noreply,
     socket
     |> update_photo(id, &Map.put(&1, :download_exact, exact == "true"))
     |> schedule_draft_save()}
  end

  # The post-wide download select. It carries its own `phx-change` rather than
  # riding the form's `validate`, so it speaks only when the author actually
  # turns it: every keystroke replays the whole form, and a replayed value
  # would push the select's answer back over a per-photo choice just made in
  # the panel. `validate` therefore ignores `post[download]` on purpose.
  def handle_event("download-choice", %{"post" => %{"download" => choice}}, socket) do
    {:noreply, apply_download_choice(socket, choice)}
  end

  # Copies one photo's four choices onto every other photo of the post. The
  # texts are deliberately NOT copied: a caption and an alt text describe one
  # particular picture, and duplicating them across a set would be worse than
  # leaving them empty.
  def handle_event("photo-apply-all", %{"id" => id}, socket) do
    case Map.fetch(socket.assigns.photos, id) do
      :error ->
        {:noreply, socket}

      {:ok, source} ->
        shared = Map.take(source, [:show_camera_info, :download_original, :download_exact])

        photos =
          Map.new(socket.assigns.photos, fn {photo_id, settings} ->
            {photo_id, Map.merge(settings, shared)}
          end)

        {:noreply, socket |> assign(:photos, photos) |> schedule_draft_save()}
    end
  end

  # The reorder path (the `PhotoStrip` hook pushes the id order its pointer
  # drag has already applied in the DOM — mouse and touch alike, so there is
  # no second control). Ids are looked up rather than trusted: an order naming
  # an unknown id must not be able to drop photos from the post.
  def handle_event("photo-reorder", %{"order" => order}, socket) when is_list(order) do
    by_id = Map.new(socket.assigns.images, &{&1.id, &1})
    reordered = Enum.flat_map(order, fn id -> List.wrap(by_id[id]) end)
    missing = Enum.reject(socket.assigns.images, &(&1.id in order))

    {:noreply, socket |> assign(:images, reordered ++ missing) |> schedule_draft_save()}
  end

  # The bento preview's tap-tap swap: the first tap marks a photo, the second
  # trades the two places (tapping the marked photo again unmarks it). Chosen
  # over drag because it needs no pointer gymnastics on a phone and stays a
  # plain pair of clicks in a test.
  def handle_event("mosaic-swap", %{"id" => id}, socket) do
    case socket.assigns.swap_photo do
      nil ->
        {:noreply, assign(socket, :swap_photo, id)}

      ^id ->
        {:noreply, assign(socket, :swap_photo, nil)}

      other_id ->
        {:noreply,
         socket
         |> assign(:images, swap_images(socket.assigns.images, other_id, id))
         |> assign(:swap_photo, nil)
         |> schedule_draft_save()}
    end
  end

  # The bento pattern chips ("Muster"). "" is the Auto chip; an unknown name
  # (a stale chip after photos were removed) falls back to auto the same way.
  def handle_event("mosaic-pattern", %{"name" => name}, socket) do
    {:noreply,
     socket
     |> assign(:layout, GalleryLayout.cast(name))
     |> schedule_draft_save()}
  end

  # The fit pair: whole photos (default — the mosaic letterboxes) vs filled
  # tiles (object-cover, the tile crops the photo).
  def handle_event("mosaic-fit", %{"fill" => fill}, socket) do
    {:noreply,
     socket
     |> assign(:fill?, fill == "true")
     |> schedule_draft_save()}
  end

  # The crop dialog's verdict (assets/js/photo_crop.js): ratio-crop fractions,
  # or "" for "show the whole photo again". The heavy lifting — re-deriving
  # every served version from the kept original — is `Posts.crop_image/2`;
  # the re-render then swaps the tile to the freshly cropped picture (the
  # URL carries a crop-keyed cache buster). Only a photo this composer holds
  # can be cropped, which is what makes the id trustworthy: everything in
  # `@images` belongs to the author.
  def handle_event("photo-crop", %{"id" => id, "crop" => crop}, socket) do
    case Enum.find(socket.assigns.images, &(&1.id == id)) do
      nil -> {:noreply, socket}
      image -> {:noreply, apply_photo_crop(socket, image, crop)}
    end
  end

  def handle_event("remove-image", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.images, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      image ->
        # Pending rows die now; already-attached ones (edit mode) are only
        # dropped from the list — update_post removes them on save, so
        # cancelling the edit keeps the post intact.
        if is_nil(image.post_id), do: Posts.delete_pending_image(image)

        {:noreply,
         socket
         |> assign(:images, Enum.reject(socket.assigns.images, &(&1.id == id)))
         |> update(:photos, &Map.delete(&1, id))
         |> assign(
           :open_photo,
           if(socket.assigns.open_photo == id, do: nil, else: socket.assigns.open_photo)
         )
         |> update(:swap_photo, &if(&1 == id, do: nil, else: &1))
         |> schedule_draft_save()}
    end
  end

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :images, ref)}
  end

  # Discarding really discards. Two controls share it: the header's own
  # "Discard draft" button (shown while there is something to lose — the ✕
  # only collapses, issue #1135) and the restore notice's "Discard draft"
  # (issue #1148). So the pending rows die now (their files with them), the
  # stored draft goes, and the form falls back to the state the composer
  # opened in — which on the reply page still includes the quote.
  #
  # Only the feed has a panel to collapse, and only the feed LiveView has the
  # matching handle_info: the reply, remote-reply and edit pages define none at
  # all, so an ungated `send` would crash them the moment the notice's button
  # is used there.
  def handle_event("discard-draft", _params, socket) do
    Enum.each(socket.assigns.images, fn image ->
      if is_nil(image.post_id), do: Posts.delete_pending_image(image)
    end)

    if feed_composer?(socket.assigns) do
      send(self(), {:composer_discarded, socket.assigns.id})
    end

    {:noreply, socket |> drop_draft() |> reset_composer()}
  end

  def handle_event("save", %{"post" => params} = payload, socket) do
    # The submitted texts are the truth (a keystroke may not have round-tripped
    # through `validate` yet), so merge them before writing.
    socket = merge_photo_texts(socket, payload["photo"])
    save_photo_settings(socket.assigns.images, socket.assigns.photos)

    # The audience comes from the submitted form (not from assigns): the
    # submit is the truth, and it must not depend on a phx-change having
    # fired first. Only the person denials are event-driven state.
    socket =
      socket
      |> assign(:preset, resolve_preset(params, socket.assigns))
      |> assign(:deny_wildcards, checked_keys(params["deny_wildcards"]))

    attrs = %{
      body: params["body"] || "",
      tags: params["tags"] || "",
      license: params["license"] || socket.assigns.license,
      language: Post.cast_language(params["language"]) || socket.assigns.language,
      # No :review key on purpose: the review form is gone, and attrs without
      # the key leave a post's stored review sidecar untouched on edit.
      denials: denials_payload(socket.assigns),
      image_ids: Enum.map(socket.assigns.images, & &1.id),
      # Event-driven like the person denials (the chips are buttons, not form
      # fields), so the assign is the truth; "" clears back to automatic.
      layout: socket.assigns.layout || "",
      fill: socket.assigns.fill?
    }

    socket.assigns
    |> save_post(attrs)
    |> handle_save_result(socket)
  end

  # Anything the author has already put into the composer by hand. Attached
  # photos count: their pending rows survive a re-mount in the DB and come
  # back through `adopt_recovered_images/2`, so a photos-only draft is worth
  # re-opening the feed composer for.
  defp drafting?(assigns),
    do: assigns.body != "" or assigns.tags_value != "" or assigns.images != []

  # Re-adopts photos LiveView form recovery hands back after a reconnect: the
  # composer's socket state died with the old socket, but the pending rows
  # survived, and the hidden `post[image_ids][]` inputs rode the recovered
  # form. During normal composing the hidden inputs only mirror `@images`, so
  # nothing is missing and this is a no-op. `Posts.pending_images/2` returns
  # only the author's own still-pending rows, so a stale or hostile id list
  # can neither steal a photo nor resurrect a removed one.
  defp adopt_recovered_images(socket, ids) when is_list(ids) and ids != [] do
    current = socket.assigns.images
    known = Map.new(current, &{&1.id, &1})
    missing = Enum.reject(ids, &Map.has_key?(known, &1))

    case Posts.pending_images(socket.assigns.current_user, missing) do
      [] ->
        socket

      adopted ->
        by_id = Map.merge(known, Map.new(adopted, &{&1.id, &1}))

        # The recovered list's order was the author's last order; anything it
        # does not name (a photo attached after the snapshot) keeps its place
        # at the end.
        ordered =
          Enum.flat_map(ids, &List.wrap(by_id[&1])) ++
            Enum.reject(current, &(&1.id in ids))

        socket
        |> assign(:images, ordered)
        |> assign(:photos, Map.merge(photo_state(adopted), socket.assigns.photos))
    end
  end

  defp adopt_recovered_images(socket, _none), do: socket

  # New posts publish public (there is no audience picker); the fallback to
  # the current preset keeps an edited restricted post from silently
  # downgrading to public as the author types.
  defp resolve_preset(params, assigns),
    do: if(params["preset"] in @presets, do: params["preset"], else: assigns.preset)

  # Tell the feed that this composer holds a draft (issue #1130).
  #
  # The feed keeps its composer collapsed behind a "Write a post" trigger and
  # holds that open/shut state in plain socket assigns, so every re-mount starts
  # collapsed — and a websocket reconnect is a re-mount. A tab left in the
  # background long enough gets one: the browser throttles the heartbeat, the
  # socket times out, and rejoining on return re-mounts the feed. LiveView's
  # form recovery then replays this very `validate` with the half-typed text
  # still sitting in the DOM, so the draft comes back but the panel does not:
  # the author returns from looking something up and the form is simply gone,
  # with the text hidden inside it. Announcing the first content lets the feed
  # re-open the panel in the same round trip.
  #
  # Only the feed composer announces. The edit, reply and remote-reply pages
  # render the composer unconditionally, so they have nothing to re-open (and no
  # handler for the message).
  defp announce_draft(socket, drafting_before?) do
    if not drafting_before? and drafting?(socket.assigns) and feed_composer?(socket.assigns) do
      send(self(), {:composer_drafting, socket.assigns.id})
    end

    socket
  end

  # The standalone composer on /feed: not editing a post, and answering nothing —
  # which is exactly "no draft context", so a new context is added in one place
  # (`draft_context/1`) rather than in every list of nils.
  # Deliberately spelled out rather than derived from `draft_context/1`, though
  # the two look interchangeable: "is this the feed's own composer" and "does
  # this composer keep drafts" are different questions that merely coincided
  # until issue #1165 added a composer that is neither. Defining one in terms of
  # the other put the feed's ✕ back on the answer page, where nothing handles
  # `close-composer` and a click therefore kills the LiveView.
  defp feed_composer?(assigns) do
    is_nil(assigns.post) and is_nil(assigns.parent) and is_nil(assigns.remote_note) and
      is_nil(assigns.remote_post)
  end

  # Answering a reply from another network goes through its own context function:
  # it writes the sidecar that carries the answer out to that network, and it
  # holds the federation gates (issue #1070).
  defp save_post(%{post: nil, remote_note: %Note{} = note, current_user: author}, attrs),
    do: Posts.create_remote_reply(author, note, attrs)

  # Answering a post by a followed account (issue #1165). Not a reply to
  # anything here — the thing answered lives on another server — so what this
  # creates is a top-level post carrying the same sidecar.
  defp save_post(%{post: nil, remote_post: %RemotePost{} = post, current_user: author}, attrs),
    do: Posts.create_remote_post_reply(author, post, attrs)

  defp save_post(%{post: nil, parent: %Post{} = parent, current_user: author}, attrs),
    do: Posts.create_reply(author, parent, attrs)

  # Writing as an organization (issue #1335). Below the reply clauses on
  # purpose: a reply is always personal, because an organization cannot answer
  # anything until issue #1336 gives it a reading side. The role is re-checked
  # inside `create_organization_post/3`, so a withdrawn publisher cannot publish
  # through a composer they still have open.
  defp save_post(
         %{post: nil, acting_as: %Organization{} = organization, current_user: author},
         attrs
       ),
       do: Posts.create_organization_post(organization, author, attrs)

  defp save_post(%{post: nil, current_user: author}, attrs), do: Posts.create_post(author, attrs)
  defp save_post(%{post: post}, attrs), do: Posts.update_post(post, attrs)

  defp handle_save_result({:ok, post}, socket) do
    # The post exists now, so the draft that was standing in for it goes. Doing
    # it here rather than in each branch below covers all four: three of them
    # navigate away and would otherwise leave a draft behind that reopens the
    # composer with a copy of what was just published.
    socket = drop_draft(socket)

    cond do
      socket.assigns.post ->
        {:noreply, push_navigate(socket, to: Posts.path(post))}

      socket.assigns[:remote_note] || socket.assigns[:remote_post] ->
        # An answer to a remote reply has no `parent` assign of its own, so its
        # own permalink is the way back into that conversation.
        {:noreply, push_navigate(socket, to: Posts.path(post))}

      socket.assigns.parent ->
        # Back to the conversation: the thread under the parent now shows it.
        {:noreply, push_navigate(socket, to: Posts.path(socket.assigns.parent))}

      true ->
        # The feed prepends the new post via its own {:new_post, …} broadcast;
        # the composer just resets (audience choice sticks).
        {:noreply, reset_composer(socket)}
    end
  end

  defp handle_save_result({:error, %Ecto.Changeset{} = changeset}, socket) do
    {:noreply, assign(socket, :error, changeset_message(changeset))}
  end

  defp handle_save_result({:error, reason}, socket) do
    {:noreply, assign(socket, :error, save_error_message(reason))}
  end

  # Back to an empty form: after a successful post, and after "Discard draft".
  # The audience choice sticks on purpose. The stored draft is dropped by the
  # caller (issue #1148), not here — a reset is not always a discard, and
  # clearing the form would autosave an empty draft away anyway.
  defp reset_composer(socket) do
    opening_body = socket.assigns[:initial_body] || ""

    socket
    |> assign(:body, opening_body)
    |> assign(:tags_value, "")
    |> assign(:images, [])
    |> assign(:photos, %{})
    |> assign(:open_photo, nil)
    |> assign(:layout, nil)
    |> assign(:fill?, false)
    |> assign(:swap_photo, nil)
    |> assign(:photo_details_open?, false)
    |> assign(:error, nil)
  end

  defp save_error_message(:invalid_denials), do: gettext("The audience selection is not valid.")

  defp save_error_message(:visibility_locked),
    do: gettext("The audience cannot be restricted while reposts or replies exist.")

  # The edit window can close while the form sits open — a like arrives, or the
  # 30 minutes run out mid-edit (issue #1023).
  defp save_error_message(:edit_engaged),
    do: gettext("This post can no longer be edited: someone has liked, reposted or answered it.")

  defp save_error_message(:edit_window_closed) do
    gettext(
      "This post can no longer be edited. Posts stay editable for %{minutes} minutes after publishing.",
      minutes: Posts.edit_window_minutes()
    )
  end

  defp save_error_message(:invalid_images),
    do: gettext("One of the images could not be attached.")

  defp save_error_message(reason) when reason in [:restricted, :not_visible],
    do: gettext("You can no longer reply to this post.")

  # Answering another network (issue #1070). `:not_federating` is handled by the
  # page before the composer ever renders, so these are the states that can only
  # appear between opening the form and pressing Save.
  defp save_error_message(:reply_capped),
    do:
      gettext(
        "You have sent a lot of answers to other networks in the past hour. Please try again later."
      )

  # The three the answer page itself refuses with, in the page's own words
  # (`PostComponents.answer_refusal_message/1`): the audience of the thing being
  # answered can narrow while the form sits open (an `Update` arrives), and the
  # operator can block the server in that same window. A refusal must not be
  # worded one way on the page and another way on save.
  defp save_error_message(reason)
       when reason in [:instance_blocked, :note_not_public, :post_not_public],
       do: PostComponents.answer_refusal_message(reason)

  defp save_error_message(reason) when reason in [:not_federating, :moved, :fediverse_disabled],
    do: gettext("Your Fediverse settings do not allow sending an answer right now.")

  defp save_error_message(_too_many_images) do
    gettext("No more than %{max} images per post.", max: Posts.max_images_per_post())
  end

  # Files refused at selection time (over the size limit, type not in the
  # accept list — e.g. HEIC photos on builds without an HEVC decoder) used to
  # sit as silently-erroring entries: the message only flashed in the
  # transient upload row, so a multi-photo selection looked like files just
  # vanished. Cancel them and say which file was refused and why, durably.
  defp sweep_rejected_uploads(socket) do
    rejected =
      Enum.filter(
        socket.assigns.uploads.images.entries,
        &(upload_errors(socket.assigns.uploads.images, &1) != [])
      )

    case rejected do
      [] ->
        socket

      rejected ->
        messages =
          Enum.map_join(rejected, " ", fn entry ->
            reason =
              socket.assigns.uploads.images
              |> upload_errors(entry)
              |> List.first()
              |> upload_error_message()

            "#{entry.client_name}: #{reason}"
          end)

        rejected
        |> Enum.reduce(socket, &cancel_upload(&2, :images, &1.ref))
        |> assign(:error, messages)
    end
  end

  defp handle_progress(:images, entry, socket) do
    cond do
      not entry.done? ->
        {:noreply, socket}

      length(socket.assigns.images) >= Posts.max_images_per_post() ->
        {:noreply,
         socket
         |> cancel_upload(:images, entry.ref)
         |> assign(
           :error,
           gettext("No more than %{max} images per post.", max: Posts.max_images_per_post())
         )}

      true ->
        result =
          consume_uploaded_entry(socket, entry, fn %{path: path} ->
            {:ok,
             Posts.create_pending_image(socket.assigns.current_user, path, entry.client_name)}
          end)

        case result do
          {:ok, image} ->
            # Announce the finished upload to the editor hook: it inserts the
            # image at the cursor iff this file was dropped/pasted into the
            # prose (picker-chosen files just join the thumbnail row).
            {:noreply,
             socket
             |> update(:images, &(&1 ++ [image]))
             |> update(:photos, &Map.put(&1, image.id, photo_defaults(image)))
             |> push_event(
               "mde-image-uploaded",
               Map.put(editor_image_payload(socket, image), :name, entry.client_name)
             )
             |> schedule_draft_save()}

          {:error, _reason} ->
            {:noreply, assign(socket, :error, gettext("That file could not be processed."))}
        end
    end
  end

  # The payload both editor-hook events share: which editor (the DOM id of
  # this composer's markdown_editor), the served URL to embed and the alt.
  defp editor_image_payload(socket, image) do
    %{
      editor: "#{socket.assigns.id}-body",
      id: image.id,
      url: PostImage.url(image, "feed"),
      alt: image.alt
    }
  end

  defp run_user_search(socket, term) do
    results =
      if term == socket.assigns.user_search do
        socket.assigns.user_results
      else
        socket.assigns.current_user
        |> Posts.search_users(term)
        |> Enum.reject(fn user ->
          Enum.any?(socket.assigns.denied_users, &(&1.id == user.id))
        end)
      end

    socket
    |> assign(:user_search, term)
    |> assign(:user_results, results)
  end

  # Group ids arrive as the UUID strings the checkbox names carry — keep them
  # as-is; they compare directly against group.id.
  defp checked_keys(nil), do: MapSet.new()

  defp checked_keys(map) when is_map(map) do
    for {key, "true"} <- map, into: MapSet.new(), do: key
  end

  defp denials_payload(assigns) do
    case assigns.preset do
      "public" ->
        []

      "followers" ->
        [%{"wildcard" => "non_followers"}]

      "connections" ->
        [%{"wildcard" => "non_connections"}]

      "only_me" ->
        [%{"wildcard" => "everyone"}]

      "custom" ->
        Enum.map(MapSet.to_list(assigns.deny_wildcards), &%{"wildcard" => &1}) ++
          Enum.map(assigns.denied_users, &%{"denied_user_id" => &1.id})
    end
  end

  # Render the changeset's errors the way the classic form pages do: translate
  # each through gettext (so the German copy shows) and interpolate its opts (so
  # `%{handles}` becomes the actual handle) rather than dumping the raw msgid
  # prefixed with the field atom ("body mentions a handle …: %{handles}"). Each
  # message is now a self-contained sentence, so the field name is dropped.
  # traverse_errors walks nested changesets too, so an error on an embedded
  # association surfaces instead of failing silently.
  defp changeset_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&ErrorHelpers.translate_error/1)
    |> flatten_messages()
    |> Enum.join(" ")
  end

  defp flatten_messages(map) when is_map(map),
    do: Enum.flat_map(map, fn {_field, value} -> flatten_messages(value) end)

  defp flatten_messages(list) when is_list(list), do: Enum.flat_map(list, &flatten_messages/1)
  defp flatten_messages(message) when is_binary(message), do: [message]

  defp full_name(user), do: VutuvWeb.UserHelpers.full_name(user)

  # `input_class/0` is the shared Direction A field recipe, imported from
  # `VutuvWeb.UI` (also used by the auth pages) so the look stays in one place.

  @impl true
  def render(assigns) do
    # Read off the per-photo state rather than kept beside it, so the select
    # and the panel can never disagree about what is in force.
    assigns =
      assigns
      |> assign(:download_choice, download_selection(assigns.photos, assigns.images))
      # The live bento preview: the very arrangement the feed will show,
      # computed from the same function the post card renders with — the
      # preview and the published mosaic can never disagree.
      |> assign(
        :bento,
        length(assigns.images) > 1 &&
          PostComponents.mosaic_layout(assigns.images, assigns.layout)
      )

    ~H"""
    <div id={@id}>
      <.card>
        <%!-- Says out loud that this text came back rather than being typed
        just now (issue #1148) — without it a restored draft is indistinguishable
        from a composer someone else left open. It sits above the form, not
        inside it, so nothing it holds is ever submitted, and it steps aside as
        soon as the member edits anything.

        The empty wrapper is load-bearing, do not fold it away: it keeps the
        card's child list the same shape whether or not the notice shows. Put
        the `:if` back on a direct child of the card and the notice's own
        element appears and disappears there — whereupon morphdom stops
        matching the following siblings one-to-one and RELOCATES the form
        (removeChild + insertBefore) to restore the order. Re-parenting a
        `contenteditable` blurs it, so the Milkdown caret is thrown out of the
        editor mid-sentence and the keystrokes after it land nowhere: the
        "jumping cursor". LiveView cannot save us, its post-patch
        `DOM.restoreFocus` covers `<input>`/`<textarea>` only. With the wrapper
        the patch only swaps a child *inside* it, and the form stays put. --%>
        <div id={"#{@id}-notice"}>
          <div
            :if={@restored_draft?}
            id={"#{@id}-restored"}
            data-draft-restored
            class="mb-3 flex flex-wrap items-center justify-between gap-2 rounded-lg bg-brand-50 px-3 py-2 text-sm text-brand-800 dark:bg-brand-900/40 dark:text-brand-100"
          >
            <span>{gettext("Picked up where you left off.")}</span>
            <button
              type="button"
              phx-click="discard-draft"
              phx-target={@myself}
              data-confirm={gettext("Discard the photos and text of this draft?")}
              class="font-semibold underline underline-offset-2 hover:text-brand-900 dark:hover:text-white"
            >
              {gettext("Discard draft")}
            </button>
          </div>
        </div>

        <%!-- The whole composer is the drop zone: photos land here from the
        first drag, not only once a grid exists. LiveView stamps
        `phx-drop-target-active` on this form while files hover it, which is
        what reveals the overlay below (components.css owns the display, so
        no competing utilities). A drop into the prose editor is different on
        purpose: the editor swallows it and inserts the picture inline at the
        drop point. --%>
        <.form
          for={to_form(%{}, as: :post)}
          id={"#{@id}-form"}
          phx-submit="save"
          phx-change="validate"
          phx-target={@myself}
          phx-drop-target={@uploads.images.ref}
          data-composer-dropzone
          class="relative"
        >
          <div
            data-drop-overlay
            class="pointer-events-none absolute -inset-2 z-10 items-center justify-center rounded-2xl border-2 border-dashed border-brand-500 bg-brand-50/90 dark:border-brand-400 dark:bg-brand-900/80"
          >
            <p class="flex items-center gap-2 text-base font-semibold text-brand-700 dark:text-brand-100">
              <.camera_icon class="h-6 w-6" />
              {gettext("Drop photos to add them")}
            </p>
          </div>
          <%!-- Header row, feed compose only: "Discard draft" (while there is
          something to lose) and the corner ✕ that merely collapses the
          composer. While the restore notice above is showing, its own
          "Discard draft" owns the action and this one stays away — with both
          gates true the button rendered twice, one right above the other
          (issue #1221); the first edit clears the notice and hands over. The ✕ carries no phx-target: the event bubbles up to the
          feed LiveView that owns the reveal (`close-composer`) — a draft
          always survives it (issue #1135; the server-side draft of #1148
          keeps the photos too, and the feed re-opens over a held draft, so
          nothing sits invisibly). Really throwing a draft away is its own,
          confirmed control. The edit, reply and remote-reply pages navigate
          away instead, so they must never render either button (the
          remote-reply page has no close handler and a click there crashed
          the page). --%>
          <div
            :if={feed_composer?(assigns)}
            class="-mt-1 mb-2 flex items-center justify-end gap-1"
          >
            <button
              :if={drafting?(assigns) and not @restored_draft?}
              type="button"
              id={"#{@id}-discard"}
              phx-click="discard-draft"
              phx-target={@myself}
              data-confirm={gettext("Discard the photos and text of this draft?")}
              class="rounded-lg px-3 py-2 text-sm font-semibold text-slate-500 hover:bg-slate-100 hover:text-red-600 dark:text-slate-400 dark:hover:bg-slate-800 dark:hover:text-red-400"
            >
              {gettext("Discard draft")}
            </button>
            <button
              type="button"
              phx-click="close-composer"
              aria-label={gettext("Close")}
              title={gettext("Close")}
              class="-mr-2 rounded-lg px-3 py-2 text-sm font-semibold text-slate-500 hover:bg-slate-100 hover:text-slate-700 dark:text-slate-400 dark:hover:bg-slate-800 dark:hover:text-slate-200"
            >
              ✕
            </button>
          </div>

          <%!-- The editor is always on screen: a post is one kind, words
          first, whether or not pictures join it below. --%>
          <.body_editor id={@id} body={@body} post={@post} />

          <%!-- The photo grid, whenever photos are attached: they come large
          in their own aspect ratio, with their caption and camera switch in
          plain sight under every tile — nothing to hunt for behind ⚙, which
          keeps only the rarer refinements (alt text, download override).
          Adding more is a tile of its own, the way every photo tool does it.
          Tiles reorder by pointer drag everywhere — the PhotoStrip hook
          lifts a tile after a short hold on touch (so ordinary scrolling
          over the photos keeps working) and on the first movement with a
          mouse; the first tile leads the mosaic. Each tile carries a DOM id
          so morphdom keys it: a drag has already moved the node when the
          server's re-render arrives, and the patch then just settles it. --%>
          <%!-- No phx-drop-target of its own: the whole form is the drop
          zone now, and nesting a second one would steal the active state
          from the overlay. The data-crop-* attributes carry the crop
          dialog's translated copy (assets/js/photo_crop.js), server-worded
          like the lightbox labels. --%>
          <div
            :if={@images != []}
            id={"#{@id}-images"}
            phx-hook="PhotoStrip"
            phx-target={@myself}
            class="mt-3 grid grid-cols-2 gap-3 sm:grid-cols-3"
            data-crop-title={gettext("Crop photo")}
            data-crop-hint={
              gettext("Pick a shape, then drag and zoom. The framed part is what the post shows.")
            }
            data-crop-save={gettext("Apply crop")}
            data-crop-cancel={gettext("Cancel")}
            data-crop-reset={gettext("Whole photo")}
            data-crop-zoom={gettext("Zoom")}
          >
            <div
              :for={{image, index} <- Enum.with_index(@images)}
              id={"#{@id}-photo-#{image.id}"}
              data-photo-tile={image.id}
              class="min-w-0"
            >
              <.photo_frame
                image={image}
                index={index}
                count={length(@images)}
                open?={@open_photo == image.id}
                alt_missing?={photo_described?(@photos, image) == false}
                myself={@myself}
              />

              <div class="mt-1.5 space-y-1.5">
                <%!-- One visible text per photo: the caption. It doubles as
                the accessible name when no alt is written (photo_alt/1), so
                the alt input can stay an opt-in refinement in the panel
                instead of a second required-looking field. Full input size
                on purpose: a shrunken input is a shrunken touch target. --%>
                <input
                  type="text"
                  name={"photo[#{image.id}][caption]"}
                  value={photo_setting(@photos, image, :caption)}
                  phx-debounce="300"
                  placeholder={gettext("Caption (optional)")}
                  class={input_class()}
                />

                <%!-- The photographer's marquee switch, right where the photo
                is — behind the tile's ⚙ nobody found it. Only rendered when
                the file actually carries camera facts, and it shows the very
                line visitors would see. --%>
                <label
                  :if={PostImage.camera_info?(image)}
                  data-photo-camera-inline={image.id}
                  class="flex items-start gap-2 py-1 text-sm text-slate-700 dark:text-slate-200"
                >
                  <input
                    type="checkbox"
                    checked={photo_setting(@photos, image, :show_camera_info)}
                    phx-click="photo-toggle"
                    phx-value-id={image.id}
                    phx-value-field="show_camera_info"
                    phx-target={@myself}
                    class={checkbox_class()}
                  />
                  <span class="min-w-0">
                    <span class="font-semibold">{gettext("Show camera settings")}</span>
                    <span class="mt-0.5 block text-xs text-slate-600 dark:text-slate-400">
                      {PostComponents.camera_line(image)}
                    </span>
                  </span>
                </label>
              </div>
            </div>

            <%!-- Adding more photos is a tile among tiles. It shares its id
            with the bottom row's picker (exactly one of the two renders, so
            the upload input exists exactly once), which is how the feed's
            camera button always finds a target to click. --%>
            <label
              id={"#{@id}-add-photos"}
              data-photo-add-tile
              class="flex aspect-square cursor-pointer flex-col items-center justify-center gap-1.5 rounded-lg border-2 border-dashed border-slate-300 text-slate-600 hover:border-brand-400 hover:bg-brand-50/50 hover:text-brand-700 dark:border-slate-700 dark:text-slate-400 dark:hover:border-brand-500 dark:hover:bg-brand-900/20 dark:hover:text-brand-200"
            >
              <.camera_icon class="h-6 w-6" />
              <span class="px-2 text-center text-xs font-semibold">{gettext("Add photos")}</span>
              <.live_file_input upload={@uploads.images} class="sr-only" />
            </label>
          </div>

          <p
            :if={length(@images) > 1}
            class="mt-1.5 text-xs text-slate-600 dark:text-slate-400"
          >
            {gettext("Drag to reorder. The first photo leads the gallery.")}
          </p>

          <%!-- The bento workshop (only with something to arrange): the very
          mosaic the feed will show, live. Tap two tiles to swap the photos;
          the chips switch the arrangement ("Muster") — each chip is that
          arrangement's real geometry in miniature, drawn from the same
          catalog the mosaic renders from. "Auto" keeps the orientation-aware
          choice and stays the default. --%>
          <div :if={@bento} class="mt-4" data-bento-editor>
            <div class="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
              <span class="text-sm font-semibold uppercase tracking-wide text-slate-500">
                {gettext("Gallery preview")}
              </span>
              <span class="text-xs text-slate-600 dark:text-slate-400">
                {gettext("Tap two photos to swap them.")}
              </span>
            </div>

            <div class="mt-2 flex flex-wrap items-center gap-2">
              <button
                type="button"
                phx-click="mosaic-pattern"
                phx-value-name=""
                phx-target={@myself}
                aria-pressed={to_string(is_nil(@layout))}
                data-bento-pattern="auto"
                class={[
                  "h-10 shrink-0 rounded-lg px-3 text-sm font-semibold ring-1",
                  (is_nil(@layout) &&
                     "bg-brand-50 text-brand-700 ring-2 ring-brand-500 dark:bg-brand-900/40 dark:text-brand-100") ||
                    "text-slate-700 ring-slate-300 hover:bg-slate-100 dark:text-slate-200 dark:ring-slate-700 dark:hover:bg-slate-800"
                ]}
              >
                {gettext("Auto")}
              </button>

              <button
                :for={variant <- GalleryLayout.variants(min(length(@images), 5))}
                type="button"
                phx-click="mosaic-pattern"
                phx-value-name={variant.name}
                phx-target={@myself}
                aria-pressed={to_string(@layout == variant.name)}
                aria-label={layout_label(variant.name)}
                title={layout_label(variant.name)}
                data-bento-pattern={variant.name}
                class={[
                  "h-10 w-14 shrink-0 rounded-lg p-1.5",
                  (@layout == variant.name &&
                     "bg-brand-50 ring-2 ring-brand-500 dark:bg-brand-900/40") ||
                    "ring-1 ring-slate-300 hover:bg-slate-100 dark:ring-slate-700 dark:hover:bg-slate-800"
                ]}
              >
                <span
                  class="grid h-full w-full gap-0.5"
                  style="grid-template-columns: repeat(12, 1fr); grid-template-rows: repeat(6, 1fr)"
                >
                  <span
                    :for={area <- variant.areas}
                    style={"grid-area: #{area}"}
                    class={[
                      "rounded-[2px]",
                      (@layout == variant.name && "bg-brand-500") ||
                        "bg-slate-400 dark:bg-slate-500"
                    ]}
                  />
                </span>
              </button>
            </div>

            <%!-- The fit pair: whole photos (default) or tiles filled by
            their photos, which crops them. Whole is the default on purpose —
            nobody's picture loses its edges unless the author asks. --%>
            <div class="mt-2 flex flex-wrap items-center gap-2">
              <button
                type="button"
                phx-click="mosaic-fit"
                phx-value-fill="false"
                phx-target={@myself}
                aria-pressed={to_string(not @fill?)}
                data-bento-fit="whole"
                class={[
                  "h-10 shrink-0 rounded-lg px-3 text-sm font-semibold",
                  (!@fill? &&
                     "bg-brand-50 text-brand-700 ring-2 ring-brand-500 dark:bg-brand-900/40 dark:text-brand-100") ||
                    "text-slate-700 ring-1 ring-slate-300 hover:bg-slate-100 dark:text-slate-200 dark:ring-slate-700 dark:hover:bg-slate-800"
                ]}
              >
                {gettext("Whole photos")}
              </button>
              <button
                type="button"
                phx-click="mosaic-fit"
                phx-value-fill="true"
                phx-target={@myself}
                aria-pressed={to_string(@fill?)}
                data-bento-fit="fill"
                class={[
                  "h-10 shrink-0 rounded-lg px-3 text-sm font-semibold",
                  (@fill? &&
                     "bg-brand-50 text-brand-700 ring-2 ring-brand-500 dark:bg-brand-900/40 dark:text-brand-100") ||
                    "text-slate-700 ring-1 ring-slate-300 hover:bg-slate-100 dark:text-slate-200 dark:ring-slate-700 dark:hover:bg-slate-800"
                ]}
              >
                {gettext("Fill the tiles")}
              </button>
              <span class="text-xs text-slate-600 dark:text-slate-400">
                {if @fill?,
                  do: gettext("Each photo covers its tile and is cropped by it."),
                  else: gettext("Each photo shows whole inside its tile.")}
              </span>
            </div>

            <div
              class="mt-2 grid gap-1 overflow-hidden rounded-lg"
              style={"aspect-ratio: #{@bento.aspect}; grid-template-columns: repeat(12, 1fr); grid-template-rows: repeat(6, 1fr); max-height: 44rem"}
              data-bento-preview
            >
              <button
                :for={cell <- @bento.cells}
                type="button"
                phx-click="mosaic-swap"
                phx-value-id={cell.image.id}
                phx-target={@myself}
                style={"grid-area: #{cell.area}"}
                aria-pressed={to_string(@swap_photo == cell.image.id)}
                aria-label={gettext("Swap this photo with another")}
                title={gettext("Swap this photo with another")}
                data-bento-tile={cell.image.id}
                class="relative cursor-pointer overflow-hidden bg-slate-100 ring-1 ring-slate-200 focus-visible:z-10 focus-visible:ring-2 focus-visible:ring-brand-500 dark:bg-slate-800 dark:ring-slate-800"
              >
                <img
                  src={PostImage.url(cell.image, "feed")}
                  alt=""
                  class={["h-full w-full", (@fill? && "object-cover") || "object-contain"]}
                />
                <span
                  :if={@swap_photo == cell.image.id}
                  class="absolute inset-0 flex items-center justify-center bg-brand-600/50 text-3xl font-semibold text-white"
                  data-bento-swap-marked
                >
                  ⇄
                </span>
                <span
                  :if={cell.more > 0}
                  class="pointer-events-none absolute inset-0 flex items-center justify-center bg-slate-900/55 text-2xl font-semibold text-white"
                >
                  +{compact_count(cell.more)}
                </span>
              </button>
            </div>
          </div>

          <%!-- In-flight uploads --%>
          <div :for={entry <- @uploads.images.entries} class="mt-2 flex items-center gap-3 text-sm text-slate-600 dark:text-slate-400">
            <span class="truncate">{entry.client_name}</span>
            <progress value={entry.progress} max="100" class="h-2 flex-1">{entry.progress}%</progress>
            <button
              type="button"
              phx-click="cancel-upload"
              phx-value-ref={entry.ref}
              phx-target={@myself}
              aria-label={gettext("Cancel upload")}
            >
              ✕
            </button>
            <p :for={err <- upload_errors(@uploads.images, entry)} class="text-red-600">
              {upload_error_message(err)}
            </p>
          </div>

          <.photo_panel
            :if={open_photo(@images, @open_photo)}
            image={open_photo(@images, @open_photo)}
            settings={photo_settings(@photos, open_photo(@images, @open_photo))}
            many?={length(@images) > 1}
            id={"#{@id}-photo-panel"}
            myself={@myself}
          />

          <%!-- The two questions about the pictures themselves — who may reuse
          them, and what a visitor can actually save — behind one collapsed
          row that appears with the first photo. Someone stapling a screenshot
          to a text is not publishing a picture, so they are never made to
          rule on reuse rights and original files as the price of an ordinary
          post (the spirit of issue #1157): the fold names the answers in
          force and can simply be ignored, while a photographer is one tap
          away. The selects render only while open, so a save with the row
          folded falls back to the stored value and cannot reset it. --%>
          <div :if={@images != []} class="mt-3">
            <button
              type="button"
              id={"#{@id}-photo-details-toggle"}
              data-photo-details-toggle
              phx-click="toggle-photo-details"
              phx-target={@myself}
              aria-expanded={to_string(@photo_details_open?)}
              aria-controls={"#{@id}-photo-details"}
              class="-ml-2 inline-flex min-h-9 flex-wrap items-center gap-x-1.5 gap-y-0.5 rounded-lg px-2 py-1.5 text-left text-sm font-medium text-slate-600 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-800 dark:hover:text-slate-100"
            >
              <span aria-hidden="true" class="text-xs">
                {if @photo_details_open?, do: "▾", else: "▸"}
              </span>
              {gettext("Photo details")}
              <span class="font-normal text-slate-500 dark:text-slate-400">
                · {PhotoLicense.label(@license)} · {download_label(@download_choice)}
              </span>
            </button>

            <div :if={@photo_details_open?} id={"#{@id}-photo-details"} class="mt-2 space-y-2">
              <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
                <label
                  for={"#{@id}-license"}
                  class="text-sm font-medium text-slate-600 dark:text-slate-400"
                >
                  {gettext("Licence")}
                </label>
                <select
                  name="post[license]"
                  id={"#{@id}-license"}
                  title={gettext("Who may reuse these photos")}
                  class={[input_class(), "h-9 w-auto max-w-full py-0 text-sm"]}
                >
                  <option
                    :for={license <- PhotoLicense.values()}
                    value={license}
                    selected={@license == license}
                  >
                    {PhotoLicense.label(license)}
                  </option>
                </select>
              </div>

              <%!-- What a visitor gets is the licence's practical half, and
              it is one answer for the whole set. The panel keeps the
              per-photo override, so a post whose photos disagree reads
              "Different per photo" rather than pretending the set agrees. --%>
              <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
                <label
                  for={"#{@id}-download"}
                  class="text-sm font-medium text-slate-600 dark:text-slate-400"
                >
                  {gettext("Download")}
                </label>
                <select
                  name="post[download]"
                  id={"#{@id}-download"}
                  phx-change="download-choice"
                  phx-target={@myself}
                  title={gettext("What a visitor can save")}
                  class={[input_class(), "h-9 w-auto max-w-full py-0 text-sm"]}
                >
                  <option value="none" selected={@download_choice == "none"}>
                    {download_label("none")}
                  </option>
                  <option value="clean" selected={@download_choice == "clean"}>
                    {download_label("clean")}
                  </option>
                  <option value="exact" selected={@download_choice == "exact"}>
                    {download_label("exact")}
                  </option>
                  <option :if={@download_choice == "mixed"} value="mixed" selected>
                    {download_label("mixed")}
                  </option>
                </select>
              </div>

              <%!-- The two things that make the choice an informed one, each
              shown at the moment it applies rather than as a standing notice
              nobody reads. --%>
              <p
                :if={@download_choice == "exact" and located_photos(@images) > 0}
                class="rounded-lg bg-amber-50 px-3 py-2 text-xs text-amber-800 ring-1 ring-amber-200 dark:bg-amber-900/30 dark:text-amber-200 dark:ring-amber-800"
                data-download-gps-warning
              >
                {ngettext(
                  "This photo carries the location it was taken at, and the exact file hands it over.",
                  "Some of these photos carry the location they were taken at, and the exact file hands it over.",
                  located_photos(@images)
                )}
              </p>
              <p
                :if={@download_choice == "clean" and uncleanable?(@images)}
                class="rounded-lg bg-amber-50 px-3 py-2 text-xs text-amber-800 ring-1 ring-amber-200 dark:bg-amber-900/30 dark:text-amber-200 dark:ring-amber-800"
                data-download-clean-notice
              >
                {gettext(
                  "A file whose format cannot be cleaned is handed out exactly as uploaded."
                )}
              </p>
            </div>
          </div>

          <%!-- Tags get their own full-width row. --%>
          <.tag_input
            id={"#{@id}-tags"}
            name="post[tags]"
            value={@tags_value}
            placeholder={
              gettext("Tags, separated by commas (max. %{max})", max: Posts.max_tags_per_post())
            }
            max={Posts.max_tags_per_post()}
            field_class={input_class()}
            class="mt-3"
          />

          <%!-- The attached photos as data: form recovery replays these ids
          after a reconnect, and `adopt_recovered_images/2` re-adopts the
          pending rows the re-mount dropped from socket state. --%>
          <input :for={image <- @images} type="hidden" name="post[image_ids][]" value={image.id} />

          <%!-- Bottom row: the photo picker on the left (once photos are
          attached, the grid's add tile takes over — exactly one upload input
          renders), the (slightly wider) submit button on the right. New
          posts publish public, so there is no audience picker here; a post
          pinned public by reposts/replies still shows the read-only lock
          chip beside the button. --%>
          <div class="mt-3 flex items-center gap-3">
            <%!-- h-9 pins this to the Post button's height (both 36px, the
            standard control height): the 📷 emoji would otherwise inflate the
            line box, and mb-0 drops the global `label` margin (components.css)
            that would offset it in this row. Shares its id with the grid's
            add tile (one of the two renders), so the feed's camera button
            always has a target to click. --%>
            <label
              :if={@images == []}
              id={"#{@id}-add-photos"}
              class="inline-flex h-9 mb-0 cursor-pointer items-center gap-1.5 rounded-lg bg-slate-100 px-3 text-sm font-semibold text-slate-700 hover:bg-slate-200 dark:bg-slate-800 dark:text-slate-200 dark:hover:bg-slate-700"
            >
              📷 {gettext("Add photos")}
              <.live_file_input upload={@uploads.images} class="sr-only" />
            </label>

            <div class="ml-auto flex items-center gap-3">
              <%!-- The author's declaration of what language this post is
              written in (issue #1489, Mastodon's model): preset to the UI
              locale, quiet — the collapsed control reads "DE". The site's
              own locales lead as short codes, the curated rest follows by
              localized name. --%>
              <select
                name="post[language]"
                id={"#{@id}-language"}
                aria-label={gettext("Post language")}
                title={gettext("The language this post is written in")}
                class={[input_class(), "h-9 w-auto py-0 text-sm"]}
              >
                <option :for={code <- Languages.site_locales()} value={code} selected={@language == code}>
                  {String.upcase(code)}
                </option>
                <optgroup label={gettext("More languages")}>
                  <option
                    :for={{label, code} <- other_language_options()}
                    value={code}
                    selected={@language == code}
                  >
                    {label}
                  </option>
                </optgroup>
              </select>
              <span
                :if={@audience_locked? or @acting_as}
                id={"#{@id}-audience-locked"}
                title={
                  if(@acting_as,
                    do: gettext("A post in an organization's name is always public."),
                    else:
                      gettext("The audience cannot be restricted while reposts or replies exist.")
                  )
                }
                class="inline-flex items-center gap-1.5 rounded-lg border border-slate-200 px-3 py-2 text-sm text-slate-500 dark:border-slate-700 dark:text-slate-400"
              >
                🌐 {gettext("Public")}
              </span>

              <.button
                type="submit"
                class="h-9 px-6"
                disabled={@uploads.images.entries != []}
                phx-disable-with={gettext("Saving…")}
              >
                <%!-- The button names the author while writing as an
                organization (issue #1335), so the last thing seen before
                publishing is whose name goes on it. The mode's own banner is at
                the top of the page and may well have scrolled away by now;
                this is the reminder that cannot. --%>
                {cond do
                  @post -> gettext("Save")
                  @acting_as -> gettext("Post as %{name}", name: @acting_as.name)
                  true -> gettext("Post")
                end}
              </.button>
            </div>
          </div>

          <%!-- The "Hide from…" sheet (custom audience) --%>
          <div
            :if={@preset == "custom"}
            id={"#{@id}-audience-sheet"}
            class="mt-4 rounded-xl bg-slate-50 p-4 ring-1 ring-slate-200 dark:bg-slate-800/50 dark:ring-slate-700"
          >
            <h3 class="text-sm font-semibold uppercase tracking-wide text-slate-500">
              {gettext("Hide this post from…")}
            </h3>

            <div class="mt-3 space-y-1.5">
              <label class="flex items-center gap-2 text-sm text-slate-700 dark:text-slate-200">
                <input
                  type="checkbox"
                  name="post[deny_wildcards][non_connections]"
                  value="true"
                  checked={MapSet.member?(@deny_wildcards, "non_connections")}
                  class={checkbox_class()}
                />
                {gettext("People who aren't my connections")}
              </label>
              <label class="flex items-center gap-2 text-sm text-slate-700 dark:text-slate-200">
                <input
                  type="checkbox"
                  name="post[deny_wildcards][non_followers]"
                  value="true"
                  checked={MapSet.member?(@deny_wildcards, "non_followers")}
                  class={checkbox_class()}
                />
                {gettext("People who don't follow me")}
              </label>
              <label class="flex items-center gap-2 text-sm text-slate-700 dark:text-slate-200">
                <input
                  type="checkbox"
                  name="post[deny_wildcards][non_followees]"
                  value="true"
                  checked={MapSet.member?(@deny_wildcards, "non_followees")}
                  class={checkbox_class()}
                />
                {gettext("People I don't follow")}
              </label>
              <label class="flex items-center gap-2 text-sm text-slate-700 dark:text-slate-200">
                <input
                  type="checkbox"
                  name="post[deny_wildcards][logged_out]"
                  value="true"
                  checked={MapSet.member?(@deny_wildcards, "logged_out")}
                  class={checkbox_class()}
                />
                {gettext("Logged-out visitors")}
              </label>
            </div>

            <%!-- Per-person denials --%>
            <div :if={@denied_users != []} class="mt-3 flex flex-wrap gap-2">
              <span
                :for={user <- @denied_users}
                class="inline-flex items-center gap-2 rounded-lg bg-brand-50 px-3 py-1.5 text-sm font-medium text-brand-700 dark:bg-brand-900/40 dark:text-brand-100"
              >
                {full_name(user)}
                <button
                  type="button"
                  phx-click="undeny-user"
                  phx-value-id={user.id}
                  phx-target={@myself}
                  aria-label={gettext("Remove")}
                  class="font-bold"
                >
                  ×
                </button>
              </span>
            </div>

            <div class="relative mt-3">
              <input
                type="text"
                name="post[user_search]"
                value={@user_search}
                autocomplete="off"
                placeholder={gettext("Hide from a specific person…")}
                class={input_class()}
              />
              <ul
                :if={@user_results != []}
                class="absolute z-20 mt-1 w-full rounded-xl bg-white py-1 shadow-lg ring-1 ring-slate-200 dark:bg-slate-900 dark:ring-slate-700"
                id={"#{@id}-user-results"}
              >
                <li :for={user <- @user_results}>
                  <button
                    type="button"
                    phx-click="deny-user"
                    phx-value-id={user.id}
                    phx-target={@myself}
                    class="block w-full px-4 py-2 text-left text-sm text-slate-700 hover:bg-slate-50 dark:text-slate-200 dark:hover:bg-slate-800"
                  >
                    {full_name(user)}
                    <span class="text-xs text-slate-600 dark:text-slate-400">@{user.username}</span>
                  </button>
                </li>
              </ul>
            </div>

            <p class="mt-3 text-xs text-slate-600 dark:text-slate-400">
              {gettext(
                "As soon as anything is hidden, the post is also invisible to logged-out visitors and search engines."
              )}
            </p>
          </div>

          <p :if={@audience_locked?} class="mt-1 text-xs text-slate-600 dark:text-slate-400" id={"#{@id}-audience-lock-hint"}>
            {gettext(
              "This post has been reposted or answered. Its audience stays public while reposts or replies exist; you can still delete the post."
            )}
          </p>

          <p :if={@error} class="mt-2 text-sm font-medium text-red-600" id={"#{@id}-error"}>
            {@error}
          </p>
        </.form>
      </.card>
    </div>
    """
  end

  # What the folded details row says a visitor may save — the same wording
  # the download select's options use, so the fold and the open control can
  # never disagree.
  defp download_label("clean"), do: gettext("Original, metadata removed")
  defp download_label("exact"), do: gettext("Original, exactly as uploaded")
  defp download_label("mixed"), do: gettext("Different per photo")

  defp download_label(_none),
    do: gettext("Web versions only (%{format})", format: served_format())

  # The markdown editor plus its quiet character counter.
  attr(:id, :string, required: true)
  attr(:body, :string, required: true)
  attr(:post, :any, required: true)

  defp body_editor(assigns) do
    ~H"""
    <div>
      <.markdown_editor
        id={"#{@id}-body"}
        name="post[body]"
        value={@body}
        label={gettext("What's new?")}
        placeholder={gettext("What's new? Markdown is supported.")}
        rows={if(@post, do: 10, else: 3)}
        submit_on="cmd-enter"
        images
        help
      />

      <p :if={String.length(@body) > Post.max_body_length() - 2000} class="mt-1 text-xs text-slate-600 dark:text-slate-400">
        {delimited_count(String.length(@body))} / {delimited_count(Post.max_body_length())}
      </p>
    </div>
    """
  end

  # One photo's frame: the picture as one big options button, the badges, a
  # remove dot and the crop dot. Reordering is pointer-drag on the frame
  # (`data-photo-drag` — the PhotoStrip hook lifts the tile after a short
  # hold on touch, immediately on mouse movement, so it works on a phone
  # without the ◀ ▶ arrow dots that used to be the touch path; Stefan asked
  # for those to go). The drag zone is the frame, not the outer cell, so a
  # drag in the grid's caption inputs still selects text; the hook finds the
  # reorder unit via closest("[data-photo-tile]"). The frame takes the
  # photo's own aspect ratio — the author judges the upload by the full
  # frame, never by a square crop.
  attr(:image, :any, required: true)
  attr(:index, :integer, required: true)
  attr(:count, :integer, required: true)
  attr(:open?, :boolean, required: true)
  attr(:alt_missing?, :boolean, required: true)
  attr(:myself, :any, required: true)

  defp photo_frame(assigns) do
    assigns = assign(assigns, :ratio_style, natural_ratio(assigns.image))

    ~H"""
    <div
      data-photo-drag={@image.id}
      style={@ratio_style}
      class={[
        "group relative overflow-hidden rounded-lg ring-1",
        !@ratio_style && "aspect-square",
        (@open? && "ring-2 ring-brand-500") || "ring-slate-200 dark:ring-slate-800"
      ]}
    >
      <%!-- The picture IS the options button: the biggest target on screen,
      the first thing people try, and as a real <button> the keyboard path
      too (which is why the scrim's ⚙ could go). --%>
      <button
        type="button"
        phx-click="photo-open"
        phx-value-id={@image.id}
        phx-target={@myself}
        aria-label={gettext("Photo options")}
        title={gettext("Photo options")}
        class="block h-full w-full cursor-pointer rounded-lg focus-visible:ring-2 focus-visible:ring-brand-500"
      >
        <%!-- The natural-ratio frame needs the aspect-preserving `feed`
        version: `thumb` is itself a 320×320 centre crop (Vutuv.Uploads.Spec),
        so inside a portrait frame it would show a cut of a cut — exactly the
        "still not the full picture" complaint the frame was meant to fix. --%>
        <%!-- draggable="false": the browser's native image drag would race
        the hook's pointer drag on a mouse (components.css also disables
        WebKit's variant). --%>
        <img
          src={PostImage.url(@image, "feed")}
          alt=""
          draggable="false"
          class="h-full w-full object-cover"
        />
      </button>

      <div class="pointer-events-none absolute left-1 top-1 flex flex-col items-start gap-1">
        <%!-- The hero marker. A number on every tile would be noise; what the
        author needs to know is which photo leads — and with a single photo
        there is nothing to lead, so it stays away. --%>
        <span
          :if={@index == 0 and @count > 1}
          data-cover-badge
          class="rounded bg-slate-900/70 px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-white"
        >
          {gettext("Cover")}
        </span>

        <%!-- Says a crop is in force — the tile already shows the cropped
        frame, but a small mark answers "why is my picture suddenly square"
        at a glance and points at the button that undoes it. --%>
        <span
          :if={PostImage.cropped?(@image)}
          title={gettext("Cropped")}
          data-photo-cropped={@image.id}
          class="flex items-center rounded bg-slate-900/70 px-1.5 py-0.5 text-white"
        >
          <.crop_icon class="h-3 w-3" />
        </span>

        <%!-- The alt-text nudge: amber while a photo has no description, so
        the gap is visible without blocking anything. --%>
        <span
          :if={@alt_missing?}
          title={gettext("No image description yet")}
          class="pointer-events-auto rounded bg-amber-400/90 px-1.5 py-0.5 text-[10px] font-bold text-amber-950"
          data-photo-alt-missing={@image.id}
        >
          ALT
        </span>
      </div>

      <button
        type="button"
        phx-click="remove-image"
        phx-value-id={@image.id}
        phx-target={@myself}
        aria-label={gettext("Remove photo")}
        title={gettext("Remove photo")}
        class={["absolute right-1 top-1", tile_dot_class()]}
      >
        ✕
      </button>

      <%!-- The crop dot: opens the ratio-crop dialog (photo_crop.js via the
      PhotoStrip hook — no phx-click; the JS pushes `photo-crop` once the
      author decides). Bottom-center, between the two reorder corners. The
      dialog loads the author-only `source` workbench, so a photo that is
      already cropped still shows its whole frame to re-crop from. --%>
      <button
        type="button"
        data-photo-crop={@image.id}
        data-crop-src={"/post_images/#{@image.token}/source.avif"}
        data-crop-value={@image.crop}
        aria-label={gettext("Crop photo")}
        title={gettext("Crop photo")}
        class={["absolute bottom-1 left-1/2 -translate-x-1/2", tile_dot_class()]}
      >
        <.crop_icon class="h-4 w-4" />
      </button>

    </div>
    """
  end

  # The corner-dot recipe: finger-sized, per the phone-first rule.
  defp tile_dot_class,
    do:
      "flex h-8 w-8 items-center justify-center rounded-full bg-slate-900/60 text-sm text-white hover:bg-slate-900/80"

  # The photo's own shape as an inline aspect-ratio, so the frame is stable
  # before the thumbnail loads; a row without stored dimensions falls back to
  # the square.
  defp natural_ratio(%PostImage{width: width, height: height})
       when is_integer(width) and width > 0 and is_integer(height) and height > 0,
       do: "aspect-ratio: #{width} / #{height}"

  defp natural_ratio(_image), do: nil

  # The chip labels for the bento arrangements — the human words for the
  # catalog names in `Vutuv.Posts.GalleryLayout` (which stay English slugs in
  # the DB, like the licence keys).
  defp layout_label("pair"), do: gettext("Side by side")
  defp layout_label("lead-left"), do: gettext("Big photo left")
  defp layout_label("lead-right"), do: gettext("Big photo right")
  defp layout_label("stack"), do: gettext("Stacked")
  defp layout_label("hero-left"), do: gettext("Cover left")
  defp layout_label("hero-top"), do: gettext("Cover on top")
  defp layout_label("hero-right"), do: gettext("Cover right")
  defp layout_label("columns"), do: gettext("Columns")
  defp layout_label("grid"), do: gettext("Grid")
  defp layout_label("mosaic"), do: gettext("Mosaic")
  defp layout_label(name), do: name

  # The crop-mark glyph (two overlapping right angles, the classic crop
  # symbol) for the tile's crop dot and the "cropped" badge.
  attr(:class, :string, default: "h-4 w-4")

  defp crop_icon(assigns) do
    ~H"""
    <svg
      class={@class}
      fill="none"
      viewBox="0 0 24 24"
      stroke-width="1.8"
      stroke="currentColor"
      aria-hidden="true"
    >
      <path stroke-linecap="round" stroke-linejoin="round" d="M6 2v14a2 2 0 0 0 2 2h14" />
      <path stroke-linecap="round" stroke-linejoin="round" d="M18 22V8a2 2 0 0 0-2-2H2" />
    </svg>
    """
  end

  # The outline camera glyph (heroicons "camera") for the dropzone and the
  # add-more tile — an SVG rather than the 📷 emoji so it takes the text
  # colour and reads calm at any size.
  attr(:class, :string, default: "h-6 w-6")

  defp camera_icon(assigns) do
    ~H"""
    <svg
      class={@class}
      fill="none"
      viewBox="0 0 24 24"
      stroke-width="1.5"
      stroke="currentColor"
      aria-hidden="true"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M6.827 6.175A2.31 2.31 0 0 1 5.186 7.23c-.38.054-.757.112-1.134.175C2.999 7.58 2.25 8.507 2.25 9.574V18a2.25 2.25 0 0 0 2.25 2.25h15A2.25 2.25 0 0 0 21.75 18V9.574c0-1.067-.75-1.994-1.802-2.169a47.865 47.865 0 0 0-1.134-.175 2.31 2.31 0 0 1-1.64-1.055l-.822-1.316a2.192 2.192 0 0 0-1.736-1.039 48.774 48.774 0 0 0-5.232 0 2.192 2.192 0 0 0-1.736 1.039l-.821 1.316Z"
      />
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M16.5 12.75a4.5 4.5 0 1 1-9 0 4.5 4.5 0 0 1 9 0Z"
      />
    </svg>
    """
  end

  @doc """
  The per-photo panel: the two texts and the two opt-ins for one photo
  (issue #1104).

  It expands **below** the strip rather than floating over it as a popover.
  A popover on a phone covers the thing it is about, cannot be scrolled
  comfortably and has nowhere to put a follow-up question — and this panel has
  one (which file a download hands over). The tile it belongs to is
  ring-highlighted, so the connection is visible without the overlay.

  Both switches say what they will actually do, with the answer in front of
  the author rather than described: the camera switch shows the very line
  visitors would see, or states that this file carries none; the download
  switch reveals the choice of file and, when the photo carries a location,
  warns about it at the moment the exact file is picked.

  The download switch is the **override** of the post-wide answer the
  "Photo details" row gives, so it renders only for a set of several photos
  (`many?`) — with one photo the two controls would be the same state asked
  twice on the same screen.

  The caption input and the camera switch live inline under the tile (issue
  #1104 follow-up), not here — a second input of the same name would corrupt
  the submit. The alt input always renders here: one opt-in refinement, one
  place.
  """
  attr(:image, :any, required: true)
  attr(:settings, :map, required: true)
  attr(:many?, :boolean, required: true)
  attr(:id, :string, required: true)
  attr(:myself, :any, required: true)

  def photo_panel(assigns) do
    assigns =
      assigns
      |> assign(:cleanable?, Vutuv.PostImageStore.cleanable?(assigns.image))
      |> assign(:cropped?, PostImage.cropped?(assigns.image))

    ~H"""
    <div
      id={@id}
      class="mt-3 rounded-xl bg-slate-50 p-4 ring-1 ring-slate-200 dark:bg-slate-800/50 dark:ring-slate-700"
    >
      <div class="flex items-start gap-3">
        <img
          src={PostImage.url(@image, "thumb")}
          alt=""
          class="h-16 w-16 shrink-0 rounded-lg object-cover ring-1 ring-slate-200 dark:ring-slate-800"
        />
        <div class="min-w-0 flex-1 space-y-2">
          <input
            type="text"
            name={"photo[#{@image.id}][alt]"}
            value={@settings.alt}
            phx-debounce="300"
            placeholder={gettext("Describe the photo for people who can't see it")}
            class={input_class()}
          />
        </div>
        <button
          type="button"
          phx-click="photo-close"
          phx-target={@myself}
          aria-label={gettext("Close")}
          class="shrink-0 rounded-lg px-2 py-1 text-sm font-semibold text-slate-500 hover:bg-slate-100 dark:hover:bg-slate-800"
        >
          ✕
        </button>
      </div>

      <div class="mt-4 space-y-3">
        <%!-- The per-photo override of the post-wide download answer, and the
        one follow-up it reveals. With a single photo there is nothing to
        override — the "Photo details" select IS that photo's answer — so
        the block stays away rather than offering the same state twice. --%>
        <div :if={@many?}>
          <label class="flex items-start gap-2 text-sm text-slate-700 dark:text-slate-200">
            <input
              type="checkbox"
              checked={@settings.download_original}
              phx-click="photo-toggle"
              phx-value-id={@image.id}
              phx-value-field="download_original"
              phx-target={@myself}
              class={checkbox_class()}
              data-photo-download-switch
            />
            <span>
              <span class="font-semibold">{gettext("Everybody may download this photo")}</span>
              <span class="mt-0.5 block text-xs text-slate-600 dark:text-slate-400">
                {gettext("Full resolution, straight from the post.")}
              </span>
            </span>
          </label>

          <div :if={@settings.download_original} class="ml-6 mt-2 space-y-1.5">
            <label class="flex items-start gap-2 text-sm text-slate-700 dark:text-slate-200">
              <input
                type="radio"
                name={"photo[#{@image.id}][exact]"}
                checked={not @settings.download_exact}
                disabled={not @cleanable?}
                phx-click="photo-exact"
                phx-value-id={@image.id}
                phx-value-exact="false"
                phx-target={@myself}
                class={checkbox_class()}
              />
              <span>
                {gettext("Just the picture")}
                <span class="mt-0.5 block text-xs text-slate-600 dark:text-slate-400">
                  {gettext(
                    "Same pixels, nothing else: location and serial numbers removed, quality untouched."
                  )}
                </span>
              </span>
            </label>
            <label class="flex items-start gap-2 text-sm text-slate-700 dark:text-slate-200">
              <input
                type="radio"
                name={"photo[#{@image.id}][exact]"}
                checked={@settings.download_exact}
                disabled={@cropped?}
                phx-click="photo-exact"
                phx-value-id={@image.id}
                phx-value-exact="true"
                phx-target={@myself}
                class={checkbox_class()}
              />
              <span>
                {gettext("The file exactly as I uploaded it")}
                <span class="mt-0.5 block text-xs text-slate-600 dark:text-slate-400">
                  {gettext("Every metadata field kept, including anything your camera wrote.")}
                </span>
              </span>
            </label>

            <%!-- A cropped photo's upload still shows what the author cut
            away, so the exact file is off the table (the server enforces it;
            this says why the radio is greyed out). --%>
            <p
              :if={@cropped?}
              class="rounded-lg bg-slate-100 px-3 py-2 text-xs text-slate-600 dark:bg-slate-800 dark:text-slate-400"
              data-photo-crop-download-note
            >
              {gettext(
                "This photo is cropped: downloads hand out the cropped picture, and the untouched upload stays private."
              )}
            </p>

            <%!-- The warning that makes the choice informed. It appears at the
            moment the exact file is selected on a photo that carries a
            location — not as a standing notice nobody reads. --%>
            <p
              :if={@settings.download_exact and @image.has_gps}
              class="rounded-lg bg-amber-50 px-3 py-2 text-xs text-amber-800 ring-1 ring-amber-200 dark:bg-amber-900/30 dark:text-amber-200 dark:ring-amber-800"
              data-photo-gps-warning
            >
              {gettext(
                "This photo carries the location it was taken at. Anyone who downloads the exact file can read it."
              )}
            </p>
            <p
              :if={not @cleanable?}
              class="rounded-lg bg-amber-50 px-3 py-2 text-xs text-amber-800 ring-1 ring-amber-200 dark:bg-amber-900/30 dark:text-amber-200 dark:ring-amber-800"
            >
              {gettext(
                "This file format can only be handed out as it is. Remove the photo if that is not what you want."
              )}
            </p>
          </div>
        </div>
      </div>

      <div class="mt-4 flex flex-wrap items-center gap-3">
        <button
          type="button"
          phx-click="insert-inline"
          phx-value-id={@image.id}
          phx-target={@myself}
          class="text-sm font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
        >
          ↳ {gettext("Insert into text")}
        </button>
        <%!-- The shortcut that keeps a ten-photo set from being twenty taps.
        Only shown when there is more than one photo to apply to. --%>
        <button
          :if={@many?}
          type="button"
          phx-click="photo-apply-all"
          phx-value-id={@image.id}
          phx-target={@myself}
          class="ml-auto text-sm font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
          data-photo-apply-all
        >
          {gettext("Apply these settings to all photos")}
        </button>
      </div>
    </div>
    """
  end

  defp upload_error_message(:too_large) do
    gettext("File is larger than %{mb} MB.", mb: div(Posts.max_image_filesize(), 1_000_000))
  end

  defp upload_error_message(:not_accepted) do
    gettext("File type not supported (allowed: %{types}).",
      types: Enum.join(Vutuv.PostImageStore.extension_whitelist(), ", ")
    )
  end

  defp upload_error_message(:too_many_files), do: gettext("Too many files.")
  defp upload_error_message(_), do: gettext("Upload failed.")
end
