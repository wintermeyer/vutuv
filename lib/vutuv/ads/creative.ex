defmodule Vutuv.Ads.Creative do
  @moduledoc """
  An ad text a member saved to use again.

  The same three lines a booking carries — title, sentence, link — kept in the
  member's account so a second week does not mean typing them a second time.
  Booking **copies** the text onto the `ads` rows rather than pointing at this
  one, so editing a saved ad can never rewrite an ad that is already running,
  already approved, or already on an invoice.

  It validates through `Vutuv.Ads.Ad.validate_text/1`, the same rules the
  booking meets: saving something the booking would then refuse is the one
  thing a library like this must not do.
  """

  use VutuvWeb, :model

  alias Vutuv.Ads.Ad

  schema "ad_creatives" do
    field(:title, :string)
    field(:body, :string)
    field(:url, :string)

    belongs_to(:user, Vutuv.Accounts.User)
    timestamps()
  end

  @doc "The save form. `user_id` is set programmatically, never cast."
  def changeset(model, params \\ %{}) do
    model
    |> cast(params, [:title, :body, :url])
    |> Ad.validate_text()
  end
end
