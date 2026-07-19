defmodule Vutuv.Accounts.EmailScrubTest do
  @moduledoc """
  The one-shot repair of legacy email addresses containing whitespace (the
  July 2026 import residue: 946 rows in prod). Only two unambiguous repairs
  are made - trimming edge whitespace, and removing whitespace from the domain
  part (a domain can never contain a space, so `gmail. com` can only mean
  `gmail.com`). Whitespace in the local part is a guess we refuse to make.
  Dirty rows are seeded via `Repo.update_all` because the changeset (rightly)
  rejects such values today.
  """
  use Vutuv.DataCase, async: true
  alias Vutuv.Accounts.{Email, EmailScrub}

  defp seed_email(value) do
    user = insert(:activated_user)

    email =
      insert(:email,
        user: user,
        value: "placeholder-#{System.unique_integer([:positive])}@example.com"
      )

    Repo.update_all(from(e in Email, where: e.id == ^email.id), set: [value: value])
    email.id
  end

  defp value_of(id), do: Repo.get!(Email, id).value

  defp md5_of(value) do
    :crypto.hash(:md5, value) |> Base.encode16() |> String.downcase()
  end

  test "trims edge whitespace and refreshes the md5sum" do
    id = seed_email(" ann@example.com ")

    assert EmailScrub.scrub_whitespace() == 1

    email = Repo.get!(Email, id)
    assert email.value == "ann@example.com"
    assert email.md5sum == md5_of("ann@example.com")
  end

  test "removes whitespace from the domain part" do
    id = seed_email("bad@gmail. com")

    assert EmailScrub.scrub_whitespace() == 1
    assert value_of(id) == "bad@gmail.com"
  end

  test "leaves whitespace in the local part alone (the intent is unknowable)" do
    id = seed_email("aang khunaifhi@gmail.co.id")

    assert EmailScrub.scrub_whitespace() == 0
    assert value_of(id) == "aang khunaifhi@gmail.co.id"
  end

  test "leaves irreparable garbage alone" do
    id = seed_email("@07012937465 ")

    assert EmailScrub.scrub_whitespace() == 0
    assert value_of(id) == "@07012937465 "
  end

  test "skips a repair whose result already exists as another address" do
    user = insert(:activated_user)
    insert(:email, user: user, value: "dup@example.com")
    id = seed_email("dup@example.com ")

    assert EmailScrub.scrub_whitespace() == 0
    assert value_of(id) == "dup@example.com "
  end

  test "when two dirty rows repair to the same value, only the older one is fixed" do
    older = seed_email("twin@example.com ")
    newer = seed_email(" twin@example.com")

    assert EmailScrub.scrub_whitespace() == 1
    assert value_of(older) == "twin@example.com"
    assert value_of(newer) == " twin@example.com"
  end

  test "is idempotent" do
    seed_email("ann@example.com ")

    assert EmailScrub.scrub_whitespace() == 1
    assert EmailScrub.scrub_whitespace() == 0
  end
end
