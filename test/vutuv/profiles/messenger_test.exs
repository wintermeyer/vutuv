defmodule Vutuv.Profiles.MessengerTest do
  use Vutuv.DataCase, async: true

  alias Vutuv.Profiles.Messenger

  defp changeset(params), do: Messenger.changeset(%Messenger{}, params)

  describe "changeset/2 validations" do
    test "requires a provider and a value" do
      cs = changeset(%{})
      refute cs.valid?
      assert %{provider: ["can't be blank"], value: ["can't be blank"]} = errors_on(cs)
    end

    test "rejects an unknown provider" do
      cs = changeset(%{"provider" => "ICQ", "value" => "12345"})
      refute cs.valid?
      assert %{provider: [_]} = errors_on(cs)
    end
  end

  describe "Signal / WhatsApp accept a phone number or a username" do
    test "a phone-shaped value is canonicalised through the phone validator" do
      cs = changeset(%{"provider" => "WhatsApp", "value" => "0261-123456"})
      assert cs.valid?
      assert get_change(cs, :value) == "+49 261 123456"
    end

    test "a username is kept as typed, not run through the phone validator" do
      cs = changeset(%{"provider" => "Signal", "value" => "@ada.99"})
      assert cs.valid?
      assert get_change(cs, :value) == "ada.99"
    end

    test "a phone-shaped but invalid number is rejected as a phone number" do
      cs = changeset(%{"provider" => "WhatsApp", "value" => "12"})
      refute cs.valid?
      assert %{value: ["Please enter a valid phone number"]} = errors_on(cs)
    end

    test "a value that is neither a valid phone nor a valid username is rejected" do
      cs = changeset(%{"provider" => "Signal", "value" => "no spaces allowed"})
      refute cs.valid?
      assert %{value: ["Enter a phone number or a username"]} = errors_on(cs)
    end
  end

  describe "handle-based providers" do
    test "Telegram stores the username without a leading @" do
      cs = changeset(%{"provider" => "Telegram", "value" => "@ada_lovelace"})
      assert cs.valid?
      assert get_change(cs, :value) == "ada_lovelace"
    end

    test "Threema uppercases the 8-character id and rejects a wrong length" do
      assert changeset(%{"provider" => "Threema", "value" => "abcd1234"}) |> get_change(:value) ==
               "ABCD1234"

      refute changeset(%{"provider" => "Threema", "value" => "ABC"}).valid?
    end

    test "Matrix accepts an MXID and adds a missing leading @" do
      cs = changeset(%{"provider" => "Matrix", "value" => "you:matrix.org"})
      assert cs.valid?
      assert get_change(cs, :value) == "@you:matrix.org"

      refute changeset(%{"provider" => "Matrix", "value" => "nope"}).valid?
    end

    test "Session accepts a 66-character id and rejects junk" do
      id = "05" <> String.duplicate("a", 64)
      assert changeset(%{"provider" => "Session", "value" => id}).valid?
      refute changeset(%{"provider" => "Session", "value" => "0512"}).valid?
    end
  end

  describe "url/1 deep links open the messenger at the contact" do
    test "WhatsApp uses bare E.164 digits" do
      %{value: value} = apply_changeset(%{"provider" => "WhatsApp", "value" => "0261-123456"})

      assert Messenger.url(%Messenger{provider: "WhatsApp", value: value}) ==
               "https://wa.me/49261123456"
    end

    test "Signal keeps the leading +" do
      %{value: value} = apply_changeset(%{"provider" => "Signal", "value" => "0261-123456"})

      assert Messenger.url(%Messenger{provider: "Signal", value: value}) ==
               "https://signal.me/#p/+49261123456"
    end

    test "Telegram, Threema and Matrix build their web links" do
      assert Messenger.url(%Messenger{provider: "Telegram", value: "ada"}) == "https://t.me/ada"

      assert Messenger.url(%Messenger{provider: "Threema", value: "ABCD1234"}) ==
               "https://threema.id/ABCD1234"

      assert Messenger.url(%Messenger{provider: "Matrix", value: "@you:matrix.org"}) ==
               "https://matrix.to/#/@you:matrix.org"
    end

    test "Session has no deep link" do
      assert Messenger.url(%Messenger{
               provider: "Session",
               value: "05" <> String.duplicate("a", 64)
             }) ==
               ""
    end

    test "a Signal / WhatsApp username has no deep link (there is no public resolver)" do
      assert Messenger.url(%Messenger{provider: "Signal", value: "ada.99"}) == ""
      assert Messenger.url(%Messenger{provider: "WhatsApp", value: "ada.wa"}) == ""
    end
  end

  defp apply_changeset(params) do
    {:ok, data} = changeset(params) |> Ecto.Changeset.apply_action(:insert)
    data
  end
end
