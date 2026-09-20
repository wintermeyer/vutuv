defmodule Vutuv.Ads.Discounts do
  @moduledoc """
  Discount codes for ad bookings: making them, checking one, and the two
  moments a booking gives one back.

  **Every rule about whether a code may be used lives in `check/3`**, which the
  wizard asks to show the member what a code is worth and `Vutuv.Ads.book_ad/3`
  asks again before it stamps anything. A check that only the form runs is a
  price a tampered form can set.

  The rules, in the order they are answered, because the order is what the
  member reads: a code that is not a code, one whose day has passed, one that
  belongs to somebody else, and one this member has already used.
  """

  import Ecto.Query

  alias Vutuv.Accounts.User
  alias Vutuv.Ads.Ad
  alias Vutuv.Ads.DiscountCode
  alias Vutuv.Ads.DiscountRedemption
  alias Vutuv.Repo
  alias Vutuv.UUIDv7

  @doc "Every code an admin made, the newest first, with its member and uses."
  def list_codes do
    Repo.all(
      from(c in DiscountCode,
        order_by: [desc: c.id],
        preload: [:user, redemptions: ^from(r in DiscountRedemption, preload: [:user])]
      )
    )
  end

  @doc """
  How many codes are still inside their window, for the admin dashboard's tile.
  An expired one is history, so counting it would advertise codes nobody can
  use — which is why the window comes from `DiscountCode.live_query/1` rather
  than being spelled a second time here.
  """
  def live_codes_count, do: Repo.aggregate(DiscountCode.live_query(), :count)

  @doc "One code by its id (which is the code), or nil - also on a malformed id."
  def get_code(id), do: UUIDv7.with_cast(id, &Repo.get(DiscountCode, &1))

  @doc "Changeset for the admin's create form."
  def change_code(%DiscountCode{} = code \\ %DiscountCode{}, attrs \\ %{}),
    do: DiscountCode.changeset(code, attrs)

  @doc "Makes a code. `admin` is stamped as its author."
  def create_code(admin, attrs) do
    %DiscountCode{created_by_id: admin.id}
    |> DiscountCode.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Forgets a code. Its redemptions go with it, and the bookings that used it keep
  the discount they were stamped with — an invoice is not rewritten because a
  code was tidied away later.
  """
  def delete_code(id) do
    case get_code(id) do
      nil -> {:error, :not_found}
      code -> Repo.delete(code)
    end
  end

  @doc """
  What `id` is worth to `user` on a net price of `cents`, or why it is not.

  `{:ok, code, discount_cents}` or `{:error, reason}` where reason is
  `:unknown`, `:expired`, `:not_yours` or `:used`. A blank code is
  `{:error, :blank}`, which the form treats as "no code", not as a mistake.
  """
  def check(id, user, cents)

  def check(id, _user, _cents) when id in [nil, ""], do: {:error, :blank}

  def check(id, %User{} = user, cents) do
    with {:code, %DiscountCode{} = code} <- {:code, get_code(String.trim(id))},
         {:live, true} <- {:live, DiscountCode.live?(code)},
         {:theirs, true} <- {:theirs, code.user_id in [nil, user.id]},
         {:unused, true} <- {:unused, not used_by?(code, user)} do
      {:ok, code, DiscountCode.discount_cents(code, cents)}
    else
      {:code, nil} -> {:error, :unknown}
      {:live, false} -> {:error, :expired}
      {:theirs, false} -> {:error, :not_yours}
      {:unused, false} -> {:error, :used}
    end
  end

  defp used_by?(%DiscountCode{id: code_id}, %User{id: user_id}) do
    Repo.exists?(
      from(r in DiscountRedemption,
        where: r.code_id == ^code_id and r.user_id == ^user_id and is_nil(r.released_at)
      )
    )
  end

  @doc """
  Writes down that `user` used `code` on `ad` for `cents_off`.

  The partial unique index is what decides a race between two tabs, so the
  error it raises is the answer rather than a second `check/3` here.
  """
  def redeem(%DiscountCode{} = code, %User{} = user, %Ad{} = ad, cents_off) do
    %DiscountRedemption{}
    |> DiscountRedemption.changeset(%{
      code_id: code.id,
      user_id: user.id,
      ad_id: ad.id,
      cents_off: cents_off
    })
    |> Repo.insert()
  end

  @doc """
  Gives back whatever code paid for this booking: nothing ran, so nothing was
  used. Called where a booking is turned down or withdrawn before approval —
  never after, where the member had what they paid for.

  A no-op for a booking that carried no code, and for one already released, so
  it is safe to call from every one of those paths.
  """
  def release_for(%Ad{discount_code_id: nil}), do: :ok

  def release_for(%Ad{} = ad) do
    Repo.update_all(
      from(r in DiscountRedemption,
        where: r.code_id == ^ad.discount_code_id and r.user_id == ^ad.user_id,
        where: is_nil(r.released_at)
      ),
      set: [released_at: DateTime.utc_now(:second)]
    )

    :ok
  end

  @doc "How often a code is in use right now (the admin list's count)."
  def live_redemptions(%DiscountCode{redemptions: redemptions}) when is_list(redemptions),
    do: Enum.count(redemptions, &is_nil(&1.released_at))
end
