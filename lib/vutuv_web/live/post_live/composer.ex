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
  alias Vutuv.Posts
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
    socket = assign(socket, Map.take(assigns, [:id, :current_user, :post, :parent]))

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

    socket
    |> assign(:composer_ready?, true)
    |> assign_new(:parent, fn -> nil end)
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
    |> assign(:images, (post && post.images) || [])
    |> assign(:alts, %{})
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

  @impl true
  def handle_event("validate", %{"post" => params}, socket) do
    # New posts publish public (there is no audience picker); the fallback to the
    # current preset keeps an edited restricted post from silently downgrading to
    # public as the author types.
    preset = if params["preset"] in @presets, do: params["preset"], else: socket.assigns.preset

    socket =
      socket
      |> assign(:body, params["body"] || socket.assigns.body)
      |> assign(:tags_value, params["tags"] || socket.assigns.tags_value)
      |> assign(:alts, params["alts"] || socket.assigns.alts)
      |> assign(:review, Map.merge(socket.assigns.review, params["review"] || %{}))
      |> assign(:preset, preset)
      |> assign(:error, nil)
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

  def handle_event("remove-image", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.images, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      image ->
        # Pending rows die now; already-attached ones (edit mode) are only
        # dropped from the list — update_post removes them on save, so
        # cancelling the edit keeps the post intact.
        if is_nil(image.post_id), do: Posts.delete_pending_image(image)
        {:noreply, assign(socket, :images, Enum.reject(socket.assigns.images, &(&1.id == id)))}
    end
  end

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :images, ref)}
  end

  def handle_event("save", %{"post" => params}, socket) do
    save_alts(socket.assigns.images, params["alts"] || %{})

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
      # The submitted panel fields are the truth; with the panel closed only
      # the hidden kind ("") arrives, which removes a stored review on save.
      review: params["review"] || %{"kind" => ""},
      denials: denials_payload(socket.assigns),
      image_ids: Enum.map(socket.assigns.images, & &1.id)
    }

    socket.assigns.post
    |> save_post(socket.assigns.current_user, attrs, socket.assigns.parent)
    |> handle_save_result(socket)
  end

  defp save_post(nil, author, attrs, %Post{} = parent),
    do: Posts.create_reply(author, parent, attrs)

  defp save_post(nil, author, attrs, nil), do: Posts.create_post(author, attrs)
  defp save_post(post, _author, attrs, _parent), do: Posts.update_post(post, attrs)

  defp handle_save_result({:ok, post}, socket) do
    cond do
      socket.assigns.post ->
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
         |> assign(:alts, %{})
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
    do: gettext("This post can no longer be edited: someone has liked or reposted it.")

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

  defp save_error_message(_too_many_images) do
    gettext("No more than %{max} images per post.", max: Posts.max_images_per_post())
  end

  defp save_alts(images, alts) do
    Enum.each(images, fn image ->
      save_alt(image, Map.get(alts, image.id))
    end)
  end

  defp save_alt(_image, nil), do: :ok

  defp save_alt(image, alt) do
    if String.trim(alt) != image.alt, do: Posts.update_image_alt(image, alt)
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

          <%!-- Uploaded images: thumbnail + alt input + inline/remove actions --%>
          <ul :if={@images != []} class="mt-3 space-y-2" id={"#{@id}-images"}>
            <li :for={image <- @images} class="flex items-center gap-3">
              <img
                src={PostImage.url(image, "thumb")}
                alt=""
                width="48"
                height="48"
                class="h-12 w-12 rounded-lg object-cover ring-1 ring-slate-200 dark:ring-slate-800"
              />
              <input
                type="text"
                name={"post[alts][#{image.id}]"}
                value={Map.get(@alts, image.id, image.alt)}
                placeholder={gettext("Describe this image (alt text)")}
                class={[input_class(), "flex-1"]}
              />
              <button
                type="button"
                phx-click="insert-inline"
                phx-value-id={image.id}
                phx-target={@myself}
                title={gettext("Insert into text")}
                class="rounded-lg px-2 py-1 text-sm font-semibold text-brand-600 hover:bg-brand-50 dark:hover:bg-slate-800"
              >
                ↳ {gettext("Insert")}
              </button>
              <button
                type="button"
                phx-click="remove-image"
                phx-value-id={image.id}
                phx-target={@myself}
                title={gettext("Remove image")}
                class="rounded-lg px-2 py-1 text-sm font-semibold text-red-600 hover:bg-red-50 dark:hover:bg-slate-800"
              >
                ✕
              </button>
            </li>
          </ul>

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
