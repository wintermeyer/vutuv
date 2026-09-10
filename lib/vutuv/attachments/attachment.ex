defmodule Vutuv.Attachments.Attachment do
  @moduledoc """
  A file a member uploaded in the composer (issue #2104) — a PDF, a plain
  text file or a Markdown file.

  Uploaded eagerly like a photo or a clip: the row exists the moment the file
  is accepted, with **neither parent set**, and the post (#2106) or the
  message (#2110) claims it later. A row that never gets a parent is swept
  after a day (`Vutuv.Attachments.sweep_pending/1`).

  ## The two parents

  `post_id` and `message_id` are the nullable pair CLAUDE.md warns about: at
  most one of them is set and both are `nil` while the composer holds the
  file. Nothing here may be read with an inner join to `posts` (that drops
  every message's file) or fed into a `NOT IN` without an `is_nil/1` branch
  (one NULL in the list makes the predicate false for every row).
  `Vutuv.Attachments.pending?/1` is the one place that asks.

  ## What the row holds

    * **what the member sent** — `file_name` as typed (for the download's
      name), `size_bytes`, and `content_type` **derived from the bytes**, not
      from the browser's claim.
    * **`page_count`** — `pdfinfo`'s answer for a PDF, `nil` for text. What
      #2105 renders its preview pages from.
    * **`token`** — the URL key and the on-disk directory name, never the id.
    * **`stage`** — where the pipeline is. `stored` the moment the file lands
      (the column's default), `rendering` while a slot is making its preview
      pages, then `ready` — however many pages that turned out to be, zero
      included — or `failed` when the renderer could not do it. The last two
      are terminal, and that is what takes the row out of the render pipeline's
      due query (`Vutuv.Attachments.Pages`, #2105).
  """

  use VutuvWeb, :model

  # `file_name` is the one column here a client writes — whatever the browser
  # sent, and a browser will happily send 400 characters. Ecto does not enforce
  # a varchar(255), so without this an oversized name raises Postgres 22001,
  # which is a 500 on a plain upload. `content_type` is validated beside it
  # because the two are set together and must not drift apart.
  @name_max 255

  schema "attachments" do
    belongs_to(:post, Vutuv.Posts.Post)
    belongs_to(:message, Vutuv.Chat.Message)
    belongs_to(:user, Vutuv.Accounts.User)

    field(:token, :string)
    field(:file_name, :string)
    field(:content_type, :string)
    field(:size_bytes, :integer)
    field(:page_count, :integer)

    field(:stage, :string, default: "stored")

    # The render pipeline's own two columns (#2105). `worked_at` is the claim
    # heartbeat a compare-and-set is done on, so two slots of a deploy overlap
    # cannot render the same file; `render_attempts` counts only the passes
    # where the renderer itself failed.
    field(:worked_at, :utc_datetime)
    field(:render_attempts, :integer, default: 0)

    timestamps()
  end

  @doc "The insert the upload chokepoint writes; every value here is already checked."
  def changeset(attachment, params) do
    attachment
    |> cast(params, [:token, :file_name, :content_type, :size_bytes, :page_count, :stage])
    |> validate_required([:token, :file_name, :content_type, :size_bytes])
    |> validate_length(:file_name, max: @name_max)
    |> validate_length(:content_type, max: @name_max)
    |> validate_number(:size_bytes, greater_than_or_equal_to: 0)
    |> unique_constraint(:token)
  end

  @doc "The longest file name that fits the column — what the chokepoint cuts to."
  def name_max, do: @name_max

  @doc "A fresh unguessable URL token (~128 bits, URL-safe)."
  defdelegate gen_token, to: Vutuv.Uploads
end
