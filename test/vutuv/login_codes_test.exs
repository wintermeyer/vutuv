defmodule Vutuv.LoginCodesTest do
  use Vutuv.DataCase

  alias Vutuv.LoginCodes
  alias Vutuv.LoginCodes.UserTotp

  # Move a confirmed enrolment's replay guard out of the way: verify_totp
  # refuses any code from a window at or before last_used_at, and confirming
  # stamps the current window. Backdating it lets a test redeem a fresh code
  # without waiting 30 real seconds.
  defp backdate_last_used(user) do
    LoginCodes.get_totp(user)
    |> Ecto.Changeset.change(last_used_at: DateTime.add(DateTime.utc_now(:second), -120))
    |> Repo.update!()
  end

  defp enroll_totp(user) do
    {:ok, pending} = LoginCodes.start_totp_enrollment(user)
    {:ok, _} = LoginCodes.confirm_totp(user, NimbleTOTP.verification_code(pending.secret))
    backdate_last_used(user)
    pending.secret
  end

  describe "authenticator app (TOTP)" do
    test "enrolment stays pending until the first valid code confirms it" do
      user = insert(:user)
      refute LoginCodes.totp_enabled?(user)

      {:ok, pending} = LoginCodes.start_totp_enrollment(user)
      assert is_binary(pending.secret)
      refute LoginCodes.totp_enabled?(user)

      # Reopening the setup page must keep the same secret, or a QR code
      # scanned just before a reload would silently stop matching.
      {:ok, resumed} = LoginCodes.start_totp_enrollment(user)
      assert resumed.secret == pending.secret

      assert {:error, :invalid_code} = LoginCodes.confirm_totp(user, "000000")
      refute LoginCodes.totp_enabled?(user)

      code = NimbleTOTP.verification_code(pending.secret)
      assert {:ok, %UserTotp{}} = LoginCodes.confirm_totp(user, code)
      assert LoginCodes.totp_enabled?(user)
      assert {:error, :already_enabled} = LoginCodes.start_totp_enrollment(user)
    end

    test "a pending (unconfirmed) enrolment never logs in" do
      user = insert(:user)
      {:ok, pending} = LoginCodes.start_totp_enrollment(user)

      assert :error =
               LoginCodes.redeem_login_code(user, NimbleTOTP.verification_code(pending.secret))
    end

    test "a confirmed app code redeems once and is replay-proof" do
      user = insert(:user)
      secret = enroll_totp(user)
      code = NimbleTOTP.verification_code(secret)

      assert :ok = LoginCodes.redeem_login_code(user, code)
      # The same code is refused for the rest of its window (NimbleTOTP since:).
      assert :error = LoginCodes.redeem_login_code(user, code)
    end

    test "whitespace in the typed code is ignored (apps display '123 456')" do
      user = insert(:user)
      secret = enroll_totp(user)
      <<a::binary-size(3), b::binary-size(3)>> = NimbleTOTP.verification_code(secret)

      assert :ok = LoginCodes.redeem_login_code(user, " #{a} #{b} ")
    end

    test "turning the app off removes the enrolment" do
      user = insert(:user)
      secret = enroll_totp(user)

      assert :ok = LoginCodes.disable_totp(user)
      refute LoginCodes.totp_enabled?(user)
      assert :error = LoginCodes.redeem_login_code(user, NimbleTOTP.verification_code(secret))
    end
  end

  describe "one-time code list" do
    test "generates a readable, unambiguous list and replaces it wholesale" do
      user = insert(:user)
      codes = LoginCodes.generate_list_codes(user)

      assert length(codes) == 10
      assert LoginCodes.unused_list_codes_count(user) == 10

      for %{code: code} <- codes do
        assert code =~ ~r/\A[0-9A-Z]{4}-[0-9A-Z]{4}\z/
        # The look-alike characters are excluded from the alphabet.
        refute String.contains?(code, ["0", "O", "1", "I", "L"])
      end

      # Regenerating replaces every code: the old ones stop working.
      [%{code: old_code} | _] = codes
      LoginCodes.generate_list_codes(user)
      assert LoginCodes.unused_list_codes_count(user) == 10
      assert :error = LoginCodes.redeem_login_code(user, old_code)
    end

    test "a code redeems exactly once, hyphen- and case-insensitively" do
      user = insert(:user)
      [%{code: code} | _] = LoginCodes.generate_list_codes(user)

      assert :ok = LoginCodes.redeem_login_code(user, String.downcase(code))
      assert LoginCodes.unused_list_codes_count(user) == 9
      assert :error = LoginCodes.redeem_login_code(user, code)
    end

    test "deleting the list disables its codes" do
      user = insert(:user)
      [%{code: code} | _] = LoginCodes.generate_list_codes(user)

      assert :ok = LoginCodes.delete_list_codes(user)
      refute LoginCodes.list_codes?(user)
      assert :error = LoginCodes.redeem_login_code(user, code)
    end

    test "another member's code never logs this member in" do
      user = insert(:user)
      other = insert(:user)
      [%{code: other_code} | _] = LoginCodes.generate_list_codes(other)

      assert :error = LoginCodes.redeem_login_code(user, other_code)
    end
  end

  describe "any_for_email?/1" do
    test "true only once something usable is enrolled for that address" do
      user = insert(:user)
      insert(:email, value: "codes@example.com", user: user)

      refute LoginCodes.any_for_email?("codes@example.com")

      # A pending TOTP enrolment is not usable at login yet.
      {:ok, pending} = LoginCodes.start_totp_enrollment(user)
      refute LoginCodes.any_for_email?("codes@example.com")

      {:ok, _} = LoginCodes.confirm_totp(user, NimbleTOTP.verification_code(pending.secret))
      assert LoginCodes.any_for_email?("CODES@example.com")

      # An unknown address reads the same as nothing enrolled.
      refute LoginCodes.any_for_email?("nobody@example.com")
    end

    test "an all-used code list no longer counts" do
      user = insert(:user)
      insert(:email, value: "sheet@example.com", user: user)
      codes = LoginCodes.generate_list_codes(user)
      assert LoginCodes.any_for_email?("sheet@example.com")

      for %{code: code} <- codes do
        assert :ok = LoginCodes.redeem_login_code(user, code)
      end

      refute LoginCodes.any_for_email?("sheet@example.com")
    end
  end

  describe "display helpers" do
    test "otpauth_uri carries the installation host and the member's handle" do
      user = insert(:user)
      {:ok, pending} = LoginCodes.start_totp_enrollment(user)

      uri = LoginCodes.otpauth_uri(user, pending)
      host = URI.parse(VutuvWeb.Endpoint.url()).host

      assert uri =~ "otpauth://totp/"
      assert uri =~ "issuer=#{host}"
      assert uri =~ user.username
    end

    test "manual_entry_secret is the Base32 secret in groups of four" do
      user = insert(:user)
      {:ok, pending} = LoginCodes.start_totp_enrollment(user)

      shown = LoginCodes.manual_entry_secret(pending)
      assert String.replace(shown, " ", "") == Base.encode32(pending.secret, padding: false)
      assert shown =~ ~r/\A(\S{4} )+\S{1,4}\z/
    end
  end
end
