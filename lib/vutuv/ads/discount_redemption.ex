defmodule Vutuv.Ads.DiscountRedemption do
  @moduledoc """
  One member's use of one discount code.

  A row rather than a counter, because "once per member" is a fact about a
  **pair** — the partial unique index on `(code_id, user_id)` where
  `released_at IS NULL` is what enforces it, and for a personalised code that
  same index is what makes it good exactly once.

  A booking we turned down, or one withdrawn before it was approved, sets
  `released_at`: nothing ran, so nothing was used, and the member may book with
  the code again. Stamped rather than deleted, so an admin can still see who
  tried what.
  """

  use VutuvWeb, :model

  alias Vutuv.Ads.DiscountCode

  schema "ad_discount_redemptions" do
    field(:cents_off, :integer)
    field(:released_at, :utc_datetime)

    belongs_to(:code, DiscountCode)
    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:ad, Vutuv.Ads.Ad)

    timestamps()
  end

  @doc "Set programmatically by `Vutuv.Ads.Discounts.redeem/3`; nothing is cast."
  def changeset(model, attrs) do
    model
    |> cast(attrs, [:code_id, :user_id, :ad_id, :cents_off])
    |> validate_required([:code_id, :user_id, :cents_off])
    |> unique_constraint([:code_id, :user_id],
      name: :ad_discount_redemptions_live_index,
      message: "has already been used"
    )
  end
end
