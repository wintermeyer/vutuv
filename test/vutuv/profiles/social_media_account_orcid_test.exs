defmodule Vutuv.Profiles.SocialMediaAccountOrcidTest do
  @moduledoc "An ORCID iD as a listed account (issue #2350)."
  use Vutuv.DataCase, async: true

  alias Vutuv.Profiles.SocialMediaAccount

  @id "0000-0002-1825-0097"

  defp changeset(value),
    do: SocialMediaAccount.changeset(%SocialMediaAccount{}, %{provider: "ORCID", value: value})

  test "ORCID is an accepted provider" do
    assert "ORCID" in SocialMediaAccount.accepted_providers()
    assert changeset(@id).valid?
  end

  test "stores the bare iD whatever address shape the member pasted" do
    for input <- ["https://orcid.org/#{@id}", "https://orcid.org/my-orcid?orcid=#{@id}", @id] do
      assert Ecto.Changeset.get_field(changeset(input), :value) == @id, input
    end
  end

  test "rejects an iD with a wrong check digit, naming the shape" do
    cs = changeset("0000-0002-1825-0098")
    refute cs.valid?
    assert {"Enter your ORCID iD, e.g. 0000-0002-1825-0097", _} = cs.errors[:value]
  end

  test "rejects a username: ORCID knows only iDs" do
    refute changeset("alice").valid?
  end

  test "links to orcid.org and shows the iD bare" do
    account = %SocialMediaAccount{provider: "ORCID", value: @id}
    assert SocialMediaAccount.url(account) == "https://orcid.org/#{@id}"
    assert SocialMediaAccount.display(account) == @id
  end
end
