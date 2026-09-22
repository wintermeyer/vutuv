defmodule Vutuv.ConcurrentTest do
  use ExUnit.Case, async: true

  alias Vutuv.Concurrent

  test "returns the results in the order of the loads" do
    assert Concurrent.run([fn -> 1 end, fn -> 2 end, fn -> 3 end]) == [1, 2, 3]
  end

  test "a load writes in the caller's language" do
    # A task starts with an empty process dictionary, which is where Gettext
    # keeps the locale, so a load rendering text came out English on a
    # German page (the profile's CV thumbnail).
    Gettext.put_locale(VutuvWeb.Gettext, "de")

    assert Concurrent.run([fn -> Gettext.get_locale(VutuvWeb.Gettext) end]) == ["de"]
  end
end
