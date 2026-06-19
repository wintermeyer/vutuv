defmodule Vutuv.CredentialsTest do
  use Vutuv.DataCase, async: true

  alias Vutuv.Accounts
  alias Vutuv.Credentials
  alias Vutuv.Credentials.UserCredential

  # The full WebAuthn crypto round-trip needs a real browser authenticator, so
  # these cover everything around it: the relying-party config, the option maps,
  # the failure paths (which must never crash or log anyone in), the DB
  # constraints, and the owner-scoped list/get/delete/count. The success path is
  # exercised by the real-browser smoke test (see issue #795).

  describe "relying-party config" do
    test "rp_id and origins are derived from the endpoint (localhost in test)" do
      assert Credentials.rp_id() == "localhost"
      assert Credentials.origins() == ["http://localhost:4001"]
    end
  end

  describe "registration_options/1" do
    test "returns a Wax challenge and a browser-ready option map" do
      user = insert(:activated_user)
      {challenge, options} = Credentials.registration_options(user)

      assert %Wax.Challenge{} = challenge
      assert options.rp.id == "localhost"
      assert options.user.name == user.username
      # The challenge bytes and the user handle are base64url, JSON/WebAuthn-ready.
      assert {:ok, _} = Base.url_decode64(options.challenge, padding: false)
      assert {:ok, _} = Base.url_decode64(options.user.id, padding: false)
      assert options.authenticatorSelection.residentKey == "required"
    end

    test "excludes the member's already-enrolled credentials" do
      user = insert(:activated_user)
      credential = insert(:user_credential, user: user)

      {_challenge, options} = Credentials.registration_options(user)

      excluded = Enum.map(options.excludeCredentials, & &1.id)
      assert Base.url_encode64(credential.credential_id, padding: false) in excluded
    end
  end

  describe "authentication_options/0" do
    test "returns a challenge and an option map with no allow-list (discoverable)" do
      {challenge, options} = Credentials.authentication_options()

      assert %Wax.Challenge{} = challenge
      assert challenge.allow_credentials == []
      assert options.rpId == "localhost"
      assert {:ok, _} = Base.url_decode64(options.challenge, padding: false)
    end
  end

  describe "register/4 (failure paths)" do
    test "a malformed attestation payload returns an error, never raises" do
      user = insert(:activated_user)
      {challenge, _options} = Credentials.registration_options(user)

      assert {:error, _} =
               Credentials.register(
                 user,
                 challenge,
                 %{"attestationObject" => "not base64!", "clientDataJSON" => "also bad"},
                 "MacBook"
               )

      assert Credentials.count_for_user(user) == 0
    end
  end

  describe "verify_authentication/2 (failure paths)" do
    setup do
      {challenge, _options} = Credentials.authentication_options()
      %{challenge: challenge}
    end

    test "an unknown credential id is rejected without logging anyone in", %{challenge: challenge} do
      params = %{
        "rawId" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
        "authenticatorData" => Base.url_encode64("x", padding: false),
        "signature" => Base.url_encode64("y", padding: false),
        "clientDataJSON" => Base.url_encode64("{}", padding: false)
      }

      assert {:error, _} = Credentials.verify_authentication(challenge, params)
    end

    test "a malformed payload returns an error, never raises", %{challenge: challenge} do
      assert {:error, _} = Credentials.verify_authentication(challenge, %{"rawId" => "%%%"})
    end
  end

  describe "the unique credential_id constraint" do
    test "the same credential id cannot be enrolled twice" do
      credential = insert(:user_credential)
      other = insert(:activated_user)

      {:error, changeset} =
        %UserCredential{user_id: other.id}
        |> UserCredential.changeset(%{nickname: "dup"})
        |> Ecto.Changeset.put_change(:credential_id, credential.credential_id)
        |> Ecto.Changeset.put_change(:public_key, credential.public_key)
        |> Ecto.Changeset.unique_constraint(:credential_id)
        |> Repo.insert()

      assert {"has already been taken", _} = changeset.errors[:credential_id]
    end
  end

  describe "the owner's passkey list" do
    setup do
      user = insert(:activated_user)
      %{user: user}
    end

    test "list_for_user/1 returns only that user's credentials", %{user: user} do
      mine = insert(:user_credential, user: user)
      _theirs = insert(:user_credential)

      assert Enum.map(Credentials.list_for_user(user), & &1.id) == [mine.id]
      assert Credentials.count_for_user(user) == 1
    end

    test "get_for_user/2 scopes by owner and tolerates a bad id", %{user: user} do
      mine = insert(:user_credential, user: user)
      theirs = insert(:user_credential)

      assert Credentials.get_for_user(user, mine.id).id == mine.id
      assert Credentials.get_for_user(user, theirs.id) == nil
      assert Credentials.get_for_user(user, "not-a-uuid") == nil
    end

    test "delete/1 removes a passkey", %{user: user} do
      credential = insert(:user_credential, user: user)
      assert {:ok, _} = Credentials.delete(credential)
      assert Credentials.count_for_user(user) == 0
    end
  end

  describe "account deletion" do
    test "passkeys cascade away when the owner is deleted" do
      user = insert(:activated_user)
      insert(:user_credential, user: user)
      assert Credentials.count_for_user(user) == 1

      {:ok, _} = Accounts.delete_user(user)

      assert Repo.aggregate(
               from(c in UserCredential, where: c.user_id == ^user.id),
               :count
             ) == 0
    end
  end
end
