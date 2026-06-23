defmodule Vutuv.Newsletters.NewsletterDelivery do
  @moduledoc """
  One row per address a newsletter was actually sent to: the delivery protocol.

  This is the log the admin asked for ("when which email went out"). `kind` is
  `test` (a preview to an arbitrary address) or `broadcast` (one of the mass
  send); `status` is `sent`, `suppressed` (the email chokepoint dropped a
  bounced address) or `error`. `user_id` is the recipient member when there is
  one, `nil` for a test to an address that is not a member. Rows are written
  directly (not cast) by `Vutuv.Newsletters`; `inserted_at` is the "when".
  """

  use VutuvWeb, :model

  alias Vutuv.Newsletters.Newsletter

  @kinds ~w(test broadcast)
  @statuses ~w(sent suppressed error)

  schema "newsletter_deliveries" do
    field(:email, :string)
    field(:kind, :string)
    field(:status, :string)

    belongs_to(:newsletter, Newsletter)
    belongs_to(:user, Vutuv.Accounts.User)

    timestamps()
  end

  def kinds, do: @kinds
  def statuses, do: @statuses
end
