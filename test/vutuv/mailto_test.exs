defmodule Vutuv.MailtoTest do
  @moduledoc """
  The one rule this module exists for: a `mailto:` query is percent-encoded,
  never form-encoded. `URI.encode_www_form/1` was what the job board's apply
  button used, so a two-word job title reached the applicant's mail client as
  `Bewerbung:+Senior+Elixir+Developer`.
  """
  use ExUnit.Case, async: true

  alias Vutuv.Mailto

  test "a space is %20, never a plus" do
    url = Mailto.to("jobs@acme.example", "Application: Senior Elixir Developer")

    assert url == "mailto:jobs@acme.example?subject=Application%3A%20Senior%20Elixir%20Developer"
    refute url =~ "+"
  end

  # A plus a member really typed has to survive as a plus, which is the other
  # half of the same rule.
  test "a plus in the subject is encoded, not passed through" do
    assert Mailto.to("a@b.example", "C++") == "mailto:a@b.example?subject=C%2B%2B"
  end

  test "no subject, no query" do
    assert Mailto.to("a@b.example") == "mailto:a@b.example"
    assert Mailto.to("a@b.example", nil) == "mailto:a@b.example"
  end

  # German subjects are the normal case here, and a mail client that is handed
  # a raw umlaut in a URL is entitled to mangle it.
  test "non-ASCII is escaped" do
    assert Mailto.to("a@b.example", "Grüße") == "mailto:a@b.example?subject=Gr%C3%BC%C3%9Fe"
  end
end
