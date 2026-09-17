defmodule Vutuv.PersonalNotes do
  @moduledoc """
  What a member writes down about another account, for their eyes only.

  The idea is Mastodon's "personal note", with two differences a member asked
  for: a member keeps **as many notes as they like** about the same account,
  each dated by when it was written, and the notes are Markdown like a post.

  A subject is one of the three shapes an account has here: a member
  (`%User{}`), a page (`%Organization{}`) or an account on another network
  (`%RemoteAccount{}`). The naming helpers for those three already live in
  `Vutuv.Mutes`, which has the same shape of problem, and are reused rather than
  copied.

  ## Private means private

  Every read and write here is scoped to the author's id, and nothing else in
  the app reads the table: no agent format, no API, no notification, no
  federation, no broadcast. The account a note is about never learns it exists.
  An `@handle` inside a note is rendered as a link like anywhere else, but a
  note never passes through `Vutuv.Mentions`' notification path, so the
  mentioned member is not told either.

  ## Order and deletion

  Newest first by when the note was written. An edit sets `edited_at` and
  leaves the note where it is: the date that counts is when it was taken.

  Deletion is the database's job. Every subject column cascades, so a member's
  deletion (`Vutuv.Accounts.delete_user/1`), a page's, and a remote account's
  own `Delete` (`Vutuv.Fediverse.remove_remote_account/1`) or its server being
  blocked all take the notes about that account along; the author's deletion
  takes their notes too.
  """

  import Ecto.Query, warn: false
  import Vutuv.SearchText, only: [name_ilike: 3]

  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Keyset
  alias Vutuv.Moderation
  alias Vutuv.Mutes
  alias Vutuv.Organizations
  alias Vutuv.Organizations.Organization
  alias Vutuv.PersonalNotes.PersonalNote
  alias Vutuv.Repo
  alias Vutuv.SearchText
  alias Vutuv.UUIDv7

  @subjects [:subject_user, :subject_organization, :subject_remote_account]

  # How many notes a panel or a card quotes before it links to the rest.
  @shown 3

  @doc """
  Whether `viewer` can keep notes about `subject`: any signed-in member, about
  anybody but themselves.
  """
  def available?(%User{id: id}, %User{id: id}), do: false
  def available?(%User{}, %User{}), do: true
  def available?(%User{}, %Organization{}), do: true
  def available?(%User{}, %RemoteAccount{}), do: true
  def available?(_viewer, _subject), do: false

  @doc "Writes a new note by `author` about `subject`."
  def create(%User{} = author, subject, attrs) do
    if available?(author, subject) do
      %PersonalNote{user_id: author.id}
      |> PersonalNote.create_changeset(subject, attrs)
      |> Repo.insert()
    else
      {:error, :self}
    end
  end

  @doc """
  Changes the text of one of `author`'s notes. Anybody else's note, or an id
  that is not one, is `{:error, :not_found}`.
  """
  def update(%User{} = author, id, attrs) do
    case get(author, id) do
      nil -> {:error, :not_found}
      note -> note |> PersonalNote.update_changeset(attrs) |> Repo.update()
    end
  end

  @doc "Deletes one of `author`'s notes."
  def delete(%User{id: author_id}, id) do
    case UUIDv7.cast_or_nil(id) do
      nil ->
        {:error, :not_found}

      id ->
        case Repo.delete_all(
               from(n in PersonalNote, where: n.id == ^id and n.user_id == ^author_id)
             ) do
          {1, _} -> :ok
          {0, _} -> {:error, :not_found}
        end
    end
  end

  @doc "One of `author`'s notes, or nil."
  def get(%User{id: author_id}, id) do
    UUIDv7.with_cast(id, &Repo.get_by(PersonalNote, id: &1, user_id: author_id))
  end

  @doc "The newest `limit` notes `author` wrote about `subject`."
  def recent(author, subject, limit) do
    if available?(author, subject) do
      author
      |> about(subject)
      |> order_by(desc: :id)
      |> limit(^limit)
      |> Repo.all()
    else
      []
    end
  end

  @doc "How many notes `author` wrote about `subject`."
  def count(author, subject) do
    if available?(author, subject),
      do: author |> about(subject) |> Repo.aggregate(:count),
      else: 0
  end

  @doc """
  The newest few notes about `subject` and how many there are in all, which is
  what the profile panel and the card show.
  """
  def summary(author, subject, limit \\ @shown) do
    case recent(author, subject, limit) do
      notes when length(notes) < limit -> %{count: length(notes), notes: notes}
      notes -> %{count: count(author, subject), notes: notes}
    end
  end

  @doc """
  One page of `author`'s notes, newest first, each with its `subject` filled in.

  Options:

    * `:query` — a case-insensitive substring of the note or of the name, handle
      or server of the account it is about.
    * `:subject` — only the notes about this account.
    * `:id` — only this note (`listed/2`).
    * `:max_id` — strictly older than this note (the "show more" direction).
    * `:limit` — the page size (default 20).
  """
  def list(%User{id: author_id}, opts \\ []) do
    from(n in PersonalNote,
      where: n.user_id == ^author_id,
      left_join: u in assoc(n, :subject_user),
      as: :member,
      left_join: o in assoc(n, :subject_organization),
      as: :page,
      left_join: r in assoc(n, :subject_remote_account),
      as: :remote,
      preload: [subject_user: u, subject_organization: o, subject_remote_account: r]
    )
    |> filter_subject(opts[:subject])
    |> filter_id(opts[:id])
    |> search(SearchText.normalize_search(opts[:query]))
    |> page(opts)
    |> Repo.all()
    |> Enum.map(&put_subject/1)
  end

  # `limit: :all` is the export's, which wants every note in the same order.
  defp page(query, opts) do
    if opts[:limit] == :all,
      do: order_by(query, desc: :id),
      else: Keyset.scope(query, Keyword.take(opts, [:max_id, :limit]))
  end

  @doc "One of `author`'s notes as `list/2` returns it, subject filled in, or nil."
  def listed(author, id) do
    case UUIDv7.cast_or_nil(id) do
      nil -> nil
      id -> author |> list(id: id) |> List.first()
    end
  end

  @doc """
  Resolves the `kind`/`id` pair a link to the overview names (`member`,
  `organization` or `remote_account`) into the account `viewer` may see, or nil.
  An id typed into the URL must not bring back a hidden member's name.
  """
  def subject(kind, id, viewer) do
    with account when not is_nil(account) <- Mutes.target(kind, id),
         true <- visible_to?(account, viewer) do
      account
    else
      _ -> nil
    end
  end

  @doc """
  Whether `viewer` may see `account` at all, by the rule its own page uses. An
  account on another network is a cached copy any signed-in member may open.
  """
  def visible_to?(%User{} = user, viewer), do: Moderation.profile_visible_to?(user, viewer)

  def visible_to?(%Organization{} = page, viewer),
    do: Organizations.organization_visible_to?(page, viewer)

  def visible_to?(%RemoteAccount{}, _viewer), do: true

  @doc "The kind string for a subject, the inverse of `subject/2`."
  defdelegate kind(subject), to: Mutes

  @doc "How the account a note is about is called."
  defdelegate display_name(subject), to: Mutes

  @doc "The address under the name: `@handle` here, `@user@host` out there."
  defdelegate handle(subject), to: Mutes

  @doc "Where the account a note is about has its page."
  defdelegate path(subject), to: Mutes

  @doc "Everything `author` wrote, for their data export."
  def export(%User{} = author) do
    author
    |> list(limit: :all)
    |> Enum.map(fn note ->
      %{
        account: handle(note.subject),
        name: display_name(note.subject),
        kind: kind(note.subject),
        body: note.body,
        written_at: note.inserted_at,
        edited_at: note.edited_at
      }
    end)
  end

  defp about(%User{id: author_id}, subject) do
    field = PersonalNote.subject_field(subject)
    from(n in PersonalNote, where: n.user_id == ^author_id and field(n, ^field) == ^subject.id)
  end

  defp filter_id(query, nil), do: query
  defp filter_id(query, id), do: where(query, [n], n.id == ^id)

  defp filter_subject(query, nil), do: query

  defp filter_subject(query, subject) do
    field = PersonalNote.subject_field(subject)
    where(query, [n], field(n, ^field) == ^subject.id)
  end

  defp search(query, nil), do: query

  defp search(query, term) do
    pattern = term |> SearchText.cap() |> SearchText.contains()

    where(
      query,
      [n, member: u, page: o, remote: r],
      ilike(n.body, ^pattern) or
        ilike(u.username, ^pattern) or
        name_ilike(u.first_name, u.last_name, ^pattern) or
        ilike(o.name, ^pattern) or
        ilike(o.slug, ^pattern) or
        ilike(r.name, ^pattern) or
        ilike(r.handle, ^pattern) or
        ilike(r.host, ^pattern)
    )
  end

  defp put_subject(note) do
    %{note | subject: Enum.find_value(@subjects, &Map.get(note, &1))}
  end
end
