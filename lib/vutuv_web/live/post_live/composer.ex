defmodule VutuvWeb.PostLive.Composer do
  @moduledoc """
  The post composer, used by the feed (new posts), the edit page and the
  reply page (pass `parent` to create the post as a reply via
  `Vutuv.Posts.create_reply/3`).

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
      assign(socket, Map.take(assigns, [:id, :current_user, :post, :parent, :remote_note]))

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
    # Reposted or answered posts carry other people's shares and replies:
    # the audience is pinned to public (Posts.update_post/2 enforces it; the
    # select disappears).
    |> assign(
      :audience_locked?,
      post != nil and (Posts.has_reposts?(post) or Posts.has_replies?(post))
    )
    |> assign(:body, (post && post.body) || "")
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
    # New posts publish public (there is no audience picker); the fallback to the
    # current preset keeps an edited restricted post from silently downgrading to
    # public as the author types.
    preset = if params["preset"] in @presets, do: params["preset"], else: socket.assigns.preset

    socket =
      socket
      |> assign(:body, params["body"] || socket.assigns.body)
      |> assign(:tags_value, params["tags"] || socket.assigns.tags_value)
      |> assign(:license, PhotoLicense.cast(params["license"] || socket.assigns.license))
      |> assign(:review, Map.merge(socket.assigns.review, params["review"] || %{}))
      |> assign(:preset, preset)
      |> assign(:error, nil)
      |> merge_photo_texts(payload["photo"])
      |> sweep_rejected_uploads()

    socket =
      if preset == "custom" do
        socket
        |> assign(:deny_wildcards, checked_keys(params["deny_wildcards"]))
        |> run_user_search(params["user_search"] || "")
      else
        socket
      end

    {:noreply, socket}
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
      |> assign(
        :preset,
        if(params["preset"] in @presets, do: params["preset"], else: socket.assigns.preset)
      )
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
        {:noreply,
         socket
         |> assign(:body, "")
         |> assign(:tags_value, "")
         |> assign(:review, @empty_review)
         |> assign(:review_lookup_error, nil)
         |> assign(:images, [])
         |> assign(:photos, %{})
         |> assign(:open_photo, nil)
         |> assign(:error, nil)}
    end
  end

  defp handle_save_result({:error, %Ecto.Changeset{} = changeset}, socket) do
    {:noreply, assign(socket, :error, changeset_message(changeset))}
  end

  defp handle_save_result({:error, reason}, socket) do
    {:noreply, assign(socket, :error, save_error_message(reason))}
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
    <div id={@id}>
      <.card>
        <.form
          for={to_form(%{}, as: :post)}
          id={"#{@id}-form"}
          phx-submit="save"
          phx-change="validate"
          phx-target={@myself}
        >
          <%!-- Feed compose only: a corner ✕ collapses the composer. It carries
          no phx-target, so the event bubbles up to the feed LiveView that owns
          the reveal (`close-composer`). The edit and reply pages navigate away
          instead, so they never render it. It sits in its own row above the
          editor rather than the card corner, which the editor toolbar owns. --%>
          <div :if={@post == nil and @parent == nil} class="mb-1 flex justify-end">
            <button
              type="button"
              phx-click="close-composer"
              aria-label={gettext("Close")}
              title={gettext("Close")}
              class="-mr-2 -mt-2 rounded-lg px-2 py-1 text-sm font-semibold text-slate-500 hover:bg-slate-100 hover:text-slate-700 dark:text-slate-400 dark:hover:bg-slate-800 dark:hover:text-slate-200"
            >
              ✕
            </button>
          </div>

          <.markdown_editor
            id={"#{@id}-body"}
            name="post[body]"
            value={@body}
            label={gettext("What's new?")}
            placeholder={gettext("What's new? Markdown is supported.")}
            rows={if(@post, do: 10, else: 3)}
            images
          />

          <p :if={String.length(@body) > Post.max_body_length() - 2000} class="mt-1 text-xs text-slate-600 dark:text-slate-400">
            {delimited_count(String.length(@body))} / {delimited_count(Post.max_body_length())}
          </p>

          <%!-- The photo strip (issue #1104). Drop photos and press Post is the
          whole flow; everything else is opt-in and one tap away. Tiles are
          drag-reorderable on a pointer device and ◀ ▶ reorderable everywhere
          (touch cannot fire native HTML5 drag), and the first tile is marked
          the one that leads the mosaic, so ordering is the only layout control
          there is. --%>
          <div
            :if={@images != []}
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
              draggable="true"
              class={[
                "group relative aspect-square overflow-hidden rounded-lg ring-1",
                (@open_photo == image.id && "ring-2 ring-brand-500") ||
                  "ring-slate-200 dark:ring-slate-800"
              ]}
            >
              <img src={PostImage.url(image, "thumb")} alt="" class="h-full w-full object-cover" />

              <%!-- The hero marker. A number on every tile would be noise; what
              the author needs to know is which photo leads. --%>
              <span
                :if={index == 0}
                class="absolute left-1 top-1 rounded bg-slate-900/70 px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-white"
              >
                {gettext("Cover")}
              </span>

              <%!-- The alt-text nudge: amber while a photo has no description,
              so the gap is visible without blocking anything. --%>
              <span
                :if={photo_setting(@photos, image, :alt) == ""}
                title={gettext("No image description yet")}
                class="absolute right-1 top-1 rounded bg-amber-400/90 px-1.5 py-0.5 text-[10px] font-bold text-amber-950"
                data-photo-alt-missing={image.id}
              >
                ALT
              </span>

              <%!-- Controls sit on a scrim at the bottom of the tile: always
              visible on touch (where there is no hover), so nothing is
              undiscoverable on a phone. --%>
              <div class="absolute inset-x-0 bottom-0 flex items-center justify-between gap-0.5 bg-slate-900/60 px-1 py-1">
                <button
                  type="button"
                  phx-click="photo-move"
                  phx-value-id={image.id}
                  phx-value-dir="back"
                  phx-target={@myself}
                  disabled={index == 0}
                  aria-label={gettext("Move photo earlier")}
                  class="rounded px-1 text-xs text-white disabled:opacity-30"
                >
                  ◀
                </button>
                <button
                  type="button"
                  phx-click="photo-open"
                  phx-value-id={image.id}
                  phx-target={@myself}
                  aria-label={gettext("Photo options")}
                  title={gettext("Photo options")}
                  class="rounded px-1 text-xs text-white hover:bg-white/20"
                >
                  ⚙
                </button>
                <button
                  type="button"
                  phx-click="remove-image"
                  phx-value-id={image.id}
                  phx-target={@myself}
                  aria-label={gettext("Remove photo")}
                  title={gettext("Remove photo")}
                  class="rounded px-1 text-xs text-white hover:bg-white/20"
                >
                  ✕
                </button>
                <button
                  type="button"
                  phx-click="photo-move"
                  phx-value-id={image.id}
                  phx-value-dir="forward"
                  phx-target={@myself}
                  disabled={index == length(@images) - 1}
                  aria-label={gettext("Move photo later")}
                  class="rounded px-1 text-xs text-white disabled:opacity-30"
                >
                  ▶
                </button>
              </div>
            </div>
          </div>

          <p
            :if={length(@images) > 1}
            class="mt-1.5 text-xs text-slate-600 dark:text-slate-400"
          >
            {gettext("Drag to reorder. The first photo leads the gallery.")}
          </p>

          <.photo_panel
            :if={open_photo(@images, @open_photo)}
            image={open_photo(@images, @open_photo)}
            settings={photo_settings(@photos, open_photo(@images, @open_photo))}
            many?={length(@images) > 1}
            id={"#{@id}-photo-panel"}
            myself={@myself}
          />

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

          <%!-- Bottom row: the image picker on the left, the (slightly wider)
          submit button on the right. New posts publish public, so there is no
          audience picker here; a post pinned public by reposts/replies still
          shows the read-only lock chip beside the button. --%>
          <div class="mt-3 flex items-center gap-3">
            <%!-- h-9 pins this to the Post button's height (both 36px, the
            standard control height): the 📷 emoji would otherwise inflate the
            line box, and mb-0 drops the global `label` margin (components.css)
            that would offset it in this row. --%>
            <label class="inline-flex h-9 mb-0 cursor-pointer items-center gap-1.5 rounded-lg bg-slate-100 px-3 text-sm font-semibold text-slate-700 hover:bg-slate-200 dark:bg-slate-800 dark:text-slate-200 dark:hover:bg-slate-700">
              📷 {gettext("Add images")}
              <.live_file_input upload={@uploads.images} class="sr-only" />
            </label>

            <%!-- Review triggers: open the book/film review panel. Emoji-only
            on phones (the row is tight there), labeled from sm up. --%>
            <button
              :if={@review["kind"] == ""}
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
              :if={@review["kind"] == ""}
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

            <%!-- The license select appears only once a photo is attached
            (issue #1104): on a text post it would be a control about nothing.
            It is a plain select of a fixed vocabulary, never free text, so
            what is published stays machine-readable and nobody invents a
            licence sentence by accident. --%>
            <select
              :if={@images != []}
              name="post[license]"
              id={"#{@id}-license"}
              title={gettext("Who may reuse these photos")}
              class={[input_class(), "h-9 w-auto max-w-[14rem] py-0 text-sm"]}
            >
              <option
                :for={license <- PhotoLicense.values()}
                value={license}
                selected={@license == license}
              >
                {PhotoLicense.label(license)}
              </option>
            </select>

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
  """
  attr(:image, :any, required: true)
  attr(:settings, :map, required: true)
  attr(:many?, :boolean, required: true)
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
        show, and says so — a dead toggle with no explanation reads as a bug. --%>
        <div>
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
