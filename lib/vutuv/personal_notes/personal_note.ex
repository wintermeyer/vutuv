defmodule Vutuv.PersonalNotes.PersonalNote do
  @moduledoc """
  One note a member wrote about another account, visible to nobody but its
  author. Written and read through `Vutuv.PersonalNotes`.

  Exactly one of the three subject columns is set, the nullable-set shape
  `Vutuv.Mutes.AccountMute` uses for "a member, a page, or an account out
  there" — CHECK-enforced, so a row can never name two. The subject is set from
  a struct the caller loaded, never cast from params, so a member can only ever
  write about an account they were looking at.
  """

  use VutuvWeb, :model

  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Organizations.Organization

  @max_body 10_000

  schema "personal_notes" do
    belongs_to(:user, User)
    belongs_to(:subject_user, User)
    belongs_to(:subject_organization, Organization)
    belongs_to(:subject_remote_account, RemoteAccount)
    field(:body, :string)
    field(:edited_at, :utc_datetime)

    # Whichever of the three subject associations is set, filled by
    # `Vutuv.PersonalNotes.list/2` so a caller never has to ask which one.
    field(:subject, :any, virtual: true)

    timestamps()
  end

  @doc "The longest note a member can write, in characters."
  def max_body, do: @max_body

  @doc """
  A new note about `subject`. The `no_self_note` constraint is not mapped here:
  `Vutuv.PersonalNotes.create/3` refuses a note about oneself before it gets
  this far, and the constraint only guards the table.
  """
  def create_changeset(note, subject, attrs) do
    note
    |> body_changeset(attrs)
    |> put_subject(subject)
  end

  @doc """
  An edit. `edited_at` moves only when the text really changed, so saving the
  form untouched does not mark the note as edited.
  """
  def update_changeset(note, attrs) do
    changeset = body_changeset(note, attrs)

    if changeset.valid? and get_change(changeset, :body) do
      put_change(changeset, :edited_at, DateTime.utc_now(:second))
    else
      changeset
    end
  end

  defp body_changeset(note, attrs) do
    note
    |> cast(attrs, [:body])
    |> update_change(:body, &trim/1)
    |> validate_required([:body])
    |> validate_length(:body, max: @max_body)
  end

  defp trim(body) when is_binary(body), do: String.trim(body)
  defp trim(body), do: body

  @doc "The column that names `subject`."
  def subject_field(%User{}), do: :subject_user_id
  def subject_field(%Organization{}), do: :subject_organization_id
  def subject_field(%RemoteAccount{}), do: :subject_remote_account_id

  defp put_subject(changeset, subject),
    do: put_change(changeset, subject_field(subject), subject.id)
end
