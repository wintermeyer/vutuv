defmodule Vutuv.Chat.Conversation do
  @moduledoc false

  use VutuvWeb, :model

  @statuses ~w(pending accepted declined)

  schema "conversations" do
    # Two shapes (issue #1336):
    #
    #   member <-> member: user_a + user_b, stored SORTED (user_a_id <
    #     user_b_id, CHECK-enforced) so one unique index allows exactly one
    #     conversation per pair. Sorting breaks a symmetry: two ids from the
    #     same table mean (a, b) and (b, a) name the same conversation.
    #   member <-> page:   user_a is the member, user_b NULL, organization set.
    #     No sorting, because two ids from DIFFERENT tables carry no such
    #     symmetry — the pair is already canonical.
    #   member <-> remote: user_a is the member, remote_account set — a private
    #     message to or from another network (issue: DMs into the Fediverse).
    #
    # A CHECK says the other side is exactly one of the three. All of these are
    # set programmatically, never cast.
    belongs_to(:user_a, Vutuv.Accounts.User)
    belongs_to(:user_b, Vutuv.Accounts.User)
    belongs_to(:organization, Vutuv.Organizations.Organization)
    belongs_to(:remote_account, Vutuv.Fediverse.RemoteAccount)
    # The party who opened the conversation (set when the first message is
    # sent). A standing role on the conversation, not a per-message field.
    #
    # **Nullable, and NULL means the remote side started it** — an account on
    # another network is not a row in `users`. Every rule that reads
    # "initiator is not me" has to spell that as `is_nil(...) or ... != me`,
    # because `NULL != <id>` is NULL and not true, which would silently deny
    # the member the right to accept the request.
    belongs_to(:initiator, Vutuv.Accounts.User)

    field(:status, :string, default: "pending")
    field(:last_message_at, :naive_datetime)
    # Set by Vutuv.Moderation when one party reports the other: the whole
    # conversation disappears for BOTH sides and accepts no new messages
    # until a rejected report restores it. Never cast.
    field(:frozen_at, :naive_datetime)

    has_many(:participants, Vutuv.Chat.Participant)
    has_many(:messages, Vutuv.Chat.Message)

    timestamps()
  end

  def statuses, do: @statuses

  def changeset(conversation, params \\ %{}) do
    conversation
    |> cast(params, [:status])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:user_a_id, :user_b_id])
    |> check_constraint(:user_a_id, name: :sorted_pair, message: "pair must be sorted")
  end
end
