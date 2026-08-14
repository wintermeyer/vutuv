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

  describe "Signal also accepts its contact link" do
    @long_link "https://signal.me/#eu/" <> String.duplicate("aB3-_", 12)

    test "a signal.me link is stored as given" do
      cs = changeset(%{"provider" => "Signal", "value" => @long_link})
      assert cs.valid?
      assert get_change(cs, :value) == @long_link
    end

    test "the host is compared and stored case-insensitively, the token verbatim" do
      cs = changeset(%{"provider" => "Signal", "value" => "https://Signal.me/#eu/aB3-_xY"})
      assert cs.valid?
      assert get_change(cs, :value) == "https://signal.me/#eu/aB3-_xY"
    end

    test "the app scheme, a missing scheme and a www host all canonicalise to https" do
      for typed <- [
            "sgnl://signal.me/#eu/aB3",
            "signal.me/#eu/aB3",
            "https://www.signal.me/#eu/aB3",
            "  https://signal.me/#eu/aB3  "
          ] do
        cs = changeset(%{"provider" => "Signal", "value" => typed})
        assert cs.valid?, "expected #{typed} to be accepted"
        assert get_change(cs, :value) == "https://signal.me/#eu/aB3"
      end
    end

    test "anything before the fragment is dropped, since the fragment is the whole address" do
      cs =
        changeset(%{"provider" => "Signal", "value" => "https://signal.me/?utm_source=x#eu/aB3"})

      assert cs.valid?
      assert get_change(cs, :value) == "https://signal.me/#eu/aB3"
    end

    test "a link to another host, or one with no fragment, is rejected as a link" do
      for typed <- ["https://example.com/#eu/aB3", "https://signal.me/", "signal.me/#"] do
        cs = changeset(%{"provider" => "Signal", "value" => typed})
        refute cs.valid?, "expected #{typed} to be rejected"

        assert %{value: ["Enter your Signal link, it starts with https://signal.me/#"]} =
                 errors_on(cs)
      end
    end

    test "a provider without a contact link keeps rejecting a pasted URL" do
      cs = changeset(%{"provider" => "Telegram", "value" => "https://t.me/ada"})
      refute cs.valid?
      assert %{value: [_]} = errors_on(cs)
    end

    test "a username that merely looks host-like is still a username" do
      cs = changeset(%{"provider" => "Signal", "value" => "signal.me"})
      assert cs.valid?
      assert get_change(cs, :value) == "signal.me"
    end
  end

  describe "kind/1 tells the three address shapes apart" do
    test "link, phone and username" do
      assert Messenger.kind(%Messenger{provider: "Signal", value: "https://signal.me/#eu/aB3"}) ==
               :link

      assert Messenger.kind(%Messenger{provider: "Signal", value: "+49261123456"}) == :phone
      assert Messenger.kind(%Messenger{provider: "Signal", value: "ada.99"}) == :username
      assert Messenger.kind(%Messenger{provider: "Threema", value: "ABCD1234"}) == :username
    end
  end

  describe "a contact link reads as an action, never as its token" do
    @signal_link "https://signal.me/#eu/aB3"

    test "url/1 is the link itself" do
      assert Messenger.url(%Messenger{provider: "Signal", value: @signal_link}) == @signal_link
    end

    test "label/1 says what the link does, since it names no address" do
      assert Messenger.label(%Messenger{provider: "Signal", value: @signal_link}) == "Open chat"
    end

    test "label/1 shows the address for every other shape" do
      assert Messenger.label(%Messenger{provider: "Signal", value: "ada.99"}) == "ada.99"

      assert Messenger.label(%Messenger{provider: "Signal", value: "+49261123456"}) ==
               "+49 261 123456"
    end

    test "display/1 keeps the address itself, so agents and the vCard get the link" do
      assert Messenger.display(%Messenger{provider: "Signal", value: @signal_link}) ==
               @signal_link
    end
  end

  describe "from_url/1 recognises a messenger address pasted as a link" do
    test "signal.me yields the canonical link, the others the address inside the URL" do
      assert Messenger.from_url("https://signal.me/#eu/aB3") ==
               {"Signal", "https://signal.me/#eu/aB3"}

      assert Messenger.from_url("https://t.me/ada_lovelace") == {"Telegram", "ada_lovelace"}
      assert Messenger.from_url("https://threema.id/ABCD1234") == {"Threema", "ABCD1234"}

      assert Messenger.from_url("https://matrix.to/#/@you:matrix.org") ==
               {"Matrix", "@you:matrix.org"}
    end

    test "an ordinary webpage, a bare host and junk yield nothing" do
      assert Messenger.from_url("https://example.com/contact") == nil
      assert Messenger.from_url("https://signal.me/") == nil
      assert Messenger.from_url("https://t.me/") == nil
      assert Messenger.from_url(nil) == nil
    end

    test "what it returns is accepted by the changeset" do
      {provider, value} = Messenger.from_url("https://Signal.me/#eu/aB3")
      assert changeset(%{"provider" => provider, "value" => value}).valid?
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
