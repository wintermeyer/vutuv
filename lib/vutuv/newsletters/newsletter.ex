defmodule Vutuv.Newsletters.Newsletter do
  @moduledoc """
  An admin-authored broadcast email ("Rundbrief").

  The body is **trusted** Markdown (only admins reach this) with merge variables
  like `{{greeting}}` / `{{first_name}}` substituted per recipient
  (`Vutuv.Newsletters` owns the rendering). A newsletter is saved as a `draft`,
  test-mailed, then broadcast once: `status` moves `draft -> sending -> sent`,
  where `sending` is the lock that stops a second concurrent broadcast.
  """

  use VutuvWeb, :model

  alias Vutuv.Newsletters.NewsletterDelivery

  @statuses ~w(draft sending sent)
  @max_subject 255
  @max_body 100_000

  schema "newsletters" do
    field(:subject, :string)
    field(:body, :string)
    field(:status, :string, default: "draft")
    field(:sent_at, :naive_datetime)
    field(:recipient_count, :integer, default: 0)

    belongs_to(:author, Vutuv.Accounts.User)
    # The audience this was broadcast to (nil = all eligible members).
    belongs_to(:group, Vutuv.Newsletters.NewsletterGroup)
    has_many(:deliveries, NewsletterDelivery)

    timestamps()
  end

  def statuses, do: @statuses

  @doc "Whether the draft can still be edited / broadcast (not yet sent)."
  def draft?(%__MODULE__{status: "draft"}), do: true
  def draft?(%__MODULE__{}), do: false

  @doc "The editable fields. author_id/status/sent_at are set programmatically."
  def changeset(newsletter, params \\ %{}) do
    newsletter
    |> cast(params, [:subject, :body])
    |> update_change(:subject, fn subject -> subject && String.trim(subject) end)
    |> validate_required([:subject, :body])
    |> validate_length(:subject, max: @max_subject)
    |> validate_length(:body, max: @max_body)
  end
end
