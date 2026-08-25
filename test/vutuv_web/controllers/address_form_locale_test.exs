defmodule VutuvWeb.AddressFormLocaleTest do
  @moduledoc """
  The address form has a per-country layout — postal conventions differ — and
  picks its template by name at runtime: `form_de`, `form_en`, `form_generic`.

  It chose between them with `Locale.locale_supported?/1`, which asks a
  different question: *does this site serve that language*. The two agreed by
  accident while there were exactly two locales, and stopped agreeing the day
  Italian shipped (v7.353.0) — `form_it` does not exist, so
  `String.to_existing_atom/1` raised and adding an address 500ed for anyone
  reading in Italian.

  That is the shape the German-render rule in `CLAUDE.md` is about: a plain
  English request renders fine and says nothing about the locale that breaks.
  So these drive every locale the installation serves, by `Accept-Language`.
  """
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Languages

  # `recycle/1` first: `create_and_login_user/1` already sent a response on this
  # conn, and a sent conn refuses a new request header.
  defp in_locale(conn, locale) do
    conn
    |> recycle()
    |> put_req_header("accept-language", "#{locale}-#{String.upcase(locale)},#{locale}")
  end

  test "the new-address form renders in every locale this installation serves", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    for locale <- Languages.site_locales() do
      html =
        conn
        |> in_locale(locale)
        |> get(~p"/settings/addresses/new")
        |> html_response(200)

      assert html =~ "form", "the #{locale} address form did not render"
    end
  end

  test "a locale with no form of its own falls back rather than raising", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    # Not a locale this installation serves at all — the same fall-through an
    # unserved language has always taken, and the branch the Italian bug proved
    # was being skipped.
    html =
      conn
      |> in_locale("fr")
      |> get(~p"/settings/addresses/new")
      |> html_response(200)

    assert html =~ "form"
  end
end
