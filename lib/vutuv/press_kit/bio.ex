defmodule Vutuv.PressKit.Bio do
  @moduledoc """
  The three bios a member offers in their Media Kit (issue #2101): one row per
  member, one column per length.

  **One row, not three.** A member writes the three together and a reader takes
  whichever fits, so the whole thing is one read, one changeset and one upsert;
  three rows would make the *length* a value in the data and buy nothing.

  **`:text`, and all three bounded by the same number.** Each is Markdown prose
  exactly as a post body is, so `Vutuv.PressKit.max_bio_length/0` is the post
  body's own 20,000 characters. The short and medium ones carry a word count in
  the editor (about fifty, about a hundred and fifty) and the form enforces
  neither: they are guidance a member may ignore, and a column that refused
  eighty words in the short one would turn that guidance into a rule behind
  their back. The cap exists for the other reason — Ecto does not enforce a
  column's width, and an unbounded value raises Postgres 22001 rather than
  showing an error in the form.

  A blank field is stored as `nil`, never as `""`, so every reader can ask one
  question (`is_nil/1`) about whether there is a bio to draw.
  """

  use VutuvWeb, :model

  alias Vutuv.Accounts.User
  alias Vutuv.ChangesetHelpers
  alias Vutuv.MarkdownContent
  alias Vutuv.Posts.Post

  # All three, in the order they are shown. The list is the vocabulary: the
  # editor, the public page and the documents all walk it rather than naming
  # the three columns each in their own order.
  @lengths [:short, :medium, :long]

  # How many words each length is aiming at, and `nil` where there is no aim.
  # Shown in the editor as guidance; nothing validates against it.
  @targets %{short: 50, medium: 150, long: nil}

  schema "press_bios" do
    belongs_to(:user, User)

    field(:short, :string)
    field(:medium, :string)
    field(:long, :string)

    timestamps()
  end

  @doc "The three lengths, in the order every surface shows them."
  def lengths, do: @lengths

  @doc "The word count a length aims at, or `nil` for the long form."
  def target(length) when length in @lengths, do: Map.fetch!(@targets, length)

  @doc """
  The longest any one of them may be, in characters — the **post body's** cap,
  asked for rather than copied, so raising one raises both.
  """
  defdelegate max_length, to: Post, as: :max_body_length

  @doc """
  All three at once — a bio is written and saved as one thing.

  Each field is trimmed and an empty one becomes `nil`, so a member who clears
  a bio removes it rather than leaving a blank block on their Media Kit; and
  each is refused an image, the same rule every other Markdown column a member
  writes states at the write (`Vutuv.Chat.Message`, an organization's and a job
  posting's description). That rule cannot be left to the renderer here: the
  stored **source** is what the `.md`, `.json` and GDPR-export readers get,
  unrendered.
  """
  def changeset(%__MODULE__{} = bio, attrs) do
    bio
    |> cast(attrs, @lengths)
    |> ChangesetHelpers.trim_fields(@lengths)
    |> then(&Enum.reduce(@lengths, &1, fn field, changeset -> bounds(changeset, field) end))
    |> unique_constraint(:user_id)
  end

  defp bounds(changeset, field) do
    changeset
    |> validate_length(field, max: max_length())
    |> MarkdownContent.validate_no_images(field)
  end

  @doc "Whether this bio says anything at all."
  def any?(%__MODULE__{} = bio), do: Enum.any?(@lengths, &is_binary(Map.fetch!(bio, &1)))
end
