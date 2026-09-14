defmodule VutuvWeb.PostLive.RemoteReply do
  @moduledoc """
  Answers a remote note publicly or, for direct messages, through the isolated
  private text reply store. The recipient is stated before the member writes.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.ErrorHelpers, only: [error_tag: 2, err_attrs: 2]
  import VutuvWeb.PostComponents

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Note
  alias Vutuv.Fediverse.PrivateMessage
  alias Vutuv.Posts
  alias VutuvWeb.Live.InitAssigns

  on_mount({VutuvWeb.Live.InitAssigns, :require_login})
  # The composer here takes a clip; its progress arrives through this hook
  # (issue #1911).
  on_mount(VutuvWeb.Live.VideoProgress)

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    viewer = socket.assigns.current_user
    note = Fediverse.get_note(id)

    if note && visible?(note, viewer) do
      {:ok, assign_gate(socket, note, viewer)}
    else
      {:ok, InitAssigns.not_found(socket)}
    end
  end

  # The same rule `Vutuv.Fediverse.list_notes/2` enforces for the thread: a public
  # reply is everybody's, a private one is its addressee's alone. Answering a
  # private one uses a separate text-only form. This check is only about
  # whether the page may show it at all, so existence never leaks.
  defp visible?(%Note{} = note, viewer) do
    Note.public?(note) or
      match?(%Posts.Post{user_id: id} when id == viewer.id, Posts.get_post(note.post_id))
  end

  defp assign_gate(socket, %Note{} = note, viewer) do
    socket =
      socket
      |> assign(:page_title, gettext("Reply to %{handle}", handle: Note.display_handle(note)))
      |> assign(:note, note)
      |> assign(:post, Posts.get_post(note.post_id))
      |> assign(:private?, note.audience == "direct")
      |> assign(:private_replies, Fediverse.list_private_replies(viewer, note))
      |> assign(
        :private_form,
        to_form(PrivateMessage.changeset(%PrivateMessage{}, %{}), as: :reply)
      )

    gate =
      if socket.assigns.private?,
        do: Fediverse.check_private_reply(viewer, note),
        else: Fediverse.check_remote_reply(viewer, note)

    case gate do
      :ok ->
        assign(socket, :refusal, nil)

      # The one refusal the member can act on, so it gets the page rather than a
      # redirect.
      {:error, :not_federating} ->
        assign(socket, :refusal, :not_federating)

      {:error, reason} ->
        socket
        |> put_flash(:error, answer_refusal_message(reason))
        |> redirect(to: Posts.path(socket.assigns.post))
    end
  end

  @impl true
  def handle_event("send-private", %{"reply" => attrs}, socket) do
    user = Vutuv.Repo.get!(Vutuv.Accounts.User, socket.assigns.current_user.id)

    case Fediverse.create_private_reply(user, socket.assigns.note, attrs) do
      {:ok, _reply} ->
        {:noreply,
         socket
         |> assign(:private_replies, Fediverse.list_private_replies(user, socket.assigns.note))
         |> assign(
           :private_form,
           to_form(PrivateMessage.changeset(%PrivateMessage{}, %{}), as: :reply)
         )
         |> put_flash(:info, gettext("Your private reply has been queued for delivery."))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket, :private_form, to_form(%{changeset | action: :insert}, as: :reply))}

      {:error, _reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Your private reply could not be sent. Please reload and try again.")
         )}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.remote_answer_page
      id="remote-reply"
      handle={Note.display_handle(@note)}
      refusal={@refusal}
      private?={@private?}
      explanation={
        gettext(
          "This reply was written on another network. Answering it means sending your words to that network, which vutuv only does for members who have switched Fediverse participation on."
        )
      }
      back_href={@post && Posts.path(@post)}
      back_label={gettext("Back to the conversation")}
    >
      <:target>
        <%!-- Whole, not clamped: nobody should have to open a "Read more" to
        see what they are answering. --%>
        <.remote_reply_card mode={:full} note={@note} viewer={@current_user} />
      </:target>
      <:composer>
        <section :if={@private?} class="space-y-4">
          <.card :for={reply <- @private_replies}>
            <div data-private-reply>
              <h2 class="mb-2 text-sm font-semibold text-slate-700 dark:text-slate-300">{gettext("Your private reply")}</h2>
              <p class="whitespace-pre-wrap break-words text-slate-800 dark:text-slate-100">{reply.body}</p>
            </div>
          </.card>
          <.card>
            <.form for={@private_form} id="private-reply-form" phx-submit="send-private" class="space-y-4">
              <div>
                <label for="private-reply-body" class="mb-2 block text-sm font-medium text-slate-700 dark:text-slate-300">{gettext("Private text reply")}</label>
                <textarea id="private-reply-body" name={@private_form[:body].name} rows="6" maxlength="5000" required class={input_class(@private_form, :body)} {err_attrs(@private_form, :body)}>{Phoenix.HTML.Form.normalize_value("textarea", @private_form[:body].value)}</textarea>
                {error_tag(@private_form, :body)}
              </div>
              <p class="text-sm text-slate-600 dark:text-slate-400">{gettext("Text only, up to 5,000 characters.")}</p>
              <.button type="submit" phx-disable-with={gettext("Sending…")}>{gettext("Send privately")}</.button>
            </.form>
          </.card>
        </section>
        <.live_component
          :if={!@private?}
          module={VutuvWeb.PostLive.Composer}
          id="composer"
          current_user={@current_user}
          post={nil}
          parent={nil}
          remote_note={@note}
        />
      </:composer>
    </.remote_answer_page>
    """
  end
end
