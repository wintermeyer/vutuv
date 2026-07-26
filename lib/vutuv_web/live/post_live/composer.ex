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

  **Two modes, one post.** The same composer serves two crowds whose needs
  point in opposite directions: the writer who staples a screenshot or two to
  a text (camera facts are noise to them), and the photographer whose post IS
  the photos (the prose is noise to them). `@mode` arranges the same fields
  for one or the other; nothing about the stored post differs. `"text"` is
  today's layout — editor first, compact photo strip below. `"photos"` leads
  with a dropzone and a large photo grid whose caption/description inputs sit
  under every photo (no panel hunting), the licence beside them, and the text
  editor folded behind one button until asked for. The mode is a **radio pair
  inside the form** (`post[mode]`), so switching is an ordinary `validate`
  (no event/race split) and form recovery restores the mode with the rest of
  the form after a reconnect. Entry points: the feed's camera trigger opens
  photos-first (`set_mode` via `send_update`), editing a photo-only post
  derives it, replies stay text-only.

  **Photos survive a reconnect.** The attached rows ride the form as hidden
  `post[image_ids][]` inputs; a re-mounted composer re-adopts the recovered,
  still-pending rows in `validate` (`Posts.pending_images/2`) — the photo
  half of issue #1130, whose text half form recovery already covered.
  """

  use VutuvWeb, :live_component

  alias Vutuv.BookMetadata
  alias Vutuv.Fediverse.Note
  alias Vutuv.Posts
  alias Vutuv.Posts.PhotoLicense
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostImage
  alias Vutuv.Posts.PostReview
  alias VutuvWeb.ErrorHelpers
  alias VutuvWeb.PostComponents

  @presets ~w(public followers connections only_me custom)
  @modes ~w(text photos)

  # The review panel's form values, kept as a plain string-keyed map (the
  # panel inputs are plain form fields; the changeset runs on save).
  @empty_review %{
    "kind" => "",
    "identifier" => "",
    "title" => "",
    "creator" => "",
    "year" => "",
    "medium" => ""
  }

  @impl true
  def update(assigns, socket) do
    socket =
      assign(
        socket,
        Map.take(assigns, [
          :id,
          :current_user,
          :post,
          :parent,
          :remote_note,
          :initial_body
        ])
      )

    socket =
      if socket.assigns[:composer_ready?] do
        socket
      else
        init_composer(socket)
      end

    # One-shot mode override from the host's two triggers (the feed's camera
    # button opens photos-first, the pill text-first). Not a template prop: a
    # prop would re-force the mode on every host re-render, undoing the
    # author's own switch. The camera always gets its way — pressing it IS
    # the request for the photo layout — while the pill, the default entry,
    # never rearranges the composer under a held draft.
    socket =
      case assigns[:set_mode] do
        "photos" ->
          assign(socket, :mode, "photos")

        "text" ->
          if drafting?(socket.assigns), do: socket, else: assign(socket, :mode, "text")

        _no_override ->
          socket
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
    |> assign(:mode, initial_mode(socket.assigns, post, images))
    # Whether photo mode's optional text editor is unfolded. It latches: once
    # the editor was on screen (asked for, or opened by an existing body), it
    # stays — deleting the last character must not fold the editor away under
    # the cursor. A reconnect that resets the flag cannot hide recovered text
    # either, since `validate` re-latches from the recovered body (#1130).
    |> assign(:text_open?, ((post && post.body) || socket.assigns[:initial_body] || "") != "")
    |> assign(:review, review_values(post))
    |> assign(:review_lookup_error, nil)
    |> assign(:tags_value, tags_value(post))
    |> assign(:images, images)
    # The per-photo settings the composer is editing (issue #1104), keyed by
    # image id. Held in the socket rather than in form fields: the two switches
    # reveal follow-up controls, and an unchecked checkbox submits nothing — so
    # driving them by event keeps "off" an actual state instead of an absence.
    |> assign(:photos, photo_state(images))
    # Which photo's panel is open; nil = none, which is the whole hobby flow.
    |> assign(:open_photo, nil)
    |> assign(:license, initial_license(post, socket.assigns.current_user))
    |> assign(:preset, preset)
    |> assign(:deny_wildcards, wildcards)
    |> assign(:denied_users, denied_users)
    |> assign(:user_search, "")
    |> assign(:user_results, [])
    |> assign(:error, nil)
    # Released once the post is saved, so the unload guard (`unsaved?/1`) stops
    # asking about content that is now safely in the database.
    |> assign(:saved?, false)
    |> allow_upload(:images,
      accept: Vutuv.PostImageStore.extension_whitelist(),
      max_entries: Posts.max_images_per_post(),
      max_file_size: Posts.max_image_filesize(),
      auto_upload: true,
      progress: &handle_progress/3
    )
  end

  defp tags_value(nil), do: ""
  defp tags_value(post), do: Enum.map_join(post.tags, ", ", & &1.name)

  defp post_images(nil), do: []
  defp post_images(%Post{images: images}) when is_list(images), do: images
  defp post_images(_post), do: []

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

  # Edit mode prefills the panel from the stored review; the panel is open
  # exactly when a kind is set.
  defp review_values(%Post{review: %PostReview{} = review}) do
    %{
      "kind" => review.kind,
      "identifier" => review.identifier || "",
      "title" => review.title || "",
      "creator" => review.creator || "",
      "year" => if(review.year, do: Integer.to_string(review.year), else: ""),
      "medium" => review.medium || ""
    }
  end

  defp review_values(_post), do: @empty_review

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
      |> assign(:mode, resolve_mode(params, socket.assigns))
      # The latch half of `show_editor?/3`: once a body existed, photo mode's
      # editor stays unfolded even after the author deletes the last character
      # (folding it away under the cursor would read as data loss) — and a
      # recovered body re-latches it after a reconnect (#1130).
      |> assign(:text_open?, socket.assigns.text_open? or body != "")
      |> assign(:tags_value, params["tags"] || socket.assigns.tags_value)
      |> assign(:license, PhotoLicense.cast(params["license"] || socket.assigns.license))
      |> assign(:review, Map.merge(socket.assigns.review, params["review"] || %{}))
      |> assign(:preset, resolve_preset(params, socket.assigns))
      |> assign(:error, nil)
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

    {:noreply, announce_draft(socket, drafting_before?)}
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

  # The 📖/🎬 buttons open the review panel with that kind; the panel's ✕
  # sets it back to "" (which deletes a stored review on save). The other
  # field values survive a toggle, so an accidental close loses nothing.
  def handle_event("review-kind", %{"kind" => kind}, socket) do
    if kind in ["" | PostReview.kinds()] do
      # The medium is per-kind (audiobook vs. cinema), so it resets on a
      # switch; every other field survives an accidental toggle.
      review = %{socket.assigns.review | "kind" => kind, "medium" => ""}

      {:noreply,
       socket
       |> assign(:review, review)
       |> assign(:review_lookup_error, nil)}
    else
      {:noreply, socket}
    end
  end

  # The ISBN lookup (book panel only, rendered only with :fetch_book_metadata
  # on): prefills title/creator/year from Open Library. Everything stays
  # editable — the lookup is convenience, not truth.
  def handle_event("review-lookup", _params, socket) do
    review = socket.assigns.review

    with {:ok, isbn} <- Vutuv.Isbn.normalize(review["identifier"] || ""),
         {:ok, data} <- BookMetadata.lookup(isbn) do
      filled =
        Map.merge(review, %{
          "identifier" => isbn,
          "title" => data.title,
          "creator" => data.creator || review["creator"],
          "year" => if(data.year, do: Integer.to_string(data.year), else: review["year"])
        })

      {:noreply, socket |> assign(:review, filled) |> assign(:review_lookup_error, nil)}
    else
      :error ->
        {:noreply,
         assign(
           socket,
           :review_lookup_error,
           gettext("Nothing found for this ISBN. Please fill in the fields yourself.")
         )}
    end
  end

  def handle_event("insert-inline", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.images, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      image ->
        {:noreply, push_event(socket, "mde-insert-image", editor_image_payload(socket, image))}
    end
  end

  ## Photo strip and panel (issue #1104)

  # Photo mode's folded text editor unfolds on request; a non-empty body keeps
  # it open without this flag (see `show_editor?/3`).
  def handle_event("show-text", _params, socket) do
    {:noreply, assign(socket, :text_open?, true)}
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
     end)}
  end

  def handle_event("photo-exact", %{"id" => id, "exact" => exact}, socket) do
    {:noreply, update_photo(socket, id, &Map.put(&1, :download_exact, exact == "true"))}
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

        {:noreply, assign(socket, :photos, photos)}
    end
  end

  # The ◀ ▶ buttons: the reorder path on touch, where a native HTML5 drag
  # cannot fire at all.
  def handle_event("photo-move", %{"id" => id, "dir" => dir}, socket) do
    images = socket.assigns.images
    index = Enum.find_index(images, &(&1.id == id))
    target = if dir == "back", do: index && index - 1, else: index && index + 1

    if index && target >= 0 && target < length(images) do
      moved = images |> List.delete_at(index) |> List.insert_at(target, Enum.at(images, index))
      {:noreply, assign(socket, :images, moved)}
    else
      {:noreply, socket}
    end
  end

  # The drag path (the `PhotoStrip` hook pushes the id order it has already
  # applied in the DOM). Ids are looked up rather than trusted: an order naming
  # an unknown id must not be able to drop photos from the post.
  def handle_event("photo-reorder", %{"order" => order}, socket) when is_list(order) do
    by_id = Map.new(socket.assigns.images, &{&1.id, &1})
    reordered = Enum.flat_map(order, fn id -> List.wrap(by_id[id]) end)
    missing = Enum.reject(socket.assigns.images, &(&1.id in order))

    {:noreply, assign(socket, :images, reordered ++ missing)}
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
         )}
    end
  end

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :images, ref)}
  end

  # Photo mode's ✕: a real discard, not a collapse. Closing over invisible
  # uploaded photos meant the next "Write a post" surprised people with last
  # week's pictures, so the pending rows die now (their files with them), the
  # form resets, and the feed collapses the panel. Only the feed composer
  # renders the ✕, so the host always has the handle_info.
  def handle_event("discard-draft", _params, socket) do
    Enum.each(socket.assigns.images, fn image ->
      if is_nil(image.post_id), do: Posts.delete_pending_image(image)
    end)

    send(self(), {:composer_discarded, socket.assigns.id})

    {:noreply, reset_composer(socket)}
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
      # The submitted panel fields are the truth; with the panel closed only
      # the hidden kind ("") arrives, which removes a stored review on save.
      review: params["review"] || %{"kind" => ""},
      denials: denials_payload(socket.assigns),
      image_ids: Enum.map(socket.assigns.images, & &1.id)
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

  # What a reload would throw away (issue #1148) — the answer the `DraftGuard`
  # hook turns into the browser's "Leave site?" prompt. Deliberately *not*
  # `drafting?/1`: on the edit page the composer opens full of the stored post,
  # so "there is text in it" would arm the guard on every visit, and a prompt
  # that fires when nothing is at stake is one people learn to click away.
  # What counts is the difference between the form and the state it opened in.
  #
  # A quote the reply page seeded (`initial_body`) is part of that opening
  # state: the reader did not type it, and it comes back from the URL anyway.
  # Audience, licence and the per-photo settings are left out — nobody sets
  # them without also having content, which is caught here already.
  defp unsaved?(%{saved?: true}), do: false

  defp unsaved?(assigns), do: composer_state(assigns) != opened_state(assigns)

  defp composer_state(assigns) do
    %{
      body: assigns.body,
      tags: assigns.tags_value,
      image_ids: Enum.map(assigns.images, & &1.id),
      review: assigns.review
    }
  end

  defp opened_state(%{post: post} = assigns) do
    %{
      body: (post && post.body) || assigns[:initial_body] || "",
      tags: tags_value(post),
      image_ids: Enum.map(post_images(post), & &1.id),
      review: review_values(post)
    }
  end

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

  # The mode radios live inside the form, so a switch is just a validate —
  # and form recovery replays the checked radio after a reconnect. Replies
  # never switch (their composer is a conversation turn, not a gallery).
  defp resolve_mode(params, assigns) do
    if params["mode"] in @modes and mode_switchable?(assigns),
      do: params["mode"],
      else: assigns.mode
  end

  # Replies (local and remote) stay text-first: their composer is a turn in a
  # conversation, not a gallery.
  defp mode_switchable?(assigns), do: is_nil(assigns.parent) and is_nil(assigns.remote_note)

  defp initial_mode(host_assigns, post, images) do
    cond do
      host_assigns[:parent] != nil or host_assigns[:remote_note] != nil -> "text"
      post != nil and images != [] and (post.body || "") == "" -> "photos"
      true -> "text"
    end
  end

  # Photo mode folds the editor away until asked for — but a body always keeps
  # it open, so recovered text (#1130) can never sit invisible in a hidden
  # field.
  defp show_editor?(mode, body, text_open?), do: mode == "text" or body != "" or text_open?

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

  defp feed_composer?(assigns),
    do: is_nil(assigns.post) and is_nil(assigns.parent) and is_nil(assigns.remote_note)

  # Answering a reply from another network goes through its own context function:
  # it writes the sidecar that carries the answer out to that network, and it
  # holds the federation gates (issue #1070).
  defp save_post(%{post: nil, remote_note: %Note{} = note, current_user: author}, attrs),
    do: Posts.create_remote_reply(author, note, attrs)

  defp save_post(%{post: nil, parent: %Post{} = parent, current_user: author}, attrs),
    do: Posts.create_reply(author, parent, attrs)

  defp save_post(%{post: nil, current_user: author}, attrs), do: Posts.create_post(author, attrs)
  defp save_post(%{post: post}, attrs), do: Posts.update_post(post, attrs)

  defp handle_save_result({:ok, post}, socket) do
    # The post is in the database, so there is nothing left to warn about —
    # release the unload guard before we hand over. The three navigating
    # branches below need this: the permalink they push to is a controller
    # page, so LiveView's `live_redirect` degrades into a full page load, and
    # a still-armed guard would greet the author with "Leave site?" for the
    # post they just published. LiveView pushes a component's diff *before*
    # its redirect, so the browser sees the released marker in time.
    socket = assign(socket, :saved?, true)

    cond do
      socket.assigns.post ->
        {:noreply, push_navigate(socket, to: Posts.path(post))}

      socket.assigns[:remote_note] ->
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

  # Back to an empty form: after a successful post, and after photo mode's ✕
  # discards a draft. Mode and audience choice stick on purpose, and the
  # unload guard re-arms for whatever gets typed next (`saved?` back to
  # false, issue #1148) — the form is empty now, so it stays quiet.
  defp reset_composer(socket) do
    socket
    |> assign(:body, "")
    |> assign(:tags_value, "")
    |> assign(:review, @empty_review)
    |> assign(:review_lookup_error, nil)
    |> assign(:images, [])
    |> assign(:photos, %{})
    |> assign(:open_photo, nil)
    |> assign(:text_open?, false)
    |> assign(:saved?, false)
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

  defp save_error_message(:instance_blocked),
    do: gettext("That server is blocked on this site, so no answer can be sent to it.")

  defp save_error_message(:note_not_public),
    do: gettext("This reply was sent to you alone, so it cannot be answered publicly.")

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
             )}

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
  # traverse_errors walks nested changesets too, so a review-field error (an
  # invalid ISBN, say) surfaces instead of failing silently.
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
    ~H"""
    <%!-- `data-draft-unsaved` is the whole unload guard (issue #1148): the
    `DraftGuard` hook in app.js reads it when the browser is about to leave the
    page and, while it says "true", asks the member first. The decision is made
    here rather than by inspecting the DOM because the composer already holds
    both halves of it — what is in the form now, and what the post looked like
    when it opened. --%>
    <div
      id={@id}
      data-composer-mode={@mode}
      phx-hook="DraftGuard"
      data-draft-unsaved={to_string(unsaved?(assigns))}
    >
      <.card>
        <.form
          for={to_form(%{}, as: :post)}
          id={"#{@id}-form"}
          phx-submit="save"
          phx-change="validate"
          phx-target={@myself}
        >
          <%!-- Header row: the text/photos mode switch (a radio pair riding
          the form, so switching is an ordinary validate and form recovery
          restores it), and — feed compose only — the corner ✕ that collapses
          the composer. The ✕ carries no phx-target: the event bubbles up to
          the feed LiveView that owns the reveal (`close-composer`). The edit,
          reply and remote-reply pages navigate away instead, so they must
          never render it (the remote-reply page has no handler and a click
          there crashed the page). --%>
          <div
            :if={mode_switchable?(assigns) or (@post == nil and @parent == nil and @remote_note == nil)}
            class="mb-2 flex items-start justify-between gap-3"
          >
            <div
              :if={mode_switchable?(assigns)}
              role="radiogroup"
              aria-label={gettext("Post type")}
              class="inline-flex items-center gap-1 rounded-lg bg-slate-100 p-1 text-sm dark:bg-slate-800"
            >
              <.mode_tab id={"#{@id}-mode-text"} value="text" active={@mode == "text"}>
                {gettext("Text")}
              </.mode_tab>
              <.mode_tab id={"#{@id}-mode-photos"} value="photos" active={@mode == "photos"}>
                {gettext("Photos")}
              </.mode_tab>
            </div>

            <%!-- The ✕ means two different things by mode, and says so via
            its tooltip: a TEXT draft survives a close (issue #1135 — the
            composer only collapses, `close-composer` bubbling to the feed),
            while a PHOTO draft is really discarded (`discard-draft`, handled
            here): collapsing over invisible uploaded photos meant the next
            "Write a post" surprised people with last week's pictures. The
            confirm guards the destructive half, and only when there is
            something to lose. --%>
            <button
              :if={@post == nil and @parent == nil and @remote_note == nil}
              type="button"
              phx-click={if @mode == "photos", do: "discard-draft", else: "close-composer"}
              phx-target={if @mode == "photos", do: @myself}
              data-confirm={
                if @mode == "photos" and drafting?(assigns),
                  do: gettext("Discard the photos and text of this draft?")
              }
              aria-label={if @mode == "photos", do: gettext("Discard draft"), else: gettext("Close")}
              title={if @mode == "photos", do: gettext("Discard draft"), else: gettext("Close")}
              class="-mr-2 -mt-1 ml-auto rounded-lg px-3 py-2 text-sm font-semibold text-slate-500 hover:bg-slate-100 hover:text-slate-700 dark:text-slate-400 dark:hover:bg-slate-800 dark:hover:text-slate-200"
            >
              ✕
            </button>
          </div>

          <%!-- One line saying what this mode IS, for everyone who lands here
          from the camera button without a mental model of the two modes. --%>
          <p
            :if={@mode == "photos"}
            data-photo-mode-hint
            class="mb-3 text-xs text-slate-600 dark:text-slate-400"
          >
            {gettext(
              "A photo post shows your pictures big and first; text is optional. For a post that is mainly text, switch to \"Text\"."
            )}
          </p>

          <%!-- Text mode leads with the editor. Photo mode renders the same
          editor below the photos instead (one instance at a time, so the ids
          never collide). --%>
          <.body_editor :if={@mode == "text"} id={@id} body={@body} post={@post} mode={@mode} />

          <%!-- The compact photo strip (text mode, issue #1104). Drop photos
          and press Post is the whole flow; everything else is opt-in and one
          tap away. Tiles are drag-reorderable on a pointer device and ◀ ▶
          reorderable everywhere (touch cannot fire native HTML5 drag), and
          the first tile is marked the one that leads the mosaic, so ordering
          is the only layout control there is. --%>
          <div
            :if={@mode == "text" and @images != []}
            id={"#{@id}-images"}
            phx-hook="PhotoStrip"
            phx-target={@myself}
            class="mt-3 grid grid-cols-3 gap-2 sm:grid-cols-5"
          >
            <%!-- Each tile carries a DOM id so morphdom keys it: a drag has
            already moved the node when the server's re-render arrives, and the
            patch then just settles it (the profile reorder tool's pattern). --%>
            <div
              :for={{image, index} <- Enum.with_index(@images)}
              id={"#{@id}-photo-#{image.id}"}
              data-photo-tile={image.id}
            >
              <.photo_frame
                image={image}
                index={index}
                count={length(@images)}
                open?={@open_photo == image.id}
                alt_missing?={photo_described?(@photos, image) == false}
                myself={@myself}
              />
            </div>
          </div>

          <%!-- The photo grid (photo mode): the photos ARE the post, so they
          come large, with their caption and description in plain sight under
          every tile — nothing to hunt for behind ⚙, which keeps only the
          rarer switches (camera line, download). The grid is also the drop
          target, and adding more is a tile of its own, the way every photo
          tool does it. --%>
          <div
            :if={@mode == "photos"}
            id={"#{@id}-images"}
            phx-hook="PhotoStrip"
            phx-target={@myself}
            phx-drop-target={@uploads.images.ref}
            class="mt-1 grid grid-cols-2 gap-3 sm:grid-cols-3"
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
                natural?
                roomy?
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

            <%!-- Adding more photos is a tile among tiles; an empty grid is
            one big dropzone instead. Only one of the two renders, so the
            upload input exists exactly once. --%>
            <label
              :if={@images != []}
              data-photo-add-tile
              class="flex aspect-square cursor-pointer flex-col items-center justify-center gap-1.5 rounded-lg border-2 border-dashed border-slate-300 text-slate-600 hover:border-brand-400 hover:bg-brand-50/50 hover:text-brand-700 dark:border-slate-700 dark:text-slate-400 dark:hover:border-brand-500 dark:hover:bg-brand-900/20 dark:hover:text-brand-200"
            >
              <.camera_icon class="h-6 w-6" />
              <span class="px-2 text-center text-xs font-semibold">{gettext("Add photos")}</span>
              <.live_file_input upload={@uploads.images} class="sr-only" />
            </label>

            <label
              :if={@images == []}
              data-photo-dropzone
              class="col-span-full flex h-44 cursor-pointer flex-col items-center justify-center gap-2 rounded-xl border-2 border-dashed border-slate-300 text-slate-600 hover:border-brand-400 hover:bg-brand-50/50 hover:text-brand-700 dark:border-slate-700 dark:text-slate-400 dark:hover:border-brand-500 dark:hover:bg-brand-900/20 dark:hover:text-brand-200"
            >
              <.camera_icon class="h-8 w-8" />
              <span class="px-4 text-center text-sm font-semibold">
                {gettext("Select photos, or drag them here")}
              </span>
              <span class="px-4 text-center text-xs">
                {gettext("Up to %{max} photos per post", max: Posts.max_images_per_post())}
              </span>
              <.live_file_input upload={@uploads.images} class="sr-only" />
            </label>
          </div>

          <p
            :if={length(@images) > 1}
            class="mt-1.5 text-xs text-slate-600 dark:text-slate-400"
          >
            {gettext("Drag to reorder. The first photo leads the gallery.")}
          </p>

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
            caption?={@mode == "text"}
            camera?={@mode == "text"}
            insert?={@mode == "text"}
            id={"#{@id}-photo-panel"}
            myself={@myself}
          />

          <%!-- Who may reuse the photos — one quiet labeled row, at home with
          the photos it is about instead of loose in the button row (where it
          read as a control about nothing, issue #1104 feedback). --%>
          <div :if={@images != []} class="mt-3 flex flex-wrap items-center gap-x-3 gap-y-1">
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

          <%!-- Photo mode: the optional words come after the pictures, folded
          behind one button until asked for. A non-empty body keeps the editor
          open on its own (recovered text must never hide, #1130). --%>
          <div :if={@mode == "photos"} class="mt-3">
            <button
              :if={not show_editor?(@mode, @body, @text_open?)}
              type="button"
              id={"#{@id}-add-text"}
              phx-click="show-text"
              phx-target={@myself}
              class="inline-flex h-9 items-center gap-1.5 rounded-lg bg-slate-100 px-3 text-sm font-semibold text-slate-700 hover:bg-slate-200 dark:bg-slate-800 dark:text-slate-200 dark:hover:bg-slate-700"
            >
              ✏️ {gettext("Add text (optional)")}
            </button>

            <.body_editor
              :if={show_editor?(@mode, @body, @text_open?)}
              id={@id}
              body={@body}
              post={@post}
              mode={@mode}
            />
          </div>

          <%!-- Tags get their own full-width row. --%>
          <input
            type="text"
            name="post[tags]"
            value={@tags_value}
            placeholder={
              gettext("Tags, comma- or space-separated (max. %{max})",
                max: Posts.max_tags_per_post()
              )
            }
            class={[input_class(), "mt-3"]}
          />

          <%!-- The review sidecar (book/film review, Vutuv.Posts.PostReview).
          The hidden kind always submits — closing the panel deletes a stored
          review on save; the panel fields join it while open. --%>
          <input type="hidden" name="post[review][kind]" value={@review["kind"]} />

          <%!-- The attached photos as data: form recovery replays these ids
          after a reconnect, and `adopt_recovered_images/2` re-adopts the
          pending rows the re-mount dropped from socket state. --%>
          <input :for={image <- @images} type="hidden" name="post[image_ids][]" value={image.id} />

          <div
            :if={@review["kind"] != ""}
            id={"#{@id}-review-panel"}
            class="mt-4 rounded-xl bg-slate-50 p-4 ring-1 ring-slate-200 dark:bg-slate-800/50 dark:ring-slate-700"
          >
            <div class="flex items-center justify-between gap-3">
              <h3 class="text-sm font-semibold uppercase tracking-wide text-slate-500">
                {if @review["kind"] == "movie",
                  do: "🎬 " <> gettext("Film review"),
                  else: "📖 " <> gettext("Book review")}
              </h3>
              <button
                type="button"
                phx-click="review-kind"
                phx-value-kind=""
                phx-target={@myself}
                class="text-sm font-semibold text-slate-500 hover:text-red-600 dark:text-slate-400"
              >
                ✕ {gettext("Remove review")}
              </button>
            </div>

            <div class="mt-3 flex gap-2">
              <input
                type="text"
                name="post[review][identifier]"
                value={@review["identifier"]}
                placeholder={
                  if @review["kind"] == "movie",
                    do: gettext("IMDb link or ID"),
                    else: gettext("ISBN")
                }
                class={[input_class(), "flex-1"]}
              />
              <button
                :if={@review["kind"] == "book" and BookMetadata.enabled?()}
                type="button"
                id={"#{@id}-review-lookup"}
                phx-click="review-lookup"
                phx-target={@myself}
                phx-disable-with={gettext("Looking up…")}
                class="shrink-0 rounded-lg bg-slate-100 px-3 py-2 text-sm font-semibold text-slate-700 hover:bg-slate-200 dark:bg-slate-800 dark:text-slate-200 dark:hover:bg-slate-700"
              >
                {gettext("Look up")}
              </button>
            </div>
            <p :if={@review_lookup_error} class="mt-1 text-sm text-red-600">
              {@review_lookup_error}
            </p>

            <div class="mt-3 grid gap-3 sm:grid-cols-2">
              <input
                type="text"
                name="post[review][title]"
                value={@review["title"]}
                placeholder={gettext("Title")}
                class={input_class()}
              />
              <input
                type="text"
                name="post[review][creator]"
                value={@review["creator"]}
                placeholder={
                  if @review["kind"] == "movie", do: gettext("Director"), else: gettext("Author(s)")
                }
                class={input_class()}
              />
            </div>

            <div class="mt-3 grid gap-3 sm:grid-cols-2">
              <input
                type="text"
                name="post[review][year]"
                value={@review["year"]}
                inputmode="numeric"
                placeholder={gettext("Year")}
                class={input_class()}
              />
              <select name="post[review][medium]" class={input_class()}>
                <option value="">
                  {if @review["kind"] == "movie",
                    do: gettext("Watched as… (optional)"),
                    else: gettext("Read as… (optional)")}
                </option>
                <option
                  :for={medium <- PostReview.media(@review["kind"])}
                  value={medium}
                  selected={@review["medium"] == medium}
                >
                  {PostComponents.review_medium_label(medium)}
                </option>
              </select>
            </div>

            <p :if={@review["kind"] == "book"} class="mt-2 text-xs text-slate-600 dark:text-slate-400">
              {gettext("With an ISBN, the post shows the book cover and a shop link automatically.")}
            </p>
          </div>

          <%!-- Bottom row: the image picker on the left (text mode; photo mode
          adds photos in the grid itself), the (slightly wider) submit button
          on the right. New posts publish public, so there is no audience
          picker here; a post pinned public by reposts/replies still shows the
          read-only lock chip beside the button. --%>
          <div class="mt-3 flex items-center gap-3">
            <%!-- h-9 pins this to the Post button's height (both 36px, the
            standard control height): the 📷 emoji would otherwise inflate the
            line box, and mb-0 drops the global `label` margin (components.css)
            that would offset it in this row. --%>
            <label
              :if={@mode == "text"}
              class="inline-flex h-9 mb-0 cursor-pointer items-center gap-1.5 rounded-lg bg-slate-100 px-3 text-sm font-semibold text-slate-700 hover:bg-slate-200 dark:bg-slate-800 dark:text-slate-200 dark:hover:bg-slate-700"
            >
              📷 {gettext("Add images")}
              <.live_file_input upload={@uploads.images} class="sr-only" />
            </label>

            <%!-- Review triggers: open the book/film review panel. Emoji-only
            on phones (the row is tight there), labeled from sm up. Text mode
            only — a photo post is not a review, and photo mode's job is to
            carry nothing the photographer does not need. --%>
            <button
              :if={@mode == "text" and @review["kind"] == ""}
              type="button"
              phx-click="review-kind"
              phx-value-kind="book"
              phx-target={@myself}
              title={gettext("Review a book")}
              aria-label={gettext("Review a book")}
              class="inline-flex h-9 items-center gap-1.5 rounded-lg bg-slate-100 px-3 text-sm font-semibold text-slate-700 hover:bg-slate-200 dark:bg-slate-800 dark:text-slate-200 dark:hover:bg-slate-700"
            >
              📖<span class="hidden sm:inline">{gettext("Book")}</span>
            </button>
            <button
              :if={@mode == "text" and @review["kind"] == ""}
              type="button"
              phx-click="review-kind"
              phx-value-kind="movie"
              phx-target={@myself}
              title={gettext("Review a film")}
              aria-label={gettext("Review a film")}
              class="inline-flex h-9 items-center gap-1.5 rounded-lg bg-slate-100 px-3 text-sm font-semibold text-slate-700 hover:bg-slate-200 dark:bg-slate-800 dark:text-slate-200 dark:hover:bg-slate-700"
            >
              🎬<span class="hidden sm:inline">{gettext("Film")}</span>
            </button>

            <div class="ml-auto flex items-center gap-3">
              <span
                :if={@audience_locked?}
                id={"#{@id}-audience-locked"}
                title={gettext("The audience cannot be restricted while reposts or replies exist.")}
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
                {if @post, do: gettext("Save"), else: gettext("Post")}
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

  # One tab of the text/photos mode switch: a label styled like the segmented
  # post-filter tabs, wrapping a real radio (`post[mode]`) so a switch is an
  # ordinary form change and recovery restores it. The sr-only radio keeps
  # keyboard semantics; `has-[:focus-visible]` paints the focus ring on the
  # visible label in its place.
  attr(:id, :string, required: true)
  attr(:value, :string, required: true)
  attr(:active, :boolean, required: true)
  slot(:inner_block, required: true)

  defp mode_tab(assigns) do
    ~H"""
    <label class={[
      "cursor-pointer whitespace-nowrap rounded-md px-3 py-1.5",
      "has-[:focus-visible]:ring-2 has-[:focus-visible]:ring-brand-500",
      (@active &&
         "bg-white font-semibold text-brand-700 shadow-sm dark:bg-slate-900 dark:text-brand-100") ||
        "font-medium text-slate-600 hover:text-slate-900 dark:text-slate-400 dark:hover:text-slate-100"
    ]}>
      <input type="radio" id={@id} name="post[mode]" value={@value} checked={@active} class="sr-only" />
      {render_slot(@inner_block)}
    </label>
    """
  end

  # The markdown editor plus its quiet character counter — rendered in one of
  # two places (text mode up top, photo mode below the photos), never both,
  # so the DOM ids stay unique.
  attr(:id, :string, required: true)
  attr(:body, :string, required: true)
  attr(:post, :any, required: true)
  attr(:mode, :string, required: true)

  defp body_editor(assigns) do
    ~H"""
    <div>
      <.markdown_editor
        id={"#{@id}-body"}
        name="post[body]"
        value={@body}
        label={if(@mode == "photos", do: gettext("Text (optional)"), else: gettext("What's new?"))}
        placeholder={gettext("What's new? Markdown is supported.")}
        rows={if(@post, do: 10, else: 3)}
        images
      />

      <p :if={String.length(@body) > Post.max_body_length() - 2000} class="mt-1 text-xs text-slate-600 dark:text-slate-400">
        {delimited_count(String.length(@body))} / {delimited_count(Post.max_body_length())}
      </p>
    </div>
    """
  end

  # One photo's frame: the picture as one big options button, the badges, a
  # remove dot and (only when there is an order to change) the two reorder
  # dots — shared by the text-mode strip and the photo-mode grid, which
  # differ around it (tile size, inline inputs) but not in it. The old
  # four-button bottom scrim is gone: with a single photo it was two dead
  # arrows plus a ⚙ the picture-tap already covers. `draggable` sits here
  # rather than on the outer cell so a drag in the grid's caption inputs
  # selects text instead of starting a photo drag; the PhotoStrip hook finds
  # the reorder unit via closest("[data-photo-tile]") either way. `natural?`
  # sizes the frame to the photo's own aspect ratio (photo mode — a
  # photographer judges the upload by the full frame), while the compact
  # text strip keeps its uniform squares. `roomy?` grows the corner dots to
  # finger size; the strip's small tiles get the compact variant.
  attr(:image, :any, required: true)
  attr(:index, :integer, required: true)
  attr(:count, :integer, required: true)
  attr(:open?, :boolean, required: true)
  attr(:alt_badge?, :boolean, default: true)
  attr(:alt_missing?, :boolean, required: true)
  attr(:natural?, :boolean, default: false)
  attr(:roomy?, :boolean, default: false)
  attr(:myself, :any, required: true)

  defp photo_frame(assigns) do
    assigns = assign(assigns, :ratio_style, assigns.natural? && natural_ratio(assigns.image))

    ~H"""
    <div
      draggable="true"
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
        "still not the full picture" complaint the frame was meant to fix.
        The square strip keeps the light thumb. --%>
        <img
          src={PostImage.url(@image, if(@natural?, do: "feed", else: "thumb"))}
          alt=""
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

        <%!-- The alt-text nudge: amber while a photo has no description, so
        the gap is visible without blocking anything. --%>
        <span
          :if={@alt_badge? and @alt_missing?}
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
        class={["absolute right-1 top-1", tile_dot_class(@roomy?)]}
      >
        ✕
      </button>

      <%!-- Reorder, only when there is an order: the end positions simply
      drop their arrow instead of showing a dead one. Touch cannot fire
      native HTML5 drag, so these stay the reorder path on a phone. --%>
      <button
        :if={@count > 1 and @index > 0}
        type="button"
        phx-click="photo-move"
        phx-value-id={@image.id}
        phx-value-dir="back"
        phx-target={@myself}
        aria-label={gettext("Move photo earlier")}
        class={["absolute bottom-1 left-1", tile_dot_class(@roomy?)]}
      >
        ◀
      </button>
      <button
        :if={@count > 1 and @index < @count - 1}
        type="button"
        phx-click="photo-move"
        phx-value-id={@image.id}
        phx-value-dir="forward"
        phx-target={@myself}
        aria-label={gettext("Move photo later")}
        class={["absolute bottom-1 right-1", tile_dot_class(@roomy?)]}
      >
        ▶
      </button>
    </div>
    """
  end

  # The corner-dot recipe: finger-sized in the photo grid (roomy), compact in
  # the text strip whose small tiles cannot fit 40px targets.
  defp tile_dot_class(true),
    do:
      "flex h-8 w-8 items-center justify-center rounded-full bg-slate-900/60 text-sm text-white hover:bg-slate-900/80"

  defp tile_dot_class(false),
    do:
      "flex h-6 w-6 items-center justify-center rounded-full bg-slate-900/60 text-xs text-white hover:bg-slate-900/80"

  # The photo's own shape as an inline aspect-ratio, so the frame is stable
  # before the thumbnail loads; a row without stored dimensions falls back to
  # the square.
  defp natural_ratio(%PostImage{width: width, height: height})
       when is_integer(width) and width > 0 and is_integer(height) and height > 0,
       do: "aspect-ratio: #{width} / #{height}"

  defp natural_ratio(_image), do: nil

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

  Photo mode moves two things out of here to where they are seen (issue
  #1104 follow-up): `caption?` drops the caption input (it sits under every
  tile there, and a second input of the same name would corrupt the submit)
  and `camera?` drops the camera block (the inline row under the tile owns
  it). The alt input always renders here — one opt-in refinement, one place.
  `insert?` drops the "Insert into text" action (photo mode may have no
  editor on screen to insert into).
  """
  attr(:image, :any, required: true)
  attr(:settings, :map, required: true)
  attr(:many?, :boolean, required: true)
  attr(:caption?, :boolean, default: true)
  attr(:camera?, :boolean, default: true)
  attr(:insert?, :boolean, default: true)
  attr(:id, :string, required: true)
  attr(:myself, :any, required: true)

  def photo_panel(assigns) do
    assigns =
      assigns
      |> assign(:camera_line, PostComponents.camera_line(assigns.image))
      |> assign(:camera_info?, PostImage.camera_info?(assigns.image))
      |> assign(:cleanable?, Vutuv.PostImageStore.cleanable?(assigns.image))

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
            :if={@caption?}
            type="text"
            name={"photo[#{@image.id}][caption]"}
            value={@settings.caption}
            phx-debounce="300"
            placeholder={gettext("Caption, shown under the photo (optional)")}
            class={input_class()}
          />
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
        <%!-- Camera info. The switch is disabled when there is nothing to
        show, and says so — a dead toggle with no explanation reads as a bug.
        Photo mode drops the whole block: the inline row under the tile owns
        the switch there. --%>
        <div :if={@camera?}>
          <label class={[
            "flex items-start gap-2 text-sm",
            (@camera_info? && "text-slate-700 dark:text-slate-200") ||
              "text-slate-500 dark:text-slate-500"
          ]}>
            <input
              type="checkbox"
              checked={@settings.show_camera_info}
              disabled={not @camera_info?}
              phx-click="photo-toggle"
              phx-value-id={@image.id}
              phx-value-field="show_camera_info"
              phx-target={@myself}
              class={checkbox_class()}
              data-photo-camera-switch
            />
            <span>
              <span class="font-semibold">{gettext("Show camera settings")}</span>
              <span
                :if={@camera_info?}
                class="mt-0.5 block text-xs text-slate-600 dark:text-slate-400"
              >
                {@camera_line}
              </span>
              <span :if={not @camera_info?} class="mt-0.5 block text-xs">
                {gettext("This file carries no camera information.")}
              </span>
            </span>
          </label>
        </div>

        <%!-- Original download, and the one follow-up it reveals. --%>
        <div>
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
          :if={@insert?}
          type="button"
          phx-click="insert-inline"
          phx-value-id={@image.id}
          phx-target={@myself}
          class="text-sm font-semibold text-brand-600 hover:text-brand-700"
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
          class="ml-auto text-sm font-semibold text-brand-600 hover:text-brand-700"
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
