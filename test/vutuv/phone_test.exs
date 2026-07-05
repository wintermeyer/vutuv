defmodule Vutuv.PhoneTest do
  use ExUnit.Case, async: true

  alias Vutuv.Phone

  describe "national/2" do
    test "renders a German number in national format for de viewers (drops +49)" do
      assert Phone.national("+49 261 9886803", "de") == "0261 9886803"
      assert Phone.national("+49 30 5550100", "de") == "030 5550100"
      assert Phone.national("+4915142408756", "de") == "01514 2408756"
    end

    test "normalizes a German number stored without the +49 prefix for de viewers" do
      assert Phone.national("017629544122", "de") == "0176 29544122"
      assert Phone.national("0171-1783428", "de") == "0171 1783428"
    end

    test "formats a number in international form for non-de viewers" do
      # An already-spaced value is returned unchanged; a run-together one is
      # spaced out so it reads cleanly (issue: unreadable +447840875616).
      assert Phone.national("+49 261 9886803", "en") == "+49 261 9886803"
      assert Phone.national("+49 261 9886803", nil) == "+49 261 9886803"
      assert Phone.national("+492619886803", "en") == "+49 261 9886803"
    end

    test "formats a foreign number in international form (keeping its country code), even for de viewers" do
      # Never converted to German national form (the +country code stays), but
      # grouped with spaces instead of returned as a run-together string.
      assert Phone.national("+447840875616", "de") == "+44 7840 875616"
      assert Phone.national("+447840875616", "en") == "+44 7840 875616"
      assert Phone.national("+421903419345", "de") == "+421 903 419 345"
      assert Phone.national("+41 78 956 91 14", "de") == "+41 78 956 91 14"
    end

    test "falls back to the stored value when it cannot be parsed or validated" do
      assert Phone.national("not a phone", "de") == "not a phone"
      assert Phone.national("12", "de") == "12"
      assert Phone.national("", "de") == ""
    end
  end

  describe "display/1" do
    test "formats a valid number in international form, spacing a run-together legacy value" do
      assert Phone.display("+447840875616") == "+44 7840 875616"
      assert Phone.display("+492619886803") == "+49 261 9886803"
      assert Phone.display("+421903419345") == "+421 903 419 345"
    end

    test "leaves an already-formatted number unchanged" do
      assert Phone.display("+49 30 5550100") == "+49 30 5550100"
      assert Phone.display("+41 78 956 91 14") == "+41 78 956 91 14"
    end

    test "falls back to the stored value when it cannot be parsed or validated" do
      assert Phone.display("not a phone") == "not a phone"
      assert Phone.display("12") == "12"
      assert Phone.display("") == ""
    end
  end

  describe "normalize/1" do
    test "rewrites a German number typed in local format to international form" do
      assert Phone.normalize("0261-123456") == {:ok, "+49 261 123456"}
      assert Phone.normalize("0261/123456") == {:ok, "+49 261 123456"}
      assert Phone.normalize("0171 1783428") == {:ok, "+49 171 1783428"}
      assert Phone.normalize("017629544122") == {:ok, "+49 176 29544122"}
    end

    test "canonicalizes an already-international number" do
      assert Phone.normalize("+49 261 9886803") == {:ok, "+49 261 9886803"}
      assert Phone.normalize("+492619886803") == {:ok, "+49 261 9886803"}
    end

    test "never reinterprets a foreign number as German" do
      assert Phone.normalize("+421903419345") == {:ok, "+421 903 419 345"}
      assert Phone.normalize("+1 202-555-0143") == {:ok, "+1 202-555-0143"}
    end

    test "rejects anything that is not a real phone number" do
      assert Phone.normalize("not a phone") == :error
      assert Phone.normalize("12") == :error
      assert Phone.normalize("555") == :error
      assert Phone.normalize("") == :error
    end
  end

  describe "country_flag/2" do
    test "annotates a foreign number with its flag + region for a de viewer" do
      assert Phone.country_flag("+421903419345", "de") == {"🇸🇰", "SK", 421}
      assert Phone.country_flag("+41 78 956 91 14", "de") == {"🇨🇭", "CH", 41}
    end

    test "annotates a German number for a non-de viewer (still shows +49)" do
      assert Phone.country_flag("+49 261 9886803", "en") == {"🇩🇪", "DE", 49}
      assert Phone.country_flag("+49 261 9886803", nil) == {"🇩🇪", "DE", 49}
    end

    test "adds no flag when the number is shown in national form (no +prefix)" do
      # A de viewer sees a German number as "0261 9886803" — no international
      # prefix, so per issue #892 there is nothing to annotate.
      assert Phone.country_flag("+49 261 9886803", "de") == nil
      assert Phone.country_flag("017629544122", "de") == nil
    end

    test "returns nil for an unparseable or unknown value" do
      assert Phone.country_flag("not a phone", "en") == nil
      assert Phone.country_flag("12", "en") == nil
      assert Phone.country_flag("", "en") == nil
    end
  end

  describe "tel/1" do
    test "returns the E.164 form for the tel: link" do
      assert Phone.tel("+49 261 9886803") == "+492619886803"
      assert Phone.tel("017629544122") == "+4917629544122"
      assert Phone.tel("+421903419345") == "+421903419345"
    end

    test "strips spaces and punctuation when the value cannot be parsed" do
      assert Phone.tel("abc") == ""
      assert Phone.tel("+49") == "+49"
    end
  end
end
