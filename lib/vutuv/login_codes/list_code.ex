defmodule Vutuv.LoginCodes.ListCode do
  @moduledoc """
  One code on a member's one-time login code list ("Kennwortliste", issue
  #912). The list is a batch of codes generated together; each code logs the
  member in once (`used_at` consumed atomically), and regenerating the list
  replaces every row.

  `code` is stored in its canonical `XXXX-XXXX` form, drawn from an
  unambiguous alphabet (no `0/O/1/I/L`), so the printed list survives
  handwriting and re-typing. Every field is set programmatically in
  `Vutuv.LoginCodes` — nothing is cast from request params.
  """

  use VutuvWeb, :model

  schema "login_list_codes" do
    belongs_to(:user, Vutuv.Accounts.User)

    field(:code, :string)
    field(:used_at, :utc_datetime)

    timestamps()
  end
end
