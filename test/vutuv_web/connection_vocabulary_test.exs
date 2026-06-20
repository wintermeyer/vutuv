defmodule VutuvWeb.ConnectionVocabularyTest do
  @moduledoc """
  Issue #797: the member-to-member connection relationship is named with ONE
  German word family — **vernetzen / vernetzt / Vernetzung** — everywhere.

  It is never called a "Kontakt" (that word stays for the profile *Contact*
  section and for "in Kontakt" = being in touch) and never a "Verbindung"
  (that stays for OAuth app linking and the unrelated "verbindlich"). This
  guards the deliberate decision against drift in the gettext catalog.

  Calls go through `Gettext.gettext/2,3` (the runtime API, not the macro) on
  purpose, so `mix gettext.extract` does not treat these strings as new
  msgids.
  """
  use ExUnit.Case, async: true

  @backend VutuvWeb.Gettext

  setup do
    Gettext.put_locale(@backend, "de")
    :ok
  end

  defp de(msgid), do: Gettext.gettext(@backend, msgid)
  defp de(msgid, bindings), do: Gettext.gettext(@backend, msgid, bindings)

  test "the connection entity and state use the vernetzen family" do
    # Vernetzt is a mutual follow now (no request/accept), so the request-flow
    # strings are gone; the relationship noun and state stay on this family.
    assert de("Connections") == "Vernetzungen"
    assert de("Connection") == "Vernetzung"
    assert de("Connections only") == "Nur Vernetzungen"
    assert de("No connections yet.") == "Noch keine Vernetzungen."
    assert Gettext.ngettext(@backend, "connection", "connections", 2) == "Vernetzungen"

    assert Gettext.ngettext(@backend, "1 connection", "%{count} connections", 5, count: 5) ==
             "5 Vernetzungen"

    assert de("Connected") == "Vernetzt"
    assert de("is now connected with you.") =~ "vernetzt"
  end

  test "no connection string calls the relationship a 'Verbindung' or 'Kontakt'" do
    connection_strings = [
      de("Connections"),
      de("Connection"),
      de("Connections only"),
      de("No connections yet."),
      de("Connections of %{name}", name: "Erika"),
      de("This post is for the connections of %{name}", name: "Erika"),
      de("Follow each other to connect with %{name} and read it.", name: "Erika"),
      de("Remove this connection? You will stop following them."),
      de("is now connected with you."),
      de(
        "Block @%{slug}? This removes any follows and connection between you, closes your conversation, and prevents all interaction in both directions. Unblocking will not restore what was removed.",
        slug: "erika"
      ),
      de(
        "Blocked members cannot follow you, connect with you, message you, or reply to your posts - and you cannot interact with them either. Blocking removed any follows and connection between you; unblocking does not restore them."
      )
    ]

    for s <- connection_strings do
      refute s =~ "Verbindung", "connection copy still uses 'Verbindung': #{inspect(s)}"
      refute s =~ "verbinden", "connection copy still uses 'verbinden': #{inspect(s)}"
      # "Kontakt" may legitimately appear as "kein Kontakt" / "in Kontakt"
      # (communication), so only the relationship-as-list noun is forbidden.
      refute s =~ ~r/\bKontakt(e|anfrage)/,
             "connection copy still uses the 'Kontakt' noun: #{inspect(s)}"
    end
  end

  test "unrelated German uses are left untouched" do
    # The profile Contact section (emails / phone) is not the connection
    # relationship and keeps "Kontakt".
    assert de("Contact") == "Kontakt"

    # "no contact in either direction" is communication, not the relationship,
    # so it keeps "Kontakt".
    assert de(
             "Your report paused the connection between you two - no contact in either direction for now. If our admins find the report unfounded, this is undone."
           ) =~ "kein Kontakt"
  end
end
